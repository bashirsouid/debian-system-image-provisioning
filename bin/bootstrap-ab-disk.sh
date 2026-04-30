#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=SCRIPTDIR/../scripts/lib/confirm-destructive.sh
source "$PROJECT_ROOT/scripts/lib/confirm-destructive.sh"
TARGET=""
SOURCE_DIR="$PROJECT_ROOT/mkosi.output/builds/latest"
DEFINITIONS_DIR="$PROJECT_ROOT/mkosi.sysupdate"
REPART_DIR="$PROJECT_ROOT/deploy.repart"
LOADER_TIMEOUT=3
ASSUME_YES=false
IMAGE_ID=""
ALLOW_FIXED_DISK=no
SKIP_SYSUPDATE=false

usage() {
  cat <<'USAGE'
Usage: sudo ./bin/bootstrap-ab-disk.sh --target /dev/sdX [options]

Destructively prepare a blank/offline disk or raw disk image for the native
systemd A/B-like workflow:
  1. create GPT partitions with systemd-repart
  2. install systemd-boot onto the target ESP
  3. seed the first version with systemd-sysupdate from mkosi.output/

Options:
  --target PATH          whole disk block device or raw disk image file
  --source-dir DIR       sysupdate source artifact directory, typically a
                         build folder under mkosi.output/builds/
                         (default: ./mkosi.output/builds/latest)
  --definitions DIR      sysupdate transfer definitions (default: ./mkosi.sysupdate)
  --repart-dir DIR       repart definitions (default: ./deploy.repart)
  --loader-timeout N     write loader.conf timeout value (default: 3)
  --image-id ID          explicit image identifier to use for transfer matching
  --allow-fixed-disk     permit writing to a non-removable (internal) disk;
                         the default refuses such targets to prevent the
                         "I flashed my laptop's SSD by accident" case
  --skip-sysupdate       only create partitions and install systemd-boot;
                         do NOT run systemd-sysupdate to seed the first
                         version (the caller is responsible for running
                         sysupdate separately)
  --yes                  skip the destructive confirmation prompt
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

confirm_or_abort() {
  [[ "$ASSUME_YES" == true ]] && return 0
  echo
  echo "===================================================================="
  echo "DESTRUCTIVE OPERATION: all partition data on the target will be lost"
  echo "===================================================================="
  echo
  echo "Target device:"
  ab_confirm_describe_target "$TARGET"
  if [[ -n "$IMAGE_ID" ]]; then
    echo
    echo "Installing image id: $IMAGE_ID"
  fi
  echo
  ab_confirm_typed_path "$TARGET" || exit 1
}

live_root_disk() {
  local root_source pkname
  root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
  [[ -n "$root_source" ]] || return 0
  root_source="$(readlink -f "$root_source")"
  if [[ -b "$root_source" ]]; then
    pkname="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
    if [[ -n "$pkname" ]]; then
      printf '/dev/%s\n' "$pkname"
      return 0
    fi
  fi
  printf '%s\n' "$root_source"
}

device_or_children_mounted() {
  local device="$1"
  if findmnt -rn -S "$device" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -b "$device" ]]; then
    while read -r child; do
      [[ -n "$child" ]] || continue
      if findmnt -rn -S "$child" >/dev/null 2>&1; then
        return 0
      fi
    done < <(lsblk -nrpo NAME "$device" | tail -n +2)
  fi

  return 1
}

ensure_safe_target() {
  local target_real root_disk
  target_real="$(readlink -f "$TARGET")"
  root_disk="$(live_root_disk)"

  if [[ -b "$target_real" && -n "$root_disk" && "$target_real" == "$root_disk" ]]; then
    die "refusing to repartition the currently running root disk: $target_real"
  fi

  if [[ -b "$target_real" ]] && device_or_children_mounted "$target_real"; then
    die "refusing to use mounted block device or a device with mounted partitions: $target_real"
  fi
}

