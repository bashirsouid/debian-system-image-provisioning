#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
IMAGE="$PROJECT_ROOT/mkosi.output/image.raw"
CONFIG_FILE="$PROJECT_ROOT/ab-flash.conf"
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Usage: sudo ./bin/ab-flash.sh [options]

LEGACY PATH: this script predates the native systemd-repart +
systemd-sysupdate workflow. Keep it only as a manual fallback.

Safely deploy the built mkosi image into the inactive A/B root slot on a
UEFI + systemd-boot host, copy the slot UKIs into the shared ESP, install or
update systemd-boot, keep the current slot as the persistent fallback, and set
the newly flashed slot for the next boot only.

Options:
  --config PATH   bash config file (default: ./ab-flash.conf)
  --image PATH    mkosi raw image to deploy (default: ./mkosi.output/image.raw)
  --yes           skip interactive confirmation
  -h, --help      show this help text

This script is intentionally conservative. It currently supports:
  - UEFI systems only
  - systemd-boot on the real host
  - plain root slot partitions (no LVM/MD RAID root slots)
  - Secure Boot disabled for this current flow
  - slot-specific kernel arguments supplied via Boot Loader Specification entries

Typical flow:
  1. build and test the image in QEMU
  2. run this script on the real machine from the currently-good slot
  3. reboot; systemd-boot boots the newly flashed inactive slot once
  4. the new slot records health + metadata on the shared ESP
  5. if auto-bless is disabled, run: sudo ab-bless-boot
     otherwise the new slot can promote itself after its health checks pass
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

findmnt_source() {
  local path="$1"
  findmnt -nro SOURCE -T "$path" 2>/dev/null || true
}

blkid_value() {
  local tag="$1"
  local path="$2"
  blkid -o value -s "$tag" "$path" 2>/dev/null || true
}

find_image_partitions() {
  local loopdev="$1"
  local name fstype size
  local best_size=0

  IMAGE_ROOT_PART=""
  IMAGE_ESP_PART=""

  while read -r name fstype size; do
    [[ "$name" == "$loopdev" ]] && continue

    case "${fstype,,}" in
      vfat|fat|fat16|fat32|msdos)
        if [[ -z "$IMAGE_ESP_PART" ]]; then
          IMAGE_ESP_PART="$name"
        fi
        ;;
      swap|"")
        ;;
      *)
        if [[ "$size" =~ ^[0-9]+$ ]] && (( size > best_size )); then
          IMAGE_ROOT_PART="$name"
          best_size="$size"
        fi
        ;;
    esac
  done < <(lsblk -b -nrpo NAME,FSTYPE,SIZE "$loopdev")

  [[ -n "$IMAGE_ROOT_PART" ]] || die "unable to identify root filesystem partition inside $IMAGE"
  [[ -n "$IMAGE_ESP_PART" ]] || die "unable to identify EFI system partition inside $IMAGE"
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

write_kv_file() {
  local path="$1"
  shift
  local tmp dir
  dir="$(dirname "$path")"
  install -d -m 0755 "$dir"
  tmp="$(mktemp "$dir/.abtmp.XXXXXX")"
  : > "$tmp"
  while [[ $# -gt 0 ]]; do
    printf '%s=%q\n' "$1" "${2-}" >> "$tmp"
    shift 2
  done
  chmod 0644 "$tmp"
  mv "$tmp" "$path"
}

load_build_info_from_image() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  # shellcheck disable=SC1090
  source "$path"
}

loader_entry_title() {
  local slot="$1"
  printf 'Debian A/B Slot %s\n' "${slot^^}"
}

write_loader_conf() {
  local path="$1"
  local timeout="$2"
  install -d -m 0755 "$(dirname "$path")"
  cat > "$path" <<EOF2
# Managed by bin/ab-flash.sh
timeout $timeout
editor yes
console-mode keep
EOF2
}

write_loader_entry() {
  local path="$1"
  local title="$2"
  local uki_path="$3"
  local root_uuid="$4"
  local root_fstype="$5"
  local extra_kernel_args="$6"
  local version="$7"

  install -d -m 0755 "$(dirname "$path")"
  cat > "$path" <<EOF2
# Managed by bin/ab-flash.sh
title $title
sort-key debian-ab
version $version
uki $uki_path
options root=UUID=$root_uuid rootfstype=$root_fstype rw rootwait $extra_kernel_args
EOF2
}

first_uki_in_dir() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -name '*.efi' | sort | head -n1
}

