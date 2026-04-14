#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="$PROJECT_ROOT/mkosi.output/image.raw"
CONFIG_FILE="$PROJECT_ROOT/ab-flash.conf"
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/ab-flash.sh [options]

Safely deploy the built mkosi image into the inactive A/B root slot on a
UEFI + GRUB host, copy the slot's UKI into the shared ESP, regenerate GRUB,
set the current slot as the persistent fallback, and set the other slot for
one boot only.

Options:
  --config PATH   bash config file (default: ./ab-flash.conf)
  --image PATH    mkosi raw image to deploy (default: ./mkosi.output/image.raw)
  --yes           skip interactive confirmation
  -h, --help      show this help text

This script is intentionally conservative. It currently supports:
  - UEFI systems only
  - GRUB-managed hosts only
  - plain root slot partitions (no LVM/MD RAID root slots)
  - Secure Boot disabled

Typical flow:
  1. build and test the image in QEMU
  2. run this script on the real machine from the currently-good slot
  3. reboot; GRUB trial-boots the newly flashed inactive slot once
  4. if it looks good, run: sudo ab-bless-boot
     otherwise just reboot again and GRUB falls back to the saved slot
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_block() {
  local path="$1"
  [[ -n "$path" ]] || die "empty block-device path"
  local resolved
  resolved="$(readlink -f "$path")"
  [[ -b "$resolved" ]] || die "block device not found: $path"
  printf '%s\n' "$resolved"
}

secureboot_enabled() {
  local var
  var="$(find /sys/firmware/efi/efivars -maxdepth 1 -type f -name 'SecureBoot-*' | head -n1 || true)"
  [[ -n "$var" ]] || return 1
  local value_hex
  value_hex="$(tail -c 1 "$var" | od -An -t x1 | tr -d '[:space:]')"
  [[ "$value_hex" == "01" ]]
}

mount_source_for_path() {
  local path="$1"
  findmnt -nro SOURCE -T "$path" 2>/dev/null || true
}

lsblk_type() {
  local path="$1"
  lsblk -nro TYPE "$path" 2>/dev/null | head -n1
}

lsblk_parent_disk() {
  local path="$1"
  lsblk -nro PKNAME "$path" 2>/dev/null | head -n1
}

blkid_value() {
  local tag="$1"
  local path="$2"
  blkid -o value -s "$tag" "$path" 2>/dev/null || true
}

ensure_grub_default_saved() {
  local grub_default_file="$1"
  local tmp backup ts

  [[ -f "$grub_default_file" ]] || die "$grub_default_file not found"

  if grep -Eq '^[[:space:]]*GRUB_DEFAULT=["'"'']?saved["'"'']?([[:space:]]*#.*)?$' "$grub_default_file"; then
    return 0
  fi

  ts="$(date +%Y%m%d%H%M%S)"
  backup="$grub_default_file.ab-flash.bak.$ts"
  cp -a "$grub_default_file" "$backup"

  tmp="$(mktemp)"
  awk '
    BEGIN { done=0 }
    /^[[:space:]]*GRUB_DEFAULT=/ {
      if (!done) {
        print "GRUB_DEFAULT=saved"
        done=1
      }
      next
    }
    { print }
    END {
      if (!done)
        print "GRUB_DEFAULT=saved"
    }
  ' "$backup" > "$tmp"
  mv "$tmp" "$grub_default_file"

  echo "==> Updated $grub_default_file to use GRUB_DEFAULT=saved"
  echo "==> Backup written to $backup"
}

