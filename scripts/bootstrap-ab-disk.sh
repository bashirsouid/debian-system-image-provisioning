#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
TARGET=""
SOURCE_DIR="$PROJECT_ROOT/mkosi.output"
DEFINITIONS_DIR="$PROJECT_ROOT/mkosi.sysupdate"
REPART_DIR="$PROJECT_ROOT/deploy.repart"
LOADER_TIMEOUT=3
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/bootstrap-ab-disk.sh --target /dev/sdX [options]

Destructively prepare a blank/offline disk or raw disk image for the native
systemd A/B-like workflow:
  1. create GPT partitions with systemd-repart
  2. install systemd-boot onto the target ESP
  3. seed the first version with systemd-sysupdate from mkosi.output/

Options:
  --target PATH          whole disk block device or raw disk image file
  --source-dir DIR       sysupdate source artifact directory (default: ./mkosi.output)
  --definitions DIR      sysupdate transfer definitions (default: ./mkosi.sysupdate)
  --repart-dir DIR       repart definitions (default: ./deploy.repart)
  --loader-timeout N     write loader.conf timeout value (default: 3)
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
  local answer
  printf 'About to destroy partition data on %s and replace it with the layout shown above. Continue? [y/N] ' "$TARGET"
  read -r answer
  case "${answer,,}" in
    y|yes) return 0 ;;
    *) echo 'Aborted.'; exit 1 ;;
  esac
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
# Managed by scripts/bootstrap-ab-disk.sh
default *@saved
editor yes
timeout $LOADER_TIMEOUT
console-mode keep
EOF2
}


preview_repartition_layout() {
  local target_real output
  target_real="$(readlink -f "$TARGET")"
  echo "==> Planned partition layout for $TARGET"
  output="$(systemd-repart --dry-run=yes --empty=force --definitions="$REPART_DIR" "$target_real" 2>&1 || true)"
  printf '%s\n' "$output" | sed '/^Refusing to repartition, please re-run with --dry-run=no\.$/d'
}

wait_for_esp_partition() {
  local part="" attempt
  for attempt in $(seq 1 10); do
    part="$(find_esp_partition || true)"
    if [[ -n "$part" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
    if command -v udevadm >/dev/null 2>&1; then
      udevadm settle || true
    fi
    sleep 1
  done
  return 1
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
if ! ab_hostdeps_have_all_commands bootctl systemd-repart systemd-sysupdate mkfs.fat findmnt lsblk losetup; then
  ab_hostdeps_ensure_packages "bootstrap prerequisites" systemd-boot-tools systemd-boot-efi systemd-repart systemd-container dosfstools util-linux || exit 1
fi
ab_hostdeps_ensure_commands "bootstrap prerequisites" bootctl systemd-repart systemd-sysupdate mkfs.fat findmnt lsblk losetup || exit 1

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

ensure_safe_target
preview_repartition_layout
confirm_or_abort
resolve_disk_device

echo "==> Repartitioning $TARGET with systemd-repart"
systemd-repart --dry-run=no --empty=force --definitions="$REPART_DIR" "$TARGET_FOR_SYSUPDATE"

if [[ -n "${LOOPDEV:-}" ]]; then
  losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
  LOOPDEV="$(losetup --find --show --partscan "$TARGET_FOR_SYSUPDATE")"
  DISK_DEVICE="$LOOPDEV"
fi

ESP_PART="$(wait_for_esp_partition)" || die "unable to locate ESP partition after repart"
ESP_MOUNT="$(mktemp -d /tmp/ab-esp.XXXXXX)"
mount "$ESP_PART" "$ESP_MOUNT"

echo "==> Installing systemd-boot into target ESP"
SYSTEMD_RELAX_ESP_CHECKS=1 bootctl --esp-path="$ESP_MOUNT" --no-variables install
write_loader_conf "$ESP_MOUNT/loader/loader.conf"

echo "==> Seeding first system version with systemd-sysupdate"
systemd-sysupdate \
  --definitions="$DEFINITIONS_DIR" \
  --transfer-source="$SOURCE_DIR" \
  --image="$TARGET_FOR_SYSUPDATE" \
  update

echo "==> Bootstrap complete"
echo "    Target:      $TARGET"
echo "    Source dir:  $SOURCE_DIR"
echo "    ESP mount:   $ESP_MOUNT"
echo ""
echo "Next step: boot this disk/image via UEFI + systemd-boot."
