#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=scripts/lib/build-meta.sh
source "$PROJECT_ROOT/scripts/lib/build-meta.sh"
# shellcheck source=scripts/lib/confirm-destructive.sh
source "$PROJECT_ROOT/scripts/lib/confirm-destructive.sh"

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
ALLOW_FIXED_DISK=no

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
  --loader-timeout N    loader menu timeout to write to the USB ESP (default: 3)
  --usb-esp-size SIZE   override the ESP size used for the USB bootstrap
  --usb-root-size SIZE  override the per-slot root size used for the USB bootstrap
  --embed-full-image    also copy the built full disk image into the USB bundle
  --allow-fixed-disk    permit writing to a non-removable (internal) disk;
                        the default refuses such targets to prevent the
                        "I flashed my laptop's SSD by accident" case
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
  [[ -n "${TEMP_DEFINITIONS_DIR:-}" && -d "$TEMP_DEFINITIONS_DIR" ]] && rm -rf "$TEMP_DEFINITIONS_DIR"
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

  [[ -n "$IMAGE_ID" ]] || die "saved build metadata is missing AB_LAST_BUILD_IMAGE_ID"
  [[ -n "$IMAGE_VERSION" ]] || die "saved build metadata is missing AB_LAST_BUILD_IMAGE_VERSION"
  [[ -n "$IMAGE_ARCH" ]] || die "saved build metadata is missing AB_LAST_BUILD_ARCH"
  [[ -n "$IMAGE_BASENAME" ]] || die "saved build metadata is missing AB_LAST_BUILD_IMAGE_BASENAME"
}