write_grub_slot_script() {
  local path="$1"
  local esp_uuid="$2"
  local slot_a_uuid="$3"
  local slot_b_uuid="$4"
  local slot_a_fstype="$5"
  local slot_b_fstype="$6"
  local uki_dir="$7"
  local slot_a_uki="$8"
  local slot_b_uki="$9"
  local extra_kernel_args="${10}"

  cat > "$path" <<EOF2
#!/bin/sh
set -e
cat <<'GRUB_EOF'
menuentry 'A/B Slot A (mkosi UKI)' --id ab-slot-a {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root $esp_uuid
    chainloader (\$root)$uki_dir/$slot_a_uki root=UUID=$slot_a_uuid rootfstype=$slot_a_fstype rw rootwait $extra_kernel_args
}

menuentry 'A/B Slot B (mkosi UKI)' --id ab-slot-b {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root $esp_uuid
    chainloader (\$root)$uki_dir/$slot_b_uki root=UUID=$slot_b_uuid rootfstype=$slot_b_fstype rw rootwait $extra_kernel_args
}
GRUB_EOF
EOF2
  chmod 0755 "$path"
}

copy_preserved_paths() {
  local target_root="$1"
  local src rel dst

  for pattern in "${PRESERVE_PATHS[@]}"; do
    for src in $pattern; do
      [[ -e "$src" ]] || continue
      rel="${src#/}"
      dst="$target_root/$rel"
      install -d -m 0755 "$(dirname "$dst")"
      if [[ -d "$src" && ! -L "$src" ]]; then
        rsync -aHAX --numeric-ids "$src/" "$dst/"
      else
        cp -a "$src" "$dst"
      fi
      echo "==> Preserved $src"
    done
  done
}

rewrite_target_fstab_root() {
  local fstab_path="$1"
  local root_uuid="$2"
  local tmp

  [[ -f "$fstab_path" ]] || return 0
  tmp="$(mktemp)"
  awk -v replacement="UUID=$root_uuid" '
    /^[[:space:]]*#/ { print; next }
    NF >= 2 && $2 == "/" {
      $1 = replacement
      print
      next
    }
    { print }
  ' "$fstab_path" > "$tmp"
  mv "$tmp" "$fstab_path"
}

find_image_partitions() {
  local loopdev="$1"
  local name fstype size partlabel parttype
  local best_size=0

  IMAGE_ROOT_PART=""
  IMAGE_ESP_PART=""

  while read -r name fstype size partlabel parttype; do
    [[ "$name" == "$loopdev" ]] && continue

    case "${fstype,,}" in
      vfat|fat|fat16|fat32|msdos)
        if [[ -z "$IMAGE_ESP_PART" ]]; then
          IMAGE_ESP_PART="$name"
        fi
        ;;
      swap)
        ;;
      "")
        ;;
      *)
        if [[ "$size" =~ ^[0-9]+$ ]] && (( size > best_size )); then
          IMAGE_ROOT_PART="$name"
          best_size="$size"
        fi
        ;;
    esac
  done < <(lsblk -b -nrpo NAME,FSTYPE,SIZE,PARTLABEL,PARTTYPE "$loopdev")

  [[ -n "$IMAGE_ROOT_PART" ]] || die "unable to identify root filesystem partition inside $IMAGE"
  [[ -n "$IMAGE_ESP_PART" ]] || die "unable to identify EFI system partition inside $IMAGE"
}

cleanup() {
  local rc=$?
  set +e
  [[ -n "${TARGET_ROOT_MNT:-}" && -d "${TARGET_ROOT_MNT:-}" ]] && mountpoint -q "$TARGET_ROOT_MNT" && umount "$TARGET_ROOT_MNT"
  [[ -n "${IMAGE_ROOT_MNT:-}" && -d "${IMAGE_ROOT_MNT:-}" ]] && mountpoint -q "$IMAGE_ROOT_MNT" && umount "$IMAGE_ROOT_MNT"
  [[ -n "${IMAGE_ESP_MNT:-}" && -d "${IMAGE_ESP_MNT:-}" ]] && mountpoint -q "$IMAGE_ESP_MNT" && umount "$IMAGE_ESP_MNT"
  [[ -n "${TARGET_ESP_MNT:-}" && -d "${TARGET_ESP_MNT:-}" ]] && mountpoint -q "$TARGET_ESP_MNT" && umount "$TARGET_ESP_MNT"
  [[ -n "${IMAGE_LOOP:-}" ]] && losetup -d "$IMAGE_LOOP" >/dev/null 2>&1 || true
  [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
  exit "$rc"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?missing config path}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing image path}"
      shift 2
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
[[ -f "$IMAGE" ]] || die "image not found: $IMAGE"

