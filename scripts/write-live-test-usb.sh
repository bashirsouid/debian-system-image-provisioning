#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=scripts/lib/build-meta.sh
source "$PROJECT_ROOT/scripts/lib/build-meta.sh"

TARGET=""
SOURCE_DIR="$PROJECT_ROOT/mkosi.output"
DEFINITIONS_DIR="$PROJECT_ROOT/mkosi.sysupdate"
REPART_DIR="$PROJECT_ROOT/deploy.repart"
BUNDLE_DIR="/root/ab-installer"
PROFILE=""
HOST=""
ASSUME_YES=false
LOADER_TIMEOUT=3
EMBED_FULL_IMAGE=false
USB_ESP_SIZE=""
USB_ROOT_SIZE=""
IMAGE_ID=""
IMAGE_VERSION=""
IMAGE_ARCH=""
IMAGE_BASENAME=""
IMAGE_ID_OVERRIDE=""
IMAGE_VERSION_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/write-live-test-usb.sh --target /dev/sdX [options]

Bootstraps a removable USB drive with the native systemd-repart +
systemd-sysupdate layout, then copies an installer bundle onto the USB so you
can boot the machine from the USB, test the real hardware, and later install to
an internal disk from the running USB system.

Options:
  --target PATH         removable USB disk device (or raw disk image file)
  --source-dir DIR      built sysupdate artifacts directory (default: ./mkosi.output)
  --definitions DIR     sysupdate transfer definitions (default: ./mkosi.sysupdate)
  --repart-dir DIR      bootstrap repart definitions (default: ./deploy.repart)
  --bundle-dir PATH     path inside the USB root where the installer bundle is copied
                        (default: /root/ab-installer)
  --profile NAME        load build metadata for a specific profile
  --host NAME           load build metadata for a specific host overlay
  --image-id ID         override the selected build image id
  --image-version VER   override the selected build image version
  --loader-timeout N    loader menu timeout to write to the USB ESP (default: 3)
  --usb-esp-size SIZE   override the ESP size used for the USB bootstrap
  --usb-root-size SIZE  override the per-slot root size used for the USB bootstrap
  --embed-full-image    also copy the built full disk image into the USB bundle
  --yes                 skip destructive confirmation prompts
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

cleanup() {
  set +e
  [[ -n "${ROOT_MOUNT:-}" ]] && mountpoint -q "$ROOT_MOUNT" && umount "$ROOT_MOUNT"
  [[ -n "${ROOT_MOUNT:-}" && -d "$ROOT_MOUNT" ]] && rmdir "$ROOT_MOUNT"
  [[ -n "${TEMP_REPART_DIR:-}" && -d "$TEMP_REPART_DIR" ]] && rm -rf "$TEMP_REPART_DIR"
  if [[ -n "${LOOPDEV:-}" ]]; then
    losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

load_build_metadata() {
  if [[ -n "$PROFILE" || -n "$HOST" ]]; then
    ab_buildmeta_load_for "$PROJECT_ROOT" "$PROFILE" "$HOST" || die "no saved build metadata found for profile='$PROFILE' host='$HOST'"
  else
    ab_buildmeta_load "$PROJECT_ROOT" || die "no saved build metadata found; run ./build.sh first"
  fi

  IMAGE_ID="${AB_LAST_BUILD_IMAGE_ID:-}"
  IMAGE_VERSION="${AB_LAST_BUILD_IMAGE_VERSION:-}"
  IMAGE_ARCH="${AB_LAST_BUILD_ARCH:-}"
  IMAGE_BASENAME="${AB_LAST_BUILD_IMAGE_BASENAME:-}"

  if [[ -n "$IMAGE_ID_OVERRIDE" ]]; then
    IMAGE_ID="$IMAGE_ID_OVERRIDE"
  fi
  if [[ -n "$IMAGE_VERSION_OVERRIDE" ]]; then
    IMAGE_VERSION="$IMAGE_VERSION_OVERRIDE"
    IMAGE_BASENAME="${IMAGE_ID}_${IMAGE_VERSION}.raw"
  fi

  [[ -n "$IMAGE_ID" ]] || die "saved build metadata is missing AB_LAST_BUILD_IMAGE_ID"
  [[ -n "$IMAGE_VERSION" ]] || die "saved build metadata is missing AB_LAST_BUILD_IMAGE_VERSION"
  [[ -n "$IMAGE_ARCH" ]] || die "saved build metadata is missing AB_LAST_BUILD_ARCH"
  [[ -n "$IMAGE_BASENAME" ]] || die "saved build metadata is missing AB_LAST_BUILD_IMAGE_BASENAME"
}

resolve_disk_device() {
  local target_real
  target_real="$(readlink -f "$TARGET")"

  if [[ -b "$target_real" ]]; then
    DISK_DEVICE="$target_real"
    return 0
  fi

  [[ -f "$target_real" ]] || die "target is neither a block device nor a regular file: $TARGET"
  LOOPDEV="$(losetup --find --show --partscan "$target_real")"
  DISK_DEVICE="$LOOPDEV"
}

find_seeded_root_partition() {
  local part label fstype
  while read -r part label fstype; do
    [[ -n "$part" ]] || continue
    case "$label" in
      ESP|_empty|HOME|DATA)
        continue
        ;;
    esac
    [[ -n "$fstype" ]] || continue
    if [[ "$label" == "${IMAGE_ID}_${IMAGE_VERSION}" || "$label" == ${IMAGE_ID}_* ]]; then
      printf '%s\n' "$part"
      return 0
    fi
  done < <(lsblk -nrpo NAME,PARTLABEL,FSTYPE "$DISK_DEVICE")

  while read -r part label fstype; do
    [[ -n "$part" ]] || continue
    case "$label" in
      ESP|_empty|HOME|DATA)
        continue
        ;;
    esac
    [[ -n "$fstype" ]] || continue
    printf '%s\n' "$part"
    return 0
  done < <(lsblk -nrpo NAME,PARTLABEL,FSTYPE "$DISK_DEVICE")

  return 1
}