cleanup() {
  set +e
  [[ -n "${ESP_MOUNT:-}" ]] && mountpoint -q "$ESP_MOUNT" && umount "$ESP_MOUNT"
  [[ -n "${ESP_MOUNT:-}" && -d "$ESP_MOUNT" ]] && rmdir "$ESP_MOUNT"
  [[ -n "${TEMP_DEFINITIONS_DIR:-}" && -d "$TEMP_DEFINITIONS_DIR" ]] && rm -rf "$TEMP_DEFINITIONS_DIR"
  if [[ -n "${LOOPDEV:-}" ]]; then
    losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

resolve_disk_device() {
  local target_real
  target_real="$(readlink -f "$TARGET")"

  if [[ -b "$target_real" ]]; then
    DISK_DEVICE="$target_real"
    TARGET_FOR_SYSUPDATE="$target_real"
    return 0
  fi

  [[ -f "$target_real" ]] || die "target is neither a block device nor a regular file: $TARGET"
  LOOPDEV="$(losetup --find --show --partscan "$target_real")"
  DISK_DEVICE="$LOOPDEV"
  TARGET_FOR_SYSUPDATE="$target_real"
}

find_esp_partition() {
  local part label fstype
  while read -r part label fstype; do
    if [[ "$label" == "ESP" || "$fstype" == "vfat" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
  done < <(lsblk -nrpo NAME,PARTLABEL,FSTYPE "$DISK_DEVICE")

  return 1
}

write_loader_conf() {
  local path="$1"
  install -d -m 0755 "$(dirname "$path")"
  cat > "$path" <<EOF2
# Managed by bin/bootstrap-ab-disk.sh
default *@saved
editor yes
timeout $LOADER_TIMEOUT
console-mode keep
EOF2
}

infer_image_id() {
  [[ -n "$IMAGE_ID" ]] && return 0
  if [[ -r "$SOURCE_DIR/build.env" ]]; then
    # shellcheck disable=SC1091
    . "$SOURCE_DIR/build.env"
    IMAGE_ID="${AB_LAST_BUILD_IMAGE_ID:-}"
  fi
}

prepare_sysupdate_definitions_dir() {
  local src dest image_id_escaped
  infer_image_id

  GENERATED_DEFINITIONS_DIR="$DEFINITIONS_DIR"
  [[ -n "$IMAGE_ID" ]] || return 0

  shopt -s nullglob
  local matches=("$DEFINITIONS_DIR"/*.transfer)
  shopt -u nullglob
  (( ${#matches[@]} > 0 )) || die "no *.transfer files found in $DEFINITIONS_DIR"

  TEMP_DEFINITIONS_DIR="$(mktemp -d /tmp/ab-sysupdate-defs.XXXXXX)"
  GENERATED_DEFINITIONS_DIR="$TEMP_DEFINITIONS_DIR"
  image_id_escaped="$(printf '%s' "$IMAGE_ID" | sed 's/[\/&]/\\&/g')"

  for src in "${matches[@]}"; do
    dest="$TEMP_DEFINITIONS_DIR/$(basename "$src")"
    sed "s/debian-provisioning/${image_id_escaped}/g" "$src" > "$dest"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:?missing target path}"
      shift 2
      ;;
    --source-dir)
      SOURCE_DIR="${2:?missing source dir}"
      shift 2
      ;;
    --definitions)
      DEFINITIONS_DIR="${2:?missing definitions dir}"
      shift 2
      ;;
    --repart-dir)
      REPART_DIR="${2:?missing repart dir}"
      shift 2
      ;;
    --loader-timeout)
      LOADER_TIMEOUT="${2:?missing timeout}"
      shift 2
      ;;
    --image-id)
      IMAGE_ID="${2:?missing image id}"
      shift 2
      ;;
    --allow-fixed-disk)
      ALLOW_FIXED_DISK=yes
      shift
      ;;
    --skip-sysupdate)
      SKIP_SYSUPDATE=true
      shift
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

[[ $EUID -eq 0 ]] || die "bootstrap-ab-disk.sh must run as root"
if ! ab_hostdeps_have_all_commands bootctl systemd-repart systemd-sysupdate mkfs.fat mkfs.ext4 findmnt lsblk losetup; then
  ab_hostdeps_ensure_packages "bootstrap prerequisites" systemd-boot-tools systemd-boot-efi systemd-repart systemd-container dosfstools e2fsprogs util-linux || exit 1
fi
ab_hostdeps_ensure_commands "bootstrap prerequisites" bootctl systemd-repart systemd-sysupdate mkfs.fat mkfs.ext4 findmnt lsblk losetup || exit 1

[[ -n "$TARGET" ]] || die "--target is required"
[[ -d "$SOURCE_DIR" ]] || die "source directory not found: $SOURCE_DIR"
[[ -d "$DEFINITIONS_DIR" ]] || die "sysupdate definitions not found: $DEFINITIONS_DIR"
[[ -d "$REPART_DIR" ]] || die "repart definitions not found: $REPART_DIR"

need_cmd bootctl
need_cmd systemd-repart
need_cmd systemd-sysupdate
need_cmd findmnt
need_cmd lsblk
need_cmd mount
need_cmd losetup
need_cmd install

preview_repart_layout() {
  echo "==> Planned partition layout for $TARGET"
  # Filter out the "Refusing to repartition, please re-run with
  # --dry-run=no." line that systemd-repart unconditionally appends
  # to dry-run output. The next step of this script DOES re-run with
  # --dry-run=no, so that message is misleading here.
  systemd-repart --dry-run=yes --empty=force --definitions="$REPART_DIR" "$TARGET_FOR_SYSUPDATE" 2>&1 \
    | grep -v '^Refusing to repartition' || true
}

wait_for_esp_partition() {
  local part="" i
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle >/dev/null 2>&1 || true
  fi
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$DISK_DEVICE" >/dev/null 2>&1 || true
  fi
  if command -v blockdev >/dev/null 2>&1; then
    blockdev --rereadpt "$DISK_DEVICE" >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 20); do
    part="$(find_esp_partition || true)"
    if [[ -n "$part" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
    if command -v udevadm >/dev/null 2>&1; then
      udevadm settle --timeout=5 >/dev/null 2>&1 || true
    fi
    sleep 0.5
  done
  return 1
}

ensure_safe_target
ab_confirm_require_removable "$TARGET" "$ALLOW_FIXED_DISK" || exit 1
resolve_disk_device
preview_repart_layout
confirm_or_abort

echo "==> Repartitioning $TARGET with systemd-repart"
systemd-repart --dry-run=no --empty=force --definitions="$REPART_DIR" "$TARGET_FOR_SYSUPDATE"

if [[ -n "${LOOPDEV:-}" ]]; then
  losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
  LOOPDEV="$(losetup --find --show --partscan "$TARGET_FOR_SYSUPDATE")"
  DISK_DEVICE="$LOOPDEV"
fi

ESP_PART="$(wait_for_esp_partition)" || die "unable to locate ESP partition after repart (partition table was written, but the ESP node did not appear in time)"
ESP_MOUNT="$(mktemp -d /tmp/ab-esp.XXXXXX)"
mount "$ESP_PART" "$ESP_MOUNT"

echo "==> Installing systemd-boot into target ESP"
bootctl --esp-path="$ESP_MOUNT" --no-variables install
write_loader_conf "$ESP_MOUNT/loader/loader.conf"

# systemd-sysupdate below is going to --image=$TARGET_FOR_SYSUPDATE,
# which means systemd-dissect will mount EVERY partition of the
# target disk internally (including the ESP, because the UKI and
# loader-entry transfers have PathRelativeTo=boot). If we leave the
# ESP mounted here from the bootctl step, dissect cannot acquire it
# cleanly and sysupdate fails with the misleading pair:
#     Failed to mount image: No such file or directory
#     No transfer definitions found.
# Unmount, sync bootctl's writes to the disk, wait for udev to
# re-settle the partition nodes, then hand the whole disk to
# sysupdate. This script does not need the ESP mounted again.
echo "==> Releasing ESP so systemd-sysupdate can dissect the whole disk"
umount "$ESP_MOUNT"
rmdir "$ESP_MOUNT"
ESP_MOUNT=""
sync
if command -v udevadm >/dev/null 2>&1; then
  udevadm settle --timeout=10 >/dev/null 2>&1 || true
fi

if [[ "$SKIP_SYSUPDATE" == true ]]; then
  echo "==> Skipping systemd-sysupdate (--skip-sysupdate was passed)"
  echo "    The caller is responsible for running sysupdate separately."
else
  echo "==> Seeding first system version with systemd-sysupdate"
  # Diagnostics: dump the exact inputs systemd-sysupdate will see, and
  # run a `list` probe before `update`. When the update step fails
  # silently with something like "No transfer definitions found." the
  # preceding output pins down whether the cause is (a) no .transfer
  # files in the definitions dir, (b) no matching files in the source
  # dir, or (c) sysupdate sees both but still decides there is nothing
  # to do. Without this preamble there is no way to tell which.
  echo "    definitions:     $DEFINITIONS_DIR"
  if [[ -d "$DEFINITIONS_DIR" ]]; then
    transfer_files=()
    while IFS= read -r f; do
      transfer_files+=("$f")
    done < <(find "$DEFINITIONS_DIR" -maxdepth 1 -type f -name '*.transfer' | sort)
    echo "    .transfer count: ${#transfer_files[@]}"
    for f in "${transfer_files[@]}"; do
      echo "      $(basename "$f")"
    done
  else
    echo "    (definitions dir does not exist)"
  fi
  echo "    transfer-source: $SOURCE_DIR"
  if [[ -d "$SOURCE_DIR" ]]; then
    echo "    source artifacts:"
    find "$SOURCE_DIR" -maxdepth 1 -type f \
      \( -name '*.root.raw' -o -name '*.efi' -o -name '*.conf' -o -name '*.artifacts.env' \) \
      -printf '      %f\n' | sort
  else
    echo "    (source dir does not exist)"
  fi
  # The image-policy tells systemd-dissect: mount the ESP (sysupdate
  # writes the UKI and BLS entry into /EFI/Linux and /loader/entries
  # via PathRelativeTo=boot), accept the root partitions whether they
  # carry a filesystem yet or not (sysupdate writes to them as raw
  # partitions via Type=partition + Path=auto), and ignore everything
  # else. This is important when extra partitions (like an exFAT
  # storage partition) exist on the disk.
  SYSUPDATE_IMAGE_POLICY='root=unprotected+absent:esp=unprotected:=unused+absent'

  echo "    image:           $TARGET_FOR_SYSUPDATE"
  echo "    image-policy:    $SYSUPDATE_IMAGE_POLICY"
  echo "==> systemd-sysupdate list (probe, non-fatal):"
  systemd-sysupdate \
    --definitions="$DEFINITIONS_DIR" \
    --transfer-source="$SOURCE_DIR" \
    --image="$TARGET_FOR_SYSUPDATE" \
    --image-policy="$SYSUPDATE_IMAGE_POLICY" \
    list 2>&1 | sed 's/^/    /' || true

  systemd-sysupdate \
    --definitions="$DEFINITIONS_DIR" \
    --transfer-source="$SOURCE_DIR" \
    --image="$TARGET_FOR_SYSUPDATE" \
    --image-policy="$SYSUPDATE_IMAGE_POLICY" \
    update
fi

echo "==> Bootstrap complete"
echo "    Target:      $TARGET"
echo "    Source dir:  $SOURCE_DIR"
echo ""
if [[ "$SKIP_SYSUPDATE" == true ]]; then
  echo "Next step: run systemd-sysupdate to seed the first version, then boot via UEFI + systemd-boot."
else
  echo "Next step: boot this disk/image via UEFI + systemd-boot."
fi