need_cmd blkid
need_cmd findmnt
need_cmd grub-editenv
need_cmd grub-mkconfig
need_cmd grub-reboot
need_cmd grub-set-default
need_cmd install
need_cmd losetup
need_cmd lsblk
need_cmd mount
need_cmd rsync
need_cmd umount

if [[ ! -d /sys/firmware/efi/efivars ]]; then
  die "this script currently supports UEFI systems only"
fi

if secureboot_enabled; then
  die "Secure Boot is enabled. This A/B GRUB flow relies on passing slot-specific root= arguments to the UKI, and Liquorix builds are also typically unsigned. Disable Secure Boot first."
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${SLOT_A_ROOT:?SLOT_A_ROOT must be set in $CONFIG_FILE}"
: "${SLOT_B_ROOT:?SLOT_B_ROOT must be set in $CONFIG_FILE}"
: "${ESP_PART:?ESP_PART must be set in $CONFIG_FILE}"
GRUB_DEFAULT_FILE="${GRUB_DEFAULT_FILE:-/etc/default/grub}"
GRUB_CFG="${GRUB_CFG:-/boot/grub/grub.cfg}"
GRUB_D_SCRIPT="${GRUB_D_SCRIPT:-/etc/grub.d/09_ab_slots}"
GRUBENV_PATH="${GRUBENV_PATH:-/boot/grub/grubenv}"
ESP_UKI_DIR="${ESP_UKI_DIR:-/EFI/Linux}"
ESP_SLOT_A_UKI="${ESP_SLOT_A_UKI:-ab-slot-a.efi}"
ESP_SLOT_B_UKI="${ESP_SLOT_B_UKI:-ab-slot-b.efi}"
ALLOW_GRUBENV_UNSAFE="${ALLOW_GRUBENV_UNSAFE:-no}"
EXTRA_KERNEL_ARGS="${EXTRA_KERNEL_ARGS:-}"