required_bundle_files() {
  local prefix="$IMAGE_ID""_""$IMAGE_VERSION""_""$IMAGE_ARCH"
  printf '%s\n' \
    "$SOURCE_DIR/${prefix}.root.raw" \
    "$SOURCE_DIR/${prefix}.efi" \
    "$SOURCE_DIR/${prefix}.conf" \
    "$SOURCE_DIR/${prefix}.artifacts.env" \
    "$SOURCE_DIR/SHA256SUMS" \
    "$PROJECT_ROOT/scripts/bootstrap-ab-disk.sh" \
    "$PROJECT_ROOT/scripts/live-usb-install.sh" \
    "$PROJECT_ROOT/scripts/sysupdate-local-update.sh" \
    "$PROJECT_ROOT/scripts/lib/host-deps.sh"

  find "$PROJECT_ROOT/mkosi.sysupdate" -maxdepth 1 -type f -name '*.transfer' -print
  find "$PROJECT_ROOT/deploy.repart" -maxdepth 1 -type f -name '*.conf' -print

  if [[ -f "$SOURCE_DIR/.latest-build.env" ]]; then
    printf '%s\n' "$SOURCE_DIR/.latest-build.env"
  fi
  if [[ -f "$(ab_buildmeta_file_for "$PROJECT_ROOT" "${PROFILE:-${AB_LAST_BUILD_PROFILE:-}}" "${HOST:-${AB_LAST_BUILD_HOST:-}}")" ]]; then
    printf '%s\n' "$(ab_buildmeta_file_for "$PROJECT_ROOT" "${PROFILE:-${AB_LAST_BUILD_PROFILE:-}}" "${HOST:-${AB_LAST_BUILD_HOST:-}}")"
  fi
  if [[ "$EMBED_FULL_IMAGE" == true ]]; then
    printf '%s\n' "$SOURCE_DIR/$IMAGE_BASENAME"
  fi
}

bundle_bytes_required() {
  local total=0 file size
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ -e "$file" ]] || die "bundle source file not found: $file"
    size="$(stat -Lc '%s' "$file")"
    total=$((total + size))
  done < <(required_bundle_files)
  printf '%s\n' "$total"
}

copy_file_preserving_layout() {
  local src="$1"
  local dest="$2"
  install -D -m 0644 "$src" "$dest"
}

write_fixed_partition_conf() {
  local path="$1"
  local type="$2"
  local label="$3"
  local size="$4"
  local format="${5:-}"
  {
    echo '[Partition]'
    printf 'Type=%s\n' "$type"
    printf 'Label=%s\n' "$label"
    printf 'SizeMinBytes=%s\n' "$size"
    printf 'SizeMaxBytes=%s\n' "$size"
    if [[ -n "$format" ]]; then
      printf 'Format=%s\n' "$format"
    fi
  } > "$path"
}

prepare_bootstrap_repart_dir() {
  BOOTSTRAP_REPART_DIR="$REPART_DIR"

  if [[ -z "$USB_ESP_SIZE" && -z "$USB_ROOT_SIZE" ]]; then
    return 0
  fi

  TEMP_REPART_DIR="$(mktemp -d /tmp/ab-usb-repart.XXXXXX)"
  write_fixed_partition_conf "$TEMP_REPART_DIR/00-esp.conf" esp ESP "${USB_ESP_SIZE:-512M}" vfat
  write_fixed_partition_conf "$TEMP_REPART_DIR/10-root-a.conf" root _empty "${USB_ROOT_SIZE:-8G}"
  write_fixed_partition_conf "$TEMP_REPART_DIR/11-root-b.conf" root _empty "${USB_ROOT_SIZE:-8G}"
  BOOTSTRAP_REPART_DIR="$TEMP_REPART_DIR"
}