prepare_sysupdate_definitions_dir() {
  local src dest image_id_escaped

  [[ -d "$DEFINITIONS_DIR" ]] || die "definitions directory not found: $DEFINITIONS_DIR"
  TEMP_DEFINITIONS_DIR="$(mktemp -d /tmp/ab-sysupdate-defs.XXXXXX)"
  GENERATED_DEFINITIONS_DIR="$TEMP_DEFINITIONS_DIR"
  image_id_escaped="$(printf '%s' "$IMAGE_ID" | sed 's/[\/&]/\\&/g')"

  shopt -s nullglob
  local matches=("$DEFINITIONS_DIR"/*.transfer)
  shopt -u nullglob
  (( ${#matches[@]} > 0 )) || die "no *.transfer files found in $DEFINITIONS_DIR"

  for src in "${matches[@]}"; do
    dest="$TEMP_DEFINITIONS_DIR/$(basename "$src")"
    sed "s/debian-provisioning/${image_id_escaped}/g" "$src" > "$dest"
  done
}

print_selected_build() {
  local artifact_prefix="$IMAGE_ID""_""$IMAGE_VERSION""_""$IMAGE_ARCH"
  echo "==> Selected build artifacts"
  echo "    Profile:        ${PROFILE:-${AB_LAST_BUILD_PROFILE:-}}"
  echo "    Host:           ${HOST:-${AB_LAST_BUILD_HOST:-}}"
  echo "    Image id:       $IMAGE_ID"
  echo "    Image version:  $IMAGE_VERSION"
  echo "    Artifact prefix:$artifact_prefix"
  echo "    Disk image:     $SOURCE_DIR/$IMAGE_BASENAME"
}

# The one destructive-confirmation point for the USB write flow. Runs
# BEFORE bootstrap-ab-disk.sh so the enhanced panel here (drive identity
# + full image identity from loaded build metadata) is the last thing
# the user reads. bootstrap-ab-disk.sh is then invoked with --yes so the
# user isn't double-prompted with a less-informed version of the same
# question. This is also where the non-removable-disk refusal lives;
# bootstrap has its own copy for direct callers.
confirm_usb_write_or_abort() {
  [[ "$ASSUME_YES" == true ]] && return 0

  echo
  echo "===================================================================="
  echo "DESTRUCTIVE OPERATION: all partition data on the target will be lost"
  echo "===================================================================="
  echo
  echo "Target device:"
  ab_confirm_describe_target "$TARGET"
  echo
  echo "Image to install:"
  ab_confirm_describe_image \
    "${PROFILE:-${AB_LAST_BUILD_PROFILE:-unknown}}" \
    "${HOST:-${AB_LAST_BUILD_HOST:-none}}" \
    "$IMAGE_ID" \
    "$IMAGE_VERSION" \
    "$IMAGE_ARCH" \
    "$SOURCE_DIR/$IMAGE_BASENAME"
  echo

  # Cross-host re-flash detector. If the target USB already has a
  # USB-IDENTITY.env from a previous flash, read it (read-only mount)
  # and compare against what we're about to install. A mismatch prints
  # a warning but does not skip the typed-path gate; the operator can
  # still proceed after seeing the prior identity.
  local existing_identity
  existing_identity="$(ab_confirm_read_existing_identity "$TARGET" 2>/dev/null || true)"
  if [[ -n "$existing_identity" ]]; then
    ab_confirm_identity_mismatch \
      "${PROFILE:-${AB_LAST_BUILD_PROFILE:-unknown}}" \
      "${HOST:-${AB_LAST_BUILD_HOST:-none}}" \
      "$IMAGE_ID" \
      "$IMAGE_VERSION" \
      "$IMAGE_ARCH" \
      <<<"$existing_identity" || true
  fi

  ab_confirm_require_removable "$TARGET" "$ALLOW_FIXED_DISK" || exit 1
  ab_confirm_typed_path "$TARGET" || exit 1
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

  find "${GENERATED_DEFINITIONS_DIR:-$PROJECT_ROOT/mkosi.sysupdate}" -maxdepth 1 -type f -name '*.transfer' -print
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
  write_fixed_partition_conf "$TEMP_REPART_DIR/10-root-a.conf" root _empty "${USB_ROOT_SIZE:-8G}" ext4
  write_fixed_partition_conf "$TEMP_REPART_DIR/11-root-b.conf" root _empty "${USB_ROOT_SIZE:-8G}" ext4
  BOOTSTRAP_REPART_DIR="$TEMP_REPART_DIR"
}

wait_for_seeded_root_partition() {
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
    part="$(find_seeded_root_partition || true)"
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

  cp -a "${GENERATED_DEFINITIONS_DIR:-$PROJECT_ROOT/mkosi.sysupdate}/." "$bundle_root/mkosi.sysupdate/"
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

  # Drop the identity file that the NEXT flash's
  # ab_confirm_read_existing_identity looks for. Keeping it next to
  # the bundle means it's always on the USB's root partition alongside
  # the installer it describes. The git rev is best-effort; lands as
  # 'unknown' if the build happened outside a git checkout.
  local git_rev
  git_rev="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  ab_confirm_write_usb_identity \
    "$bundle_root/USB-IDENTITY.env" \
    "${PROFILE:-${AB_LAST_BUILD_PROFILE:-unknown}}" \
    "${HOST:-${AB_LAST_BUILD_HOST:-}}" \
    "$IMAGE_ID" \
    "$IMAGE_VERSION" \
    "$IMAGE_ARCH" \
    "$git_rev"
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
    --allow-fixed-disk)
      ALLOW_FIXED_DISK=yes
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
ab_hostdeps_ensure_commands "hardware test USB prerequisites" systemd-repart systemd-sysupdate bootctl mkfs.fat losetup lsblk df || {
  echo "==> If this host still cannot provide systemd-sysupdate, use a newer Debian/systemd host for the native USB workflow." >&2
  echo "==> Fast fallback for a hardware smoke test: write the built .raw image directly to the USB instead of using the native installer USB flow." >&2
  exit 1
}

load_build_metadata
prepare_sysupdate_definitions_dir
print_selected_build
need_cmd losetup
need_cmd lsblk
need_cmd mount
need_cmd install
need_cmd df

[[ -f "$SOURCE_DIR/$IMAGE_BASENAME" ]] || die "built disk image not found: $SOURCE_DIR/$IMAGE_BASENAME"

prepare_bootstrap_repart_dir
confirm_usb_write_or_abort

bootstrap_args=(
  --target "$TARGET"
  --source-dir "$SOURCE_DIR"
  --definitions "$GENERATED_DEFINITIONS_DIR"
  --repart-dir "$BOOTSTRAP_REPART_DIR"
  --loader-timeout "$LOADER_TIMEOUT"
  # Confirmation already happened in confirm_usb_write_or_abort above
  # with strictly more context than bootstrap's own prompt can provide,
  # so always pass --yes down. If the user wants bootstrap's prompt,
  # they should call bootstrap directly.
  --yes
)
# Propagate --allow-fixed-disk: confirm_usb_write_or_abort has already
# enforced the removable check; bootstrap's own check would otherwise
# reject the target again and there's no way for the user to recover
# without this pass-through.
[[ "$ALLOW_FIXED_DISK" == "yes" ]] && bootstrap_args+=(--allow-fixed-disk)
[[ -n "$IMAGE_ID" ]] && bootstrap_args+=(--image-id "$IMAGE_ID")

echo "==> Bootstrapping hardware test USB on $TARGET"
"$PROJECT_ROOT/scripts/bootstrap-ab-disk.sh" "${bootstrap_args[@]}"

resolve_disk_device
ROOT_PART="$(wait_for_seeded_root_partition)" || die "unable to locate the seeded root partition on $TARGET (the USB was bootstrapped, but the newly-seeded root partition did not appear in time)"
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
