#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=SCRIPTDIR/../scripts/lib/build-meta.sh
source "$PROJECT_ROOT/scripts/lib/build-meta.sh"
# shellcheck source=SCRIPTDIR/../scripts/lib/confirm-destructive.sh
source "$PROJECT_ROOT/scripts/lib/confirm-destructive.sh"

TARGET=""
BUILD_DIR=""
SOURCE_DIR=""
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
# By default the remaining space on the USB past ESP+root-a+root-b
# becomes a user-writable exFAT partition so the test USB is actually
# useful as a stick (copy files off the machine, carry installers,
# etc.) instead of having ~tens of GiB of unallocated space. Disable
# with --no-usb-storage.
INCLUDE_USB_STORAGE=true
USB_STORAGE_LABEL="USBDATA"

usage() {
  cat <<'USAGE'
Usage: sudo ./bin/write-live-test-usb.sh --target /dev/sdX [options]

Bootstraps a removable USB drive with the native systemd-repart +
systemd-sysupdate layout, then copies an installer bundle onto the USB so you
can boot the machine from the USB, test the real hardware, and later install to
an internal disk from the running USB system.

Options:
  --target PATH         removable USB disk device (or raw disk image file)
  --build-dir PATH      specific build folder under mkosi.output/builds/ to
                        flash. Takes precedence over --host / --profile.
  --definitions DIR     sysupdate transfer definitions (default: ./mkosi.sysupdate)
  --repart-dir DIR      bootstrap repart definitions (default: ./deploy.repart)
  --bundle-dir PATH     path inside the USB root where the installer bundle is copied
                        (default: /root/ab-installer)
  --profile NAME        resolve mkosi.output/builds/latest-NAME when --host
                        is not given and --build-dir is not set
  --host NAME           resolve mkosi.output/builds/latest-NAME (the host
                        name); with no --build-dir this is the usual way
                        to pick the right build
  --loader-timeout N    loader menu timeout to write to the USB ESP (default: 3)
  --usb-esp-size SIZE   override the ESP size used for the USB bootstrap
  --usb-root-size SIZE  override the per-slot root size used for the USB bootstrap
  --embed-full-image    also copy the built full disk image into the USB bundle
  --no-usb-storage      do not create the trailing exFAT storage partition
                        (by default the remaining USB space becomes a
                        user-writable exFAT partition labeled USBDATA)
  --usb-storage-label L set the exFAT partition label (default: USBDATA)
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
  # Per-host profile default: when --host is given and --profile is not,
  # look at hosts/<host>/profile.default so the tool picks the same
  # profile build.sh would have used by default. This is only for
  # display / identity output — resolution itself is by host symlink.
  if [[ -n "$HOST" && -z "$PROFILE" ]]; then
    local host_default_profile
    host_default_profile="$(ab_buildmeta_host_default_profile "$PROJECT_ROOT" "$HOST")"
    [[ -n "$host_default_profile" ]] && PROFILE="$host_default_profile"
  fi

  if [[ -z "$BUILD_DIR" ]]; then
    BUILD_DIR="$(ab_buildmeta_resolve_build_dir "$PROJECT_ROOT" "$PROFILE" "$HOST" || true)"
  fi

  if [[ -z "$BUILD_DIR" ]]; then
    if [[ -n "$HOST" ]]; then
      die "no build found for host='$HOST' under mkosi.output/builds/ — run ./build.sh --host '$HOST' first"
    elif [[ -n "$PROFILE" ]]; then
      die "no build found for profile='$PROFILE' under mkosi.output/builds/ — run ./build.sh --profile '$PROFILE' first"
    else
      die "no build found under mkosi.output/builds/ — run ./build.sh first, or pass --build-dir / --host / --profile"
    fi
  fi

  [[ -d "$BUILD_DIR" ]] || die "resolved build folder does not exist: $BUILD_DIR"
  ab_buildmeta_load_env "$BUILD_DIR" \
    || die "build folder is missing build.env: $BUILD_DIR"

  IMAGE_ID="${AB_LAST_BUILD_IMAGE_ID:-}"
  IMAGE_VERSION="${AB_LAST_BUILD_IMAGE_VERSION:-}"
  IMAGE_ARCH="${AB_LAST_BUILD_ARCH:-}"
  IMAGE_BASENAME="${AB_LAST_BUILD_IMAGE_BASENAME:-}"

  [[ -n "$IMAGE_ID" ]] || die "build.env is missing AB_LAST_BUILD_IMAGE_ID"
  [[ -n "$IMAGE_VERSION" ]] || die "build.env is missing AB_LAST_BUILD_IMAGE_VERSION"
  [[ -n "$IMAGE_ARCH" ]] || die "build.env is missing AB_LAST_BUILD_ARCH"
  [[ -n "$IMAGE_BASENAME" ]] || die "build.env is missing AB_LAST_BUILD_IMAGE_BASENAME"

  # Every path below this point reads from the resolved build folder.
  SOURCE_DIR="$BUILD_DIR"
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
  echo "==> Selected build"
  echo "    Build folder:   $BUILD_DIR"
  echo "    Profile:        ${AB_LAST_BUILD_PROFILE:-${PROFILE:-unknown}}"
  echo "    Host:           ${AB_LAST_BUILD_HOST:-${HOST:-none}}"
  echo "    Image id:       $IMAGE_ID"
  echo "    Image version:  $IMAGE_VERSION"
  echo "    Artifact prefix:$artifact_prefix"
  echo "    Disk image:     $SOURCE_DIR/$IMAGE_BASENAME"
}