print_selected_build() {
  local prefix="$IMAGE_ID""_""$IMAGE_VERSION""_""$IMAGE_ARCH"
  echo "==> Selected build artifacts"
  echo "    Profile:        ${PROFILE:-${AB_LAST_BUILD_PROFILE:-unknown}}"
  echo "    Host:           ${HOST:-${AB_LAST_BUILD_HOST:-none}}"
  echo "    Image id:       $IMAGE_ID"
  echo "    Image version:  $IMAGE_VERSION"
  echo "    Artifact prefix:$prefix"
  echo "    Disk image:     $SOURCE_DIR/$IMAGE_BASENAME"
}

wait_for_seeded_root_partition() {
  local part="" attempt
  for attempt in $(seq 1 10); do
    part="$(find_seeded_root_partition || true)"
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

copy_bundle() {
  local bundle_root="$ROOT_MOUNT$BUNDLE_DIR"
  local required avail headroom
  required="$(bundle_bytes_required)"
  avail="$(df -B1 --output=avail "$ROOT_MOUNT" | tail -n1 | tr -d '[:space:]')"
  headroom=$((256 * 1024 * 1024))

  if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < required + headroom )); then
    die "USB root filesystem does not have enough free space for the installer bundle (need about $(( (required + headroom) / 1024 / 1024 )) MiB free)"
  fi

  echo "==> Copying installer bundle into $BUNDLE_DIR"
  install -d -m 0700 "$bundle_root"
  install -d -m 0755 "$bundle_root/scripts/lib" "$bundle_root/mkosi.output" "$bundle_root/mkosi.sysupdate" "$bundle_root/deploy.repart"

  copy_file_preserving_layout "$PROJECT_ROOT/scripts/bootstrap-ab-disk.sh" "$bundle_root/scripts/bootstrap-ab-disk.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/scripts/live-usb-install.sh" "$bundle_root/scripts/live-usb-install.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/scripts/sysupdate-local-update.sh" "$bundle_root/scripts/sysupdate-local-update.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/scripts/lib/host-deps.sh" "$bundle_root/scripts/lib/host-deps.sh"
  chmod 0755 "$bundle_root/scripts/bootstrap-ab-disk.sh" "$bundle_root/scripts/live-usb-install.sh" "$bundle_root/scripts/sysupdate-local-update.sh"

  cp -a "$PROJECT_ROOT/mkosi.sysupdate/." "$bundle_root/mkosi.sysupdate/"
  cp -a "$PROJECT_ROOT/deploy.repart/." "$bundle_root/deploy.repart/"

  local prefix="$IMAGE_ID""_""$IMAGE_VERSION""_""$IMAGE_ARCH"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.root.raw" "$bundle_root/mkosi.output/${prefix}.root.raw"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.efi" "$bundle_root/mkosi.output/${prefix}.efi"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.conf" "$bundle_root/mkosi.output/${prefix}.conf"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.artifacts.env" "$bundle_root/mkosi.output/${prefix}.artifacts.env"
  copy_file_preserving_layout "$SOURCE_DIR/SHA256SUMS" "$bundle_root/mkosi.output/SHA256SUMS"

  if [[ -f "$SOURCE_DIR/.latest-build.env" ]]; then
    copy_file_preserving_layout "$SOURCE_DIR/.latest-build.env" "$bundle_root/mkosi.output/.latest-build.env"
  fi
  if [[ -f "$(ab_buildmeta_file_for "$PROJECT_ROOT" "${PROFILE:-${AB_LAST_BUILD_PROFILE:-}}" "${HOST:-${AB_LAST_BUILD_HOST:-}}")" ]]; then
    copy_file_preserving_layout "$(ab_buildmeta_file_for "$PROJECT_ROOT" "${PROFILE:-${AB_LAST_BUILD_PROFILE:-}}" "${HOST:-${AB_LAST_BUILD_HOST:-}}")" "$bundle_root/mkosi.output/$(basename "$(ab_buildmeta_file_for "$PROJECT_ROOT" "${PROFILE:-${AB_LAST_BUILD_PROFILE:-}}" "${HOST:-${AB_LAST_BUILD_HOST:-}}")")"
  fi
  if [[ "$EMBED_FULL_IMAGE" == true ]]; then
    copy_file_preserving_layout "$SOURCE_DIR/$IMAGE_BASENAME" "$bundle_root/mkosi.output/$IMAGE_BASENAME"
  fi

  cat > "$bundle_root/README.txt" <<EOF2