if ! declare -p PRESERVE_PATHS >/dev/null 2>&1 || [[ ${#PRESERVE_PATHS[@]} -eq 0 ]]; then
  PRESERVE_PATHS=(
    /etc/fstab
    /etc/machine-id
    /etc/hostname
    /etc/ssh/ssh_host_*
  )
fi

SLOT_A_ROOT="$(resolve_block "$SLOT_A_ROOT")"
SLOT_B_ROOT="$(resolve_block "$SLOT_B_ROOT")"
ESP_PART="$(resolve_block "$ESP_PART")"
ACTIVE_ROOT="$(readlink -f "$(findmnt -nro SOURCE /)")"

[[ "$ACTIVE_ROOT" == "$SLOT_A_ROOT" || "$ACTIVE_ROOT" == "$SLOT_B_ROOT" ]] || die "/ is on $ACTIVE_ROOT, which does not match SLOT_A_ROOT or SLOT_B_ROOT"
[[ "$SLOT_A_ROOT" != "$SLOT_B_ROOT" ]] || die "slot A and slot B resolve to the same block device"
[[ "$(lsblk_type "$SLOT_A_ROOT")" == "part" ]] || die "SLOT_A_ROOT must be a plain partition"
[[ "$(lsblk_type "$SLOT_B_ROOT")" == "part" ]] || die "SLOT_B_ROOT must be a plain partition"
[[ "$(lsblk_type "$ESP_PART")" == "part" ]] || die "ESP_PART must be a plain partition"

if [[ "$ACTIVE_ROOT" == "$SLOT_A_ROOT" ]]; then
  ACTIVE_SLOT="a"
  ACTIVE_GRUB_ID="ab-slot-a"
  INACTIVE_SLOT="b"
  INACTIVE_GRUB_ID="ab-slot-b"
  INACTIVE_ROOT="$SLOT_B_ROOT"
else
  ACTIVE_SLOT="b"
  ACTIVE_GRUB_ID="ab-slot-b"
  INACTIVE_SLOT="a"
  INACTIVE_GRUB_ID="ab-slot-a"
  INACTIVE_ROOT="$SLOT_A_ROOT"
fi

if findmnt -nr -S "$INACTIVE_ROOT" >/dev/null 2>&1; then
  die "inactive slot device $INACTIVE_ROOT is mounted; refusing to continue"
fi

GRUBENV_SOURCE="$(mount_source_for_path "$GRUBENV_PATH")"
if [[ -n "$GRUBENV_SOURCE" && "$GRUBENV_SOURCE" == /dev/* ]]; then
  GRUBENV_SOURCE="$(readlink -f "$GRUBENV_SOURCE")"
  case "$(lsblk_type "$GRUBENV_SOURCE")" in
    part|disk)
      ;;
    *)
      if [[ "$ALLOW_GRUBENV_UNSAFE" != "yes" ]]; then
        die "GRUB environment block appears to live on $GRUBENV_SOURCE ($(lsblk_type "$GRUBENV_SOURCE")); grub-reboot fallback may be unreliable there. Set ALLOW_GRUBENV_UNSAFE=yes only if you accept that risk."
      fi
      ;;
  esac
fi

grub-editenv "$GRUBENV_PATH" list >/dev/null 2>&1 || die "unable to access $GRUBENV_PATH with grub-editenv"
ensure_grub_default_saved "$GRUB_DEFAULT_FILE"

SLOT_A_UUID="$(blkid_value UUID "$SLOT_A_ROOT")"
SLOT_B_UUID="$(blkid_value UUID "$SLOT_B_ROOT")"
SLOT_A_FSTYPE="$(blkid_value TYPE "$SLOT_A_ROOT")"
SLOT_B_FSTYPE="$(blkid_value TYPE "$SLOT_B_ROOT")"
ESP_UUID="$(blkid_value UUID "$ESP_PART")"

[[ -n "$SLOT_A_UUID" && -n "$SLOT_B_UUID" ]] || die "failed to read filesystem UUIDs for the root slots"
[[ -n "$SLOT_A_FSTYPE" && -n "$SLOT_B_FSTYPE" ]] || die "failed to read filesystem types for the root slots"
[[ -n "$ESP_UUID" ]] || die "failed to read filesystem UUID for the ESP"

WORKDIR="$(mktemp -d)"
IMAGE_ROOT_MNT="$WORKDIR/image-root"
IMAGE_ESP_MNT="$WORKDIR/image-esp"
TARGET_ROOT_MNT="$WORKDIR/target-root"
TARGET_ESP_MNT="$WORKDIR/target-esp"
install -d "$IMAGE_ROOT_MNT" "$IMAGE_ESP_MNT" "$TARGET_ROOT_MNT" "$TARGET_ESP_MNT"

IMAGE_SHA256="$(sha256sum "$IMAGE" | awk '{print $1}')"
IMAGE_LOOP="$(losetup --find --show --partscan "$IMAGE")"
find_image_partitions "$IMAGE_LOOP"
mount -o ro "$IMAGE_ROOT_PART" "$IMAGE_ROOT_MNT"
mount -o ro "$IMAGE_ESP_PART" "$IMAGE_ESP_MNT"
mount "$INACTIVE_ROOT" "$TARGET_ROOT_MNT"
mount "$ESP_PART" "$TARGET_ESP_MNT"

mapfile -t IMAGE_UKIS < <(find "$IMAGE_ESP_MNT$ESP_UKI_DIR" -maxdepth 1 -type f -name '*.efi' | sort)
if [[ ${#IMAGE_UKIS[@]} -ne 1 ]]; then
  printf 'Found UKI candidates in %s:\n' "$IMAGE_ESP_MNT$ESP_UKI_DIR" >&2
  printf '  %s\n' "${IMAGE_UKIS[@]:-<none>}" >&2
  die "expected exactly one UKI in the image ESP"
fi
IMAGE_UKI="${IMAGE_UKIS[0]}"

INACTIVE_UUID="$(blkid_value UUID "$INACTIVE_ROOT")"
[[ -n "$INACTIVE_UUID" ]] || die "failed to determine UUID for inactive slot"

if [[ "$INACTIVE_SLOT" == "a" ]]; then
  TARGET_SLOT_UKI="$ESP_SLOT_A_UKI"
else
  TARGET_SLOT_UKI="$ESP_SLOT_B_UKI"
fi

cat <<SUMMARY
==> Deployment summary
    image:         $IMAGE
    image sha256:  $IMAGE_SHA256
    active slot:   $ACTIVE_SLOT ($ACTIVE_ROOT)
    inactive slot: $INACTIVE_SLOT ($INACTIVE_ROOT)
    shared ESP:    $ESP_PART
    trial boot id: $INACTIVE_GRUB_ID
SUMMARY

if [[ "$ASSUME_YES" != true ]]; then
  echo
  read -r -p "Type YES to deploy into the inactive slot: " answer
  [[ "$answer" == "YES" ]] || die "aborted"
fi

echo "==> Syncing image rootfs into inactive slot $INACTIVE_SLOT..."
rsync -aHAX --numeric-ids --delete --delete-excluded --exclude=/lost+found "$IMAGE_ROOT_MNT/" "$TARGET_ROOT_MNT/"

copy_preserved_paths "$TARGET_ROOT_MNT"
rewrite_target_fstab_root "$TARGET_ROOT_MNT/etc/fstab" "$INACTIVE_UUID"

install -d -m 0755 "$TARGET_ROOT_MNT/etc"
cat > "$TARGET_ROOT_MNT/etc/ab-slot.conf" <<EOF2
AB_SLOT=$INACTIVE_SLOT
AB_GRUB_ID=$INACTIVE_GRUB_ID
AB_OTHER_SLOT=$ACTIVE_SLOT
AB_OTHER_GRUB_ID=$ACTIVE_GRUB_ID
AB_ROOT_DEVICE=$INACTIVE_ROOT
AB_ROOT_UUID=$INACTIVE_UUID
AB_ESP_DEVICE=$ESP_PART
AB_ESP_UUID=$ESP_UUID
AB_UKI_PATH=$ESP_UKI_DIR/$TARGET_SLOT_UKI
AB_IMAGE_SHA256=$IMAGE_SHA256
EOF2
printf '%s\n' "$INACTIVE_SLOT" > "$TARGET_ROOT_MNT/etc/ab-slot"
printf '%s\n' "$IMAGE_SHA256" > "$TARGET_ROOT_MNT/etc/ab-image.sha256"

install -d -m 0755 "$TARGET_ESP_MNT$ESP_UKI_DIR"
cp -f "$IMAGE_UKI" "$TARGET_ESP_MNT$ESP_UKI_DIR/$TARGET_SLOT_UKI"
sync

echo "==> Installing managed GRUB slot entries..."
write_grub_slot_script \
  "$GRUB_D_SCRIPT" \
  "$ESP_UUID" \
  "$SLOT_A_UUID" \
  "$SLOT_B_UUID" \
  "$SLOT_A_FSTYPE" \
  "$SLOT_B_FSTYPE" \
  "$ESP_UKI_DIR" \
  "$ESP_SLOT_A_UKI" \
  "$ESP_SLOT_B_UKI" \
  "$EXTRA_KERNEL_ARGS"

echo "==> Regenerating GRUB config..."
grub-mkconfig -o "$GRUB_CFG" >/dev/null

echo "==> Setting persistent fallback to current slot: $ACTIVE_GRUB_ID"
grub-set-default "$ACTIVE_GRUB_ID"

echo "==> Scheduling one-time trial boot into new slot: $INACTIVE_GRUB_ID"
grub-reboot "$INACTIVE_GRUB_ID"

echo "==> Done. Reboot when ready to trial boot slot $INACTIVE_SLOT."
echo "==> If the new slot looks good, run: sudo ab-bless-boot"
echo "==> If it fails and the machine resets, GRUB should fall back to slot $ACTIVE_SLOT on the following boot."