# Shows the user two things right before the typed-path gate:
#   BEFORE: the current partition table on the target as lsblk sees
#           it right now. This is the "did I pick the right drive"
#           check -- familiar labels (DATA, HOME, a USB stick you
#           recognize) here are the last chance to notice a mistake.
#   AFTER:  the layout systemd-repart is about to create, from
#           --dry-run=yes. This is the "is this the layout I meant"
#           check -- confirms ESP + two roots + the trailing exFAT
#           storage partition match expectations before any writes.
# systemd-repart accepts the target path directly (block device or
# regular file), so this works before resolve_disk_device has
# loop-attached a file target.
preview_current_and_planned_layout() {
  local target_real
  target_real="$(readlink -f "$TARGET")"

  echo "Current partition table on target (BEFORE):"
  if [[ -b "$target_real" ]]; then
    # -f shows fstype/label/uuid without needing root on some hosts;
    # -o lays out the columns we want to see.
    lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINT "$target_real" 2>/dev/null \
      || echo "  (lsblk failed; target may have no partition table yet)"
  elif [[ -f "$target_real" ]]; then
    printf '  raw image file: %s (%s bytes)\n' \
      "$target_real" "$(stat -Lc '%s' "$target_real" 2>/dev/null || echo unknown)"
    printf '  (will be loop-attached before repart runs)\n'
  else
    echo "  (target is neither a block device nor a regular file)"
  fi
  echo

  echo "Planned layout after repart (AFTER):"
  # Redirect stderr to stdout so the layout table lands in the panel
  # rather than interleaving with the prompt. Filter out the
  # "Refusing to repartition, please re-run with --dry-run=no." line
  # that systemd-repart unconditionally appends to dry-run output —
  # it's misleading in a preview context because this script DOES
  # then re-run with --dry-run=no a few lines below. `|| true`
  # because a dry-run failure (e.g. image too small for the roots)
  # should still let the prompt proceed; the real run will fail
  # loudly and the user has already been warned.
  systemd-repart --dry-run=yes --empty=force \
    --definitions="$BOOTSTRAP_REPART_DIR" \
    "$target_real" 2>&1 \
    | grep -v '^Refusing to repartition' \
    | sed 's/^/  /' || true
  if [[ "$INCLUDE_USB_STORAGE" == true ]]; then
    echo
    echo "  Note: the USBDATA partition above is created unformatted by"
    echo "        systemd-repart, then formatted as exFAT (label=$USB_STORAGE_LABEL)"
    echo "        after the A/B bootstrap finishes."
  fi
  echo
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
    "${AB_LAST_BUILD_PROFILE:-unknown}" \
    "${AB_LAST_BUILD_HOST:-none}" \
    "$IMAGE_ID" \
    "$IMAGE_VERSION" \
    "$IMAGE_ARCH" \
    "$SOURCE_DIR/$IMAGE_BASENAME"
  echo

  preview_current_and_planned_layout

  # Cross-host re-flash detector. If the target USB already has a
  # USB-IDENTITY.env from a previous flash, read it (read-only mount)
  # and compare against what we're about to install. A mismatch prints
  # a warning but does not skip the typed-path gate; the operator can
  # still proceed after seeing the prior identity.
  local existing_identity
  existing_identity="$(ab_confirm_read_existing_identity "$TARGET" 2>/dev/null || true)"
  if [[ -n "$existing_identity" ]]; then
    ab_confirm_identity_mismatch \
      "${AB_LAST_BUILD_PROFILE:-unknown}" \
      "${AB_LAST_BUILD_HOST:-none}" \
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
      ESP|_empty|HOME|DATA|USBDATA)
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
      ESP|_empty|HOME|DATA|USBDATA)
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
    "$SOURCE_DIR/build.env" \
    "$PROJECT_ROOT/bin/bootstrap-ab-disk.sh" \
    "$PROJECT_ROOT/installer/live-usb-install.sh" \
    "$PROJECT_ROOT/bin/sysupdate-local-update.sh" \
    "$PROJECT_ROOT/scripts/lib/host-deps.sh" \
    "$PROJECT_ROOT/scripts/lib/build-meta.sh"

  find "${GENERATED_DEFINITIONS_DIR:-$PROJECT_ROOT/mkosi.sysupdate}" -maxdepth 1 -type f -name '*.transfer' -print
  find "$PROJECT_ROOT/deploy.repart" -maxdepth 1 -type f -name '*.conf' -print

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
  TEMP_REPART_DIR="$(mktemp -d /tmp/ab-usb-repart.XXXXXX)"
  BOOTSTRAP_REPART_DIR="$TEMP_REPART_DIR"

  # Base layout: if the user did not override sizes, mirror the
  # committed deploy.repart/ exactly so the USB ESP+root layout is
  # identical to an internal-disk bootstrap. With size overrides,
  # generate fresh confs with the requested sizes.
  if [[ -z "$USB_ESP_SIZE" && -z "$USB_ROOT_SIZE" ]]; then
    cp "$REPART_DIR"/*.conf "$TEMP_REPART_DIR/"
  else
    write_fixed_partition_conf "$TEMP_REPART_DIR/00-esp.conf" esp ESP "${USB_ESP_SIZE:-512M}" vfat
    write_fixed_partition_conf "$TEMP_REPART_DIR/10-root-a.conf" root _empty "${USB_ROOT_SIZE:-8G}" ext4
    write_fixed_partition_conf "$TEMP_REPART_DIR/11-root-b.conf" root _empty "${USB_ROOT_SIZE:-8G}" ext4
  fi

  if [[ "$INCLUDE_USB_STORAGE" == true ]]; then
    write_usb_storage_partition_conf "$TEMP_REPART_DIR/20-usb-storage.conf"
  fi
}

# Writes the GPT entry for the trailing USB storage partition.
# systemd-repart creates the partition but does NOT format it; we
# mkfs.exfat it ourselves after bootstrap because repart's built-in
# Format= list does not reliably include exfat across the systemd
# versions we target. With no Size*Bytes set, repart grows the
# partition to fill whatever space remains after the fixed ESP and
# root partitions. If nothing is left, repart simply does not
# allocate this partition and format_usb_storage_partition() treats
# the absence as "no storage partition, nothing to do".
write_usb_storage_partition_conf() {
  local path="$1"
  cat > "$path" <<EOF
[Partition]
Type=linux-generic
Label=$USB_STORAGE_LABEL
EOF
}

find_usb_storage_partition() {
  local part label _fstype
  while read -r part label _fstype; do
    [[ -n "$part" ]] || continue
    if [[ "$label" == "$USB_STORAGE_LABEL" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
  done < <(lsblk -nrpo NAME,PARTLABEL,FSTYPE "$DISK_DEVICE")
  return 1
}

format_usb_storage_partition() {
  local part
  [[ "$INCLUDE_USB_STORAGE" == true ]] || return 0
  part="$(find_usb_storage_partition || true)"
  if [[ -z "$part" ]]; then
    echo "==> No USBDATA partition present (likely no free space after roots); skipping exFAT format"
    return 0
  fi
  echo "==> Formatting $part as exFAT (label=$USB_STORAGE_LABEL)"
  # -L sets both filesystem label and is visible in `lsblk -o LABEL`.
  # GPT PARTLABEL was already set by systemd-repart.
  mkfs.exfat -L "$USB_STORAGE_LABEL" "$part"
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
  install -d -m 0755 "$bundle_root/bin" "$bundle_root/installer" "$bundle_root/scripts/lib" "$bundle_root/mkosi.output" "$bundle_root/mkosi.sysupdate" "$bundle_root/deploy.repart"

  copy_file_preserving_layout "$PROJECT_ROOT/bin/bootstrap-ab-disk.sh" "$bundle_root/bin/bootstrap-ab-disk.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/installer/live-usb-install.sh" "$bundle_root/installer/live-usb-install.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/bin/sysupdate-local-update.sh" "$bundle_root/bin/sysupdate-local-update.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/scripts/lib/host-deps.sh" "$bundle_root/scripts/lib/host-deps.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/scripts/lib/build-meta.sh" "$bundle_root/scripts/lib/build-meta.sh"
  chmod 0755 "$bundle_root/bin/bootstrap-ab-disk.sh" "$bundle_root/installer/live-usb-install.sh" "$bundle_root/bin/sysupdate-local-update.sh"

  cp -a "${GENERATED_DEFINITIONS_DIR:-$PROJECT_ROOT/mkosi.sysupdate}/." "$bundle_root/mkosi.sysupdate/"
  cp -a "$PROJECT_ROOT/deploy.repart/." "$bundle_root/deploy.repart/"

  # The bundle's mkosi.output/ is flat (no builds/ subtree) because the
  # installer on the USB expects a single transfer-source directory. We
  # copy only the artifacts that installer + bootstrap need, and carry
  # build.env alongside so the installer has full identity info.
  local prefix="$IMAGE_ID""_""$IMAGE_VERSION""_""$IMAGE_ARCH"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.root.raw" "$bundle_root/mkosi.output/${prefix}.root.raw"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.efi" "$bundle_root/mkosi.output/${prefix}.efi"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.conf" "$bundle_root/mkosi.output/${prefix}.conf"
  copy_file_preserving_layout "$SOURCE_DIR/${prefix}.artifacts.env" "$bundle_root/mkosi.output/${prefix}.artifacts.env"
  copy_file_preserving_layout "$SOURCE_DIR/SHA256SUMS" "$bundle_root/mkosi.output/SHA256SUMS"
  copy_file_preserving_layout "$SOURCE_DIR/build.env" "$bundle_root/mkosi.output/build.env"

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
  $BUNDLE_DIR/installer/live-usb-install.sh

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
exec $BUNDLE_DIR/installer/live-usb-install.sh "\$@"
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
    "${AB_LAST_BUILD_PROFILE:-unknown}" \
    "${AB_LAST_BUILD_HOST:-}" \
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
    --build-dir)
      BUILD_DIR="${2:?missing build dir}"
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
    --no-usb-storage)
      INCLUDE_USB_STORAGE=false
      shift
      ;;
    --usb-storage-label)
      USB_STORAGE_LABEL="${2:?missing usb storage label}"
      shift 2
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

# mkfs.exfat (from exfatprogs) is only needed when the trailing USB
# storage partition is enabled. Install-and-check separately so
# --no-usb-storage users on hosts without exfatprogs keep working.
if [[ "$INCLUDE_USB_STORAGE" == true ]]; then
  if ! ab_hostdeps_have_all_commands mkfs.exfat; then
    ab_hostdeps_ensure_packages "USB exFAT storage partition" exfatprogs || exit 1
  fi
  ab_hostdeps_ensure_commands "USB exFAT storage partition" mkfs.exfat || {
    echo "==> Re-run with --no-usb-storage to skip the trailing exFAT partition if this host cannot provide mkfs.exfat." >&2
    exit 1
  }
fi

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
  # Skip sysupdate inside bootstrap. The USBDATA partition is
  # unformatted at this point (repart creates it without Format= and
  # we mkfs.exfat it ourselves below). systemd-dissect inside
  # sysupdate cannot handle the unformatted partition and fails with
  # "Failed to mount image: No such file or directory". We run
  # sysupdate ourselves after formatting USBDATA.
  --skip-sysupdate
)
# Propagate --allow-fixed-disk: confirm_usb_write_or_abort has already
# enforced the removable check; bootstrap's own check would otherwise
# reject the target again and there's no way for the user to recover
# without this pass-through.
[[ "$ALLOW_FIXED_DISK" == "yes" ]] && bootstrap_args+=(--allow-fixed-disk)
[[ -n "$IMAGE_ID" ]] && bootstrap_args+=(--image-id "$IMAGE_ID")

echo "==> Bootstrapping hardware test USB on $TARGET"
"$PROJECT_ROOT/bin/bootstrap-ab-disk.sh" "${bootstrap_args[@]}"

resolve_disk_device
# Format the trailing exFAT storage partition (if created by repart)
# BEFORE running sysupdate. This is critical: systemd-sysupdate uses
# systemd-dissect internally which fails with "Failed to mount image:
# No such file or directory" when it encounters the unformatted
# USBDATA partition (Type=linux-generic, no filesystem). Formatting
# it first gives dissect a valid filesystem to skip over via the
# image-policy. It's a no-op under --no-usb-storage or if repart did
# not allocate the partition.
format_usb_storage_partition

# Now seed the first system version. This runs after USBDATA is
# formatted so systemd-dissect can properly handle every partition on
# the disk.
SYSUPDATE_IMAGE_POLICY='root=unprotected+absent:esp=unprotected:=unused+absent'
# For block devices, sysupdate targets the device directly; for file
# images, it targets the file (sysupdate loop-attaches it internally).
SYSUPDATE_TARGET="$(readlink -f "$TARGET")"

echo "==> Seeding first system version with systemd-sysupdate"
echo "    definitions:     $GENERATED_DEFINITIONS_DIR"
if [[ -d "$GENERATED_DEFINITIONS_DIR" ]]; then
  transfer_files=()
  while IFS= read -r f; do
    transfer_files+=("$f")
  done < <(find "$GENERATED_DEFINITIONS_DIR" -maxdepth 1 -type f -name '*.transfer' | sort)
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
echo "    image:           $SYSUPDATE_TARGET"
echo "    image-policy:    $SYSUPDATE_IMAGE_POLICY"
echo "==> systemd-sysupdate list (probe, non-fatal):"
systemd-sysupdate \
  --definitions="$GENERATED_DEFINITIONS_DIR" \
  --transfer-source="$SOURCE_DIR" \
  --image="$SYSUPDATE_TARGET" \
  --image-policy="$SYSUPDATE_IMAGE_POLICY" \
  list 2>&1 | sed 's/^/    /' || true

systemd-sysupdate \
  --definitions="$GENERATED_DEFINITIONS_DIR" \
  --transfer-source="$SOURCE_DIR" \
  --image="$SYSUPDATE_TARGET" \
  --image-policy="$SYSUPDATE_IMAGE_POLICY" \
  update

ROOT_PART="$(wait_for_seeded_root_partition)" || die "unable to locate the seeded root partition on $TARGET (the USB was bootstrapped, but the newly-seeded root partition did not appear in time)"
ROOT_MOUNT="$(mktemp -d /tmp/ab-live-root.XXXXXX)"
mount "$ROOT_PART" "$ROOT_MOUNT"

copy_bundle

echo "==> Hardware test USB is ready"
echo "    Boot target:     $TARGET"
echo "    Seeded root:     $ROOT_PART"
echo "    Installer entry: /root/INSTALL-TO-INTERNAL-DISK.sh"
if [[ "$INCLUDE_USB_STORAGE" == true ]]; then
  STORAGE_PART="$(find_usb_storage_partition || true)"
  if [[ -n "$STORAGE_PART" ]]; then
    echo "    exFAT storage:   $STORAGE_PART (label=$USB_STORAGE_LABEL)"
  fi
fi
if [[ "$EMBED_FULL_IMAGE" == true ]]; then
  echo "    Full raw image:  copied into $BUNDLE_DIR/mkosi.output/"
fi