Hardware test USB bundle
========================

This USB was bootstrapped from build:
  image id:      $IMAGE_ID
  image version: $IMAGE_VERSION
  arch:          $IMAGE_ARCH

Recommended workflow after booting from the USB:
  sudo /root/INSTALL-TO-INTERNAL-DISK.sh

That wrapper runs:
  $BUNDLE_DIR/scripts/live-usb-install.sh

The bundled installer defaults to a fresh destructive A/B bootstrap onto the
selected target disk. By default it creates:
  - a 512M ESP
  - two retained root partitions of 8G each
  - a GPT home partition that takes the rest of the disk
  - no /mnt/data partition unless you ask for one

Use the live installer prompts to change that layout.
EOF2
  chmod 0644 "$bundle_root/README.txt"

  cat > "$ROOT_MOUNT/root/INSTALL-TO-INTERNAL-DISK.sh" <<EOF2
#!/usr/bin/env bash
exec $BUNDLE_DIR/scripts/live-usb-install.sh "\$@"
EOF2
  chmod 0750 "$ROOT_MOUNT/root/INSTALL-TO-INTERNAL-DISK.sh"
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
    --bundle-dir)
      BUNDLE_DIR="${2:?missing bundle dir}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:?missing profile name}"
      shift 2
      ;;
    --host)
      HOST="${2:?missing host name}"
      shift 2
      ;;
    --image-id)
      IMAGE_ID_OVERRIDE="${2:?missing image id}"
      shift 2
      ;;
    --image-version)
      IMAGE_VERSION_OVERRIDE="${2:?missing image version}"
      shift 2
      ;;
    --loader-timeout)
      LOADER_TIMEOUT="${2:?missing loader timeout}"
      shift 2
      ;;
    --usb-esp-size)
      USB_ESP_SIZE="${2:?missing USB ESP size}"
      shift 2
      ;;
    --usb-root-size)
      USB_ROOT_SIZE="${2:?missing USB root size}"
      shift 2
      ;;
    --embed-full-image)
      EMBED_FULL_IMAGE=true
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

[[ $EUID -eq 0 ]] || die "write-live-test-usb.sh must run as root"
[[ -n "$TARGET" ]] || die "--target is required"
[[ -d "$SOURCE_DIR" ]] || die "source directory not found: $SOURCE_DIR"
[[ -d "$DEFINITIONS_DIR" ]] || die "definitions directory not found: $DEFINITIONS_DIR"
[[ -d "$REPART_DIR" ]] || die "repart directory not found: $REPART_DIR"

if ! ab_hostdeps_have_all_commands systemd-repart systemd-sysupdate bootctl mkfs.fat losetup lsblk df; then
  ab_hostdeps_ensure_packages "hardware test USB prerequisites" systemd-container systemd-repart systemd-boot-tools systemd-boot-efi dosfstools fdisk util-linux || exit 1
fi
ab_hostdeps_ensure_commands "hardware test USB prerequisites" systemd-repart systemd-sysupdate bootctl mkfs.fat losetup lsblk df || exit 1

load_build_metadata
need_cmd losetup
need_cmd lsblk
need_cmd mount
need_cmd install
need_cmd df

print_selected_build
[[ -f "$SOURCE_DIR/$IMAGE_BASENAME" ]] || die "built disk image not found: $SOURCE_DIR/$IMAGE_BASENAME"

prepare_bootstrap_repart_dir

bootstrap_args=(
  --target "$TARGET"
  --source-dir "$SOURCE_DIR"
  --definitions "$DEFINITIONS_DIR"
  --repart-dir "$BOOTSTRAP_REPART_DIR"
  --loader-timeout "$LOADER_TIMEOUT"
)
[[ "$ASSUME_YES" == true ]] && bootstrap_args+=(--yes)

echo "==> Bootstrapping hardware test USB on $TARGET"
"$PROJECT_ROOT/scripts/bootstrap-ab-disk.sh" "${bootstrap_args[@]}"

resolve_disk_device
ROOT_PART="$(wait_for_seeded_root_partition)" || die "unable to locate the seeded root partition on $TARGET"
ROOT_MOUNT="$(mktemp -d /tmp/ab-live-root.XXXXXX)"
mount "$ROOT_PART" "$ROOT_MOUNT"

copy_bundle

echo "==> Hardware test USB is ready"
echo "    Boot target:     $TARGET"
echo "    Seeded root:     $ROOT_PART"
echo "    Installer entry: /root/INSTALL-TO-INTERNAL-DISK.sh"
if [[ "$EMBED_FULL_IMAGE" == true ]]; then
  echo "    Full raw image:  copied into $BUNDLE_DIR/mkosi.output/"
fi