find_current_slot_uki_candidate() {
  local candidate

  for candidate in \
    /boot/EFI/Linux/*.efi \
    /efi/EFI/Linux/*.efi \
    /boot/efi/EFI/Linux/*.efi; do
    [[ -f "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

copy_uki_into_esp() {
  local src="$1"
  local dest="$2"
  install -d -m 0755 "$(dirname "$dest")"
  install -m 0644 "$src" "$dest"
}

mounted_target_for_source() {
  local source="$1"
  findmnt -nro TARGET -S "$source" 2>/dev/null | head -n1 || true
}

confirm_or_abort() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local answer
  printf 'Continue with flashing the inactive slot? [y/N] '
  read -r answer
  case "${answer,,}" in
    y|yes)
      return 0
      ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
}

cleanup() {
  set +e
  if [[ -n "${TARGET_ROOT_MOUNTPOINT:-}" && "${TARGET_ROOT_MOUNTED_BY_US:-false}" == true ]]; then
    umount "$TARGET_ROOT_MOUNTPOINT"
  fi
  if [[ -n "${IMAGE_ESP_MOUNTPOINT:-}" ]]; then
    umount "$IMAGE_ESP_MOUNTPOINT"
  fi
  if [[ -n "${IMAGE_ROOT_MOUNTPOINT:-}" ]]; then
    umount "$IMAGE_ROOT_MOUNTPOINT"
  fi
  if [[ -n "${ESP_MOUNTPOINT:-}" && "${ESP_MOUNTED_BY_US:-false}" == true ]]; then
    umount "$ESP_MOUNTPOINT"
  fi
  if [[ -n "${LOOPDEV:-}" ]]; then
    losetup -d "$LOOPDEV"
  fi
  if [[ -n "${WORKDIR:-}" ]]; then
    rm -rf "$WORKDIR"
  fi
}

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
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "ab-flash.sh must run as root"
if ! ab_hostdeps_have_all_commands awk blkid bootctl findmnt install losetup lsblk mount rsync sha256sum umount; then
  ab_hostdeps_ensure_packages "legacy A/B flash prerequisites" systemd-boot-tools systemd-boot-efi rsync util-linux || exit 1
fi
ab_hostdeps_ensure_commands "legacy A/B flash prerequisites" awk blkid bootctl findmnt install losetup lsblk mount rsync sha256sum umount || exit 1

[[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
[[ -f "$IMAGE" ]] || die "image file not found: $IMAGE"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

AB_BOOTLOADER="${AB_BOOTLOADER:-systemd-boot}"
INSTALL_SYSTEMD_BOOT="${INSTALL_SYSTEMD_BOOT:-yes}"
LOADER_TIMEOUT="${LOADER_TIMEOUT:-5}"
ESP_UKI_DIR="${ESP_UKI_DIR:-/EFI/Linux}"
LOADER_CONF_PATH="${LOADER_CONF_PATH:-/loader/loader.conf}"
LOADER_ENTRIES_DIR="${LOADER_ENTRIES_DIR:-/loader/entries}"
SLOT_A_ENTRY_ID="${SLOT_A_ENTRY_ID:-ab-slot-a.conf}"
SLOT_B_ENTRY_ID="${SLOT_B_ENTRY_ID:-ab-slot-b.conf}"
SLOT_A_UKI="${SLOT_A_UKI:-ab-slot-a.efi}"
SLOT_B_UKI="${SLOT_B_UKI:-ab-slot-b.efi}"
AB_STATE_ESP_DIR="${AB_STATE_ESP_DIR:-/EFI/Linux/ab-state}"
AB_AUTO_BLESS="${AB_AUTO_BLESS:-no}"
AB_HEALTH_DELAY_SECS="${AB_HEALTH_DELAY_SECS:-20}"
AB_HEALTH_HOOK_DIR="${AB_HEALTH_HOOK_DIR:-/usr/local/libexec/ab-health-check.d}"
AB_BUILD_INFO_PATH="${AB_BUILD_INFO_PATH:-/usr/local/share/ab-image-meta/build-info.env}"
AB_DEPLOY_INFO_PATH="${AB_DEPLOY_INFO_PATH:-/usr/local/share/ab-image-meta/deploy-info.env}"
AB_REBOOT_ON_HEALTH_FAILURE="${AB_REBOOT_ON_HEALTH_FAILURE:-no}"
AB_HEALTH_FAILURE_REBOOT_DELAY="${AB_HEALTH_FAILURE_REBOOT_DELAY:-5}"
EXTRA_KERNEL_ARGS="${EXTRA_KERNEL_ARGS:-quiet}"

: "${ESP_PART:?ESP_PART is required in the config file}"
: "${SLOT_A_ROOT:?SLOT_A_ROOT is required in the config file}"
: "${SLOT_B_ROOT:?SLOT_B_ROOT is required in the config file}"
: "${PRESERVE_PATHS:?PRESERVE_PATHS must be defined in the config file}"

[[ "$AB_BOOTLOADER" == "systemd-boot" ]] || die "this revision supports AB_BOOTLOADER=systemd-boot only"

for cmd in awk blkid bootctl findmnt install losetup lsblk mount rsync sha256sum umount; do
  need_cmd "$cmd"
done

[[ -d /sys/firmware/efi ]] || die "this host is not booted via UEFI"
if secureboot_enabled; then
  die "Secure Boot is enabled. This current A/B flow assumes Secure Boot is disabled because slot-specific kernel command-line overrides are injected from the boot menu entries."
fi

ESP_PART="$(resolve_block "$ESP_PART")"
SLOT_A_ROOT="$(resolve_block "$SLOT_A_ROOT")"
SLOT_B_ROOT="$(resolve_block "$SLOT_B_ROOT")"

CURRENT_ROOT_SOURCE="$(findmnt_source /)"
[[ -n "$CURRENT_ROOT_SOURCE" ]] || die "unable to determine the running root source"
CURRENT_ROOT_SOURCE="$(readlink -f "$CURRENT_ROOT_SOURCE")"
[[ -b "$CURRENT_ROOT_SOURCE" ]] || die "running root source is not a plain block device: $CURRENT_ROOT_SOURCE"

case "$CURRENT_ROOT_SOURCE" in
  "$SLOT_A_ROOT")
    CURRENT_SLOT=a
    CURRENT_ROOT="$SLOT_A_ROOT"
    CURRENT_ENTRY_ID="$SLOT_A_ENTRY_ID"
    CURRENT_UKI_NAME="$SLOT_A_UKI"
    TARGET_SLOT=b
    TARGET_ROOT="$SLOT_B_ROOT"
    TARGET_ENTRY_ID="$SLOT_B_ENTRY_ID"
    TARGET_UKI_NAME="$SLOT_B_UKI"
    ;;
  "$SLOT_B_ROOT")
    CURRENT_SLOT=b
    CURRENT_ROOT="$SLOT_B_ROOT"
    CURRENT_ENTRY_ID="$SLOT_B_ENTRY_ID"
    CURRENT_UKI_NAME="$SLOT_B_UKI"
    TARGET_SLOT=a
    TARGET_ROOT="$SLOT_A_ROOT"
    TARGET_ENTRY_ID="$SLOT_A_ENTRY_ID"
    TARGET_UKI_NAME="$SLOT_A_UKI"
    ;;
  *)
    die "running root ($CURRENT_ROOT_SOURCE) is not SLOT_A_ROOT or SLOT_B_ROOT"
    ;;
esac

for slot_root in "$SLOT_A_ROOT" "$SLOT_B_ROOT"; do
  [[ "$(lsblk -nro TYPE "$slot_root" | head -n1)" == "part" ]] || die "$slot_root is not a partition"
done

CURRENT_ROOT_UUID="$(blkid_value UUID "$CURRENT_ROOT")"
TARGET_ROOT_UUID="$(blkid_value UUID "$TARGET_ROOT")"
CURRENT_ROOT_FSTYPE="$(blkid_value TYPE "$CURRENT_ROOT")"
TARGET_ROOT_FSTYPE="$(blkid_value TYPE "$TARGET_ROOT")"
[[ -n "$CURRENT_ROOT_UUID" && -n "$TARGET_ROOT_UUID" ]] || die "unable to read slot root UUIDs"
[[ -n "$CURRENT_ROOT_FSTYPE" && -n "$TARGET_ROOT_FSTYPE" ]] || die "unable to read slot root filesystem types"

CURRENT_TARGET_UKI_PATH="$ESP_UKI_DIR/$CURRENT_UKI_NAME"
TARGET_TARGET_UKI_PATH="$ESP_UKI_DIR/$TARGET_UKI_NAME"

CURRENT_SLOT_UKI_CANDIDATE="$(find_current_slot_uki_candidate || true)"
[[ -n "$CURRENT_SLOT_UKI_CANDIDATE" ]] || die "unable to find a current-slot UKI under /boot/EFI/Linux, /efi/EFI/Linux, or /boot/efi/EFI/Linux. For the first systemd-boot migration, boot the current slot from a UKI-capable image first or place a fallback UKI at one of those locations."

CURRENT_IMAGE_SHA256="$(sha256sum "$IMAGE" | awk '{print $1}')"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TARGET_TITLE="$(loader_entry_title "$TARGET_SLOT")"
CURRENT_TITLE="$(loader_entry_title "$CURRENT_SLOT")"
TARGET_VERSION="$DEPLOYED_AT"
CURRENT_VERSION="$(uname -r 2>/dev/null || echo current)"

cat <<EOF2
==> A/B deployment summary
    Bootloader mode:       $AB_BOOTLOADER
    Current slot:          $CURRENT_SLOT ($CURRENT_ROOT)
    Current entry id:      $CURRENT_ENTRY_ID
    Target slot:           $TARGET_SLOT ($TARGET_ROOT)
    Target entry id:       $TARGET_ENTRY_ID
    Shared ESP:            $ESP_PART
    Image:                 $IMAGE
    Image sha256:          $CURRENT_IMAGE_SHA256
    Extra kernel args:     $EXTRA_KERNEL_ARGS
    Auto bless:            $AB_AUTO_BLESS
    Reboot on failure:     $AB_REBOOT_ON_HEALTH_FAILURE
EOF2
confirm_or_abort

trap cleanup EXIT
WORKDIR="$(mktemp -d)"
IMAGE_ROOT_MOUNTPOINT="$WORKDIR/image-root"
IMAGE_ESP_MOUNTPOINT="$WORKDIR/image-esp"
TARGET_ROOT_MOUNTPOINT="$WORKDIR/target-root"
ESP_MOUNTPOINT="$(mounted_target_for_source "$ESP_PART")"
ESP_MOUNTED_BY_US=false
TARGET_ROOT_MOUNTED_BY_US=false

mkdir -p "$IMAGE_ROOT_MOUNTPOINT" "$IMAGE_ESP_MOUNTPOINT" "$TARGET_ROOT_MOUNTPOINT"

if [[ -z "$ESP_MOUNTPOINT" ]]; then
  ESP_MOUNTPOINT="$WORKDIR/esp"
  mkdir -p "$ESP_MOUNTPOINT"
  mount "$ESP_PART" "$ESP_MOUNTPOINT"
  ESP_MOUNTED_BY_US=true
fi

existing_target_root_mnt="$(mounted_target_for_source "$TARGET_ROOT")"
if [[ -n "$existing_target_root_mnt" ]]; then
  die "inactive target slot is already mounted at $existing_target_root_mnt; unmount it before flashing"
else
  mount "$TARGET_ROOT" "$TARGET_ROOT_MOUNTPOINT"
  TARGET_ROOT_MOUNTED_BY_US=true
fi

LOOPDEV="$(losetup --find --show --partscan --read-only "$IMAGE")"
find_image_partitions "$LOOPDEV"
mount -o ro "$IMAGE_ROOT_PART" "$IMAGE_ROOT_MOUNTPOINT"
mount -o ro "$IMAGE_ESP_PART" "$IMAGE_ESP_MOUNTPOINT"

load_build_info_from_image "$IMAGE_ROOT_MOUNTPOINT$AB_BUILD_INFO_PATH"
CURRENT_VERSION="$(uname -r 2>/dev/null || echo current)"

TARGET_IMAGE_UKI="$(first_uki_in_dir "$IMAGE_ESP_MOUNTPOINT/EFI/Linux")"
[[ -n "$TARGET_IMAGE_UKI" ]] || die "unable to find a UKI in the built image under EFI/Linux"
TARGET_VERSION="$(basename "$TARGET_IMAGE_UKI" .efi)"

TARGET_SLOT_CONF="$TARGET_ROOT_MOUNTPOINT/etc/ab-slot.conf"
TARGET_DEPLOY_INFO="$TARGET_ROOT_MOUNTPOINT$AB_DEPLOY_INFO_PATH"
STATE_DIR="$ESP_MOUNTPOINT$AB_STATE_ESP_DIR"
SLOT_STATE_PATH="$STATE_DIR/slot-$TARGET_SLOT.env"
STATUS_STATE_PATH="$STATE_DIR/status.env"

mkdir -p "$STATE_DIR"

# Copy the new rootfs into the inactive slot.
echo "==> Syncing built image rootfs into inactive slot $TARGET_SLOT"
rsync -aHAX --numeric-ids --delete --info=progress2 "$IMAGE_ROOT_MOUNTPOINT/" "$TARGET_ROOT_MOUNTPOINT/"

copy_preserved_paths "$TARGET_ROOT_MOUNTPOINT"
rewrite_target_fstab_root "$TARGET_ROOT_MOUNTPOINT/etc/fstab" "$TARGET_ROOT_UUID"

# Ensure both slot UKIs exist on the shared ESP.
echo "==> Updating slot UKIs on the shared ESP"
copy_uki_into_esp "$CURRENT_SLOT_UKI_CANDIDATE" "$ESP_MOUNTPOINT$CURRENT_TARGET_UKI_PATH"
copy_uki_into_esp "$TARGET_IMAGE_UKI" "$ESP_MOUNTPOINT$TARGET_TARGET_UKI_PATH"

if [[ "$INSTALL_SYSTEMD_BOOT" == "yes" ]]; then
  echo "==> Installing/updating systemd-boot on the shared ESP"
  bootctl --esp-path="$ESP_MOUNTPOINT" install
fi

write_loader_conf "$ESP_MOUNTPOINT$LOADER_CONF_PATH" "$LOADER_TIMEOUT"
write_loader_entry \
  "$ESP_MOUNTPOINT$LOADER_ENTRIES_DIR/$CURRENT_ENTRY_ID" \
  "$CURRENT_TITLE" \
  "$CURRENT_TARGET_UKI_PATH" \
  "$CURRENT_ROOT_UUID" \
  "$CURRENT_ROOT_FSTYPE" \
  "$EXTRA_KERNEL_ARGS" \
  "$CURRENT_VERSION"
write_loader_entry \
  "$ESP_MOUNTPOINT$LOADER_ENTRIES_DIR/$TARGET_ENTRY_ID" \
  "$TARGET_TITLE" \
  "$TARGET_TARGET_UKI_PATH" \
  "$TARGET_ROOT_UUID" \
  "$TARGET_ROOT_FSTYPE" \
  "$EXTRA_KERNEL_ARGS" \
  "$TARGET_VERSION"

write_kv_file "$TARGET_SLOT_CONF" \
  AB_BOOTLOADER "$AB_BOOTLOADER" \
  AB_SLOT "$TARGET_SLOT" \
  AB_ENTRY_ID "$TARGET_ENTRY_ID" \
  AB_OTHER_SLOT "$CURRENT_SLOT" \
  AB_OTHER_ENTRY_ID "$CURRENT_ENTRY_ID" \
  AB_ROOT_DEVICE "$TARGET_ROOT" \
  AB_ROOT_UUID "$TARGET_ROOT_UUID" \
  AB_ESP_DEVICE "$ESP_PART" \
  AB_UKI_PATH "$TARGET_TARGET_UKI_PATH" \
  AB_STATE_ESP_DIR "$AB_STATE_ESP_DIR" \
  AB_AUTO_BLESS "$AB_AUTO_BLESS" \
  AB_HEALTH_DELAY_SECS "$AB_HEALTH_DELAY_SECS" \
  AB_HEALTH_HOOK_DIR "$AB_HEALTH_HOOK_DIR" \
  AB_BUILD_INFO_PATH "$AB_BUILD_INFO_PATH" \
  AB_DEPLOY_INFO_PATH "$AB_DEPLOY_INFO_PATH" \
  AB_REBOOT_ON_HEALTH_FAILURE "$AB_REBOOT_ON_HEALTH_FAILURE" \
  AB_HEALTH_FAILURE_REBOOT_DELAY "$AB_HEALTH_FAILURE_REBOOT_DELAY"

write_kv_file "$TARGET_DEPLOY_INFO" \
  AB_SLOT "$TARGET_SLOT" \
  AB_ENTRY_ID "$TARGET_ENTRY_ID" \
  AB_OTHER_SLOT "$CURRENT_SLOT" \
  AB_OTHER_ENTRY_ID "$CURRENT_ENTRY_ID" \
  AB_ROOT_DEVICE "$TARGET_ROOT" \
  AB_ROOT_UUID "$TARGET_ROOT_UUID" \
  AB_ESP_DEVICE "$ESP_PART" \
  AB_UKI_PATH "$TARGET_TARGET_UKI_PATH" \
  AB_IMAGE_SHA256 "$CURRENT_IMAGE_SHA256" \
  AB_DEPLOYED_AT "$DEPLOYED_AT" \
  AB_DEPLOY_SOURCE_IMAGE "$IMAGE" \
  AB_DEPLOY_SOURCE_HOST "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"

write_kv_file "$SLOT_STATE_PATH" \
  AB_SLOT "$TARGET_SLOT" \
  AB_ENTRY_ID "$TARGET_ENTRY_ID" \
  AB_ROOT_DEVICE "$TARGET_ROOT" \
  AB_ROOT_UUID "$TARGET_ROOT_UUID" \
  AB_UKI_PATH "$TARGET_TARGET_UKI_PATH" \
  AB_IMAGE_SHA256 "$CURRENT_IMAGE_SHA256" \
  AB_DEPLOYED_AT "$DEPLOYED_AT" \
  AB_BUILD_PROFILE "${AB_BUILD_PROFILE:-unknown}" \
  AB_BUILD_HOST_OVERLAY "${AB_BUILD_HOST_OVERLAY:-none}" \
  AB_BUILD_TIME_UTC "${AB_BUILD_TIME_UTC:-unknown}" \
  AB_BUILD_GIT_REV "${AB_BUILD_GIT_REV:-unknown}" \
  AB_BUILD_KERNEL_TRACK "${AB_BUILD_KERNEL_TRACK:-unknown}"

if [[ -f "$STATUS_STATE_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$STATUS_STATE_PATH"
fi

write_kv_file "$STATUS_STATE_PATH" \
  AB_STATE_VERSION "2" \
  AB_SAVED_SLOT "$CURRENT_SLOT" \
  AB_SAVED_ENTRY_ID "$CURRENT_ENTRY_ID" \
  AB_PENDING_SLOT "$TARGET_SLOT" \
  AB_PENDING_ENTRY_ID "$TARGET_ENTRY_ID" \
  AB_PENDING_IMAGE_SHA256 "$CURRENT_IMAGE_SHA256" \
  AB_PENDING_DEPLOYED_AT "$DEPLOYED_AT" \
  AB_LAST_BOOT_SLOT "${AB_LAST_BOOT_SLOT:-}" \
  AB_LAST_BOOT_STATUS "${AB_LAST_BOOT_STATUS:-}" \
  AB_LAST_BOOT_AT "${AB_LAST_BOOT_AT:-}" \
  AB_LAST_GOOD_SLOT "${AB_LAST_GOOD_SLOT:-}" \
  AB_LAST_GOOD_IMAGE_SHA256 "${AB_LAST_GOOD_IMAGE_SHA256:-}" \
  AB_LAST_GOOD_AT "${AB_LAST_GOOD_AT:-}" \
  AB_LAST_BAD_SLOT "${AB_LAST_BAD_SLOT:-}" \
  AB_LAST_BAD_IMAGE_SHA256 "${AB_LAST_BAD_IMAGE_SHA256:-}" \
  AB_LAST_BAD_REASON "${AB_LAST_BAD_REASON:-}" \
  AB_LAST_BAD_AT "${AB_LAST_BAD_AT:-}" \
  AB_LAST_FALLBACK_FROM "${AB_LAST_FALLBACK_FROM:-}" \
  AB_LAST_FALLBACK_TO "${AB_LAST_FALLBACK_TO:-}" \
  AB_LAST_FALLBACK_AT "${AB_LAST_FALLBACK_AT:-}" \
  AB_LAST_PROMOTION_SLOT "${AB_LAST_PROMOTION_SLOT:-}" \
  AB_LAST_PROMOTION_MODE "${AB_LAST_PROMOTION_MODE:-}" \
  AB_LAST_PROMOTION_AT "${AB_LAST_PROMOTION_AT:-}" \
  AB_LAST_MANUAL_PROMOTION_REQUIRED_SLOT "${AB_LAST_MANUAL_PROMOTION_REQUIRED_SLOT:-}" \
  AB_LAST_MANUAL_PROMOTION_REQUIRED_AT "${AB_LAST_MANUAL_PROMOTION_REQUIRED_AT:-}"

# Make the current slot the persistent default and the target slot the next boot only.
echo "==> Setting persistent fallback to current slot: $CURRENT_ENTRY_ID"
bootctl --esp-path="$ESP_MOUNTPOINT" set-default "$CURRENT_ENTRY_ID"
echo "==> Scheduling next boot into target slot: $TARGET_ENTRY_ID"
bootctl --esp-path="$ESP_MOUNTPOINT" set-oneshot "$TARGET_ENTRY_ID"

sync

echo
cat <<EOF2
==> A/B deploy complete.
    Current saved fallback: $CURRENT_SLOT ($CURRENT_ENTRY_ID)
    Next boot only:         $TARGET_SLOT ($TARGET_ENTRY_ID)
    Shared ESP state:       $STATUS_STATE_PATH

Next steps:
  1. reboot
  2. on the new slot, run: sudo ab-status
  3. if AB_AUTO_BLESS=no, run: sudo ab-bless-boot after validation
EOF2
