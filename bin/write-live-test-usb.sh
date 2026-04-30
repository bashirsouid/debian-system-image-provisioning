#!/usr/bin/env bash
set -euo pipefail

# write-live-test-usb.sh
#
# High-level behavior
# -------------------
# This tool turns a removable USB disk (or raw image file) into a
# "hardware test" / installer USB with a systemd-repart + A/B root
# layout, and then copies an installer bundle onto the seeded root so
# you can:
#
#   - Boot real hardware from the USB
#   - Smoke-test the built image on that hardware
#   - Optionally install onto an internal disk from the running system
#
# Layout (on a fresh target)
# --------------------------
#   - GPT with:
#       * ESP         (vfat, label=ESP)
#       * root-a      (ext4, label=_empty initially)
#       * root-b      (ext4, label=_empty initially)
#       * USBDATA     (optional, exFAT, label=$USB_STORAGE_LABEL)
#
#   - systemd-boot installed into the ESP
#   - One root slot is "seeded" with the mkosi-produced *.root.raw,
#     and its GPT PARTLABEL is set to:
#
#         ${IMAGE_ID}_${IMAGE_VERSION}
#
#     This matches what the sysupdate transfer definitions expect.
#
# Seeding strategy (A/B behavior)
# -------------------------------
# We do NOT use `systemd-sysupdate --image=/dev/sdX` to seed the first
# version because current systemd releases are unreliable when
# dissecting a just-repartitioned, still-empty disk image in that mode
# (this is what caused "Failed to mount image: No such file or
# directory" / "No transfer definitions found."). Instead:
#
#   - On a freshly-partitioned drive (both roots labeled "_empty"):
#       * Seed the first root slot found with ${prefix}.root.raw
#       * Grow the ext4 filesystem to the full partition size
#       * Rename its GPT PARTLABEL to ${IMAGE_ID}_${IMAGE_VERSION}
#
#   - On reuse of an existing USB:
#       * If any root slot is still labeled "_empty", we seed that
#         slot and relabel it as above.
#       * If both root slots are already in use:
#           - With --yes: overwrite a deterministic slot (see
#             select_root_slot_for_seed()).
#           - Without --yes: show the candidate slots and prompt
#             for which one to overwrite (typed path).
#
# This keeps the on-disk layout compatible with the sysupdate-based
# installer and future A/B updates, while avoiding the fragile
# sysupdate --image flow for the initial seed.
#
# The installer bundle written into $BUNDLE_DIR on the seeded root
# carries:
#   - bootstrap-ab-disk.sh
#   - live-usb-install.sh
#   - sysupdate-local-update.sh
#   - mkosi.sysupdate/*.transfer
#   - deploy.repart/*.conf
#   - mkosi artifacts for ${IMAGE_ID}/${IMAGE_VERSION}/${IMAGE_ARCH}
#
# See the --help output below for CLI usage and options.

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
DIAGNOSTIC_MODE=false
# Mode tristate, chosen at arg-parse time and resolved into REFLASH below:
#   auto        - detect_existing_ab_layout() decides: reflash if an A/B
#                 layout is already on the target (non-destructive),
#                 repartition otherwise. This is the right default for
#                 day-to-day "I plugged in my old test USB and want the
#                 latest build on it" because it preserves USBDATA and
#                 the active root slot whenever it can.
#   reflash     - force --reflash; error out if the disk doesn't already
#                 have a valid A/B layout.
#   repartition - force a destructive systemd-repart bootstrap, even if
#                 the disk is already laid out correctly.
MODE="auto"
# REFLASH is the resolved boolean used by all the existing flow code.
# Computed from MODE after arg-parsing + load_build_metadata so user
# echo lines can name the resolved disk path.
REFLASH=false
LUKS_PASSPHRASE=""    # passphrase for LUKS-encrypted roots (--luks-passphrase)
LUKS_MAP=""           # mapper name opened by seed_first_root_slot; closed by cleanup()
LUKS_PASS_FILE=""     # tmpfile holding passphrase; shredded by cleanup()
USBDATA_BUNDLE_MOUNT="" # set by copy_bundle() when bundle overflows to USBDATA

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
  --diagnostic-mode     append initrd debug params to the boot entry
  --luks-passphrase PASSPHRASE
                        passphrase for a LUKS-encrypted root partition. Required
                        when *.root.raw uses LUKS (auto-detected after dd). The
                        passphrase is fed to cryptsetup via stdin and is not
                        stored anywhere on the USB.
  --reflash             FORCE reflash mode: do NOT repartition. Detect the
                        existing A/B layout, write the new image into the
                        *inactive* root slot, and leave the active slot +
                        USBDATA untouched. Errors out if the target has no
                        valid A/B layout. This is the same as the auto
                        default when a layout is already present; pass it
                        explicitly to fail fast on a fresh disk.
  --reimage, --repartition
                        FORCE destructive bootstrap: wipe everything on the
                        target and re-create the GPT layout (ESP + 2 root
                        slots + USBDATA). Use this when you want a fully
                        fresh USB even though an A/B layout already exists,
                        e.g. to switch image-id schemes or recover from a
                        broken layout.

By default (no --reflash, no --repartition), the tool detects whether the
target already has a valid A/B layout and picks the right mode automatically:
present-layout → reflash, fresh-disk → repartition. The chosen mode is
printed before the destructive-confirmation prompt.
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
    if [[ -n "${LUKS_PASS_FILE:-}" && -f "${LUKS_PASS_FILE}" ]]; then
        shred -u "$LUKS_PASS_FILE" 2>/dev/null || rm -f "$LUKS_PASS_FILE"
        LUKS_PASS_FILE=""
    fi
    if [[ -n "${LUKS_MAP:-}" ]]; then
        cryptsetup luksClose "$LUKS_MAP" >/dev/null 2>&1 || true
        LUKS_MAP=""
    fi
    if [[ -n "${USBDATA_BUNDLE_MOUNT:-}" ]]; then
        mountpoint -q "$USBDATA_BUNDLE_MOUNT" 2>/dev/null \
            && umount "$USBDATA_BUNDLE_MOUNT" 2>/dev/null || true
        [[ -d "$USBDATA_BUNDLE_MOUNT" ]] \
            && rmdir "$USBDATA_BUNDLE_MOUNT" 2>/dev/null || true
    fi
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
  if [[ "$REFLASH" == true ]]; then
    echo "===================================================================="
    echo "RE-FLASH (non-destructive): writes to the *inactive* root slot only;"
    echo "the active slot, USBDATA partition, and ESP fallback entries are kept."
    echo "===================================================================="
  else
    echo "===================================================================="
    echo "DESTRUCTIVE OPERATION: all partition data on the target will be lost"
    echo "===================================================================="
  fi
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

  if [[ "$REFLASH" == true ]]; then
    echo "Current partition table on target (will be REUSED in --reflash mode):"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINT "$(readlink -f "$TARGET")" 2>/dev/null \
      || echo "  (lsblk failed)"
    echo
  else
    preview_current_and_planned_layout
  fi

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
  local line NAME PARTLABEL FSTYPE TYPE
  while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue
    [[ -n "$NAME" ]] || continue

    case "$PARTLABEL" in
      ESP|_empty|HOME|DATA|USBDATA)
        continue
        ;;
    esac

    # fstype check is now just a hint; we mostly care about the label
    if [[ "$PARTLABEL" == "${IMAGE_ID}_${IMAGE_VERSION}" || "$PARTLABEL" == ${IMAGE_ID}_* ]]; then
      printf '%s\n' "$NAME"
      return 0
    fi
  done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

  # Fallback: any non-reserved partition
  while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue
    [[ -n "$NAME" ]] || continue

    case "$PARTLABEL" in
      ESP|_empty|HOME|DATA|USBDATA)
        continue
        ;;
    esac
    printf '%s\n' "$NAME"
    return 0
  done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

  return 1
}

# Select a root partition to seed with the current image.
# Strategy:
#   - Prefer any root partition with PARTLABEL=_empty
#   - Otherwise, if --yes is NOT set, prompt the user to choose
#   - With --yes, deterministically pick the "oldest-looking"
#     slot (lexicographically smallest PARTLABEL) so repeated
#     invocations are predictable.
select_root_slot_for_seed() {
    local line NAME PARTLABEL FSTYPE TYPE candidates=() labels=()

    while IFS= read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        [[ -n "$NAME" ]] || continue

        case "$PARTLABEL" in
            ESP|HOME|DATA|USBDATA)
                continue
                ;;
        esac
        # root slots are usually ext4 but can be crypto_LUKS if encrypted
        [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]] || continue

        candidates+=("$NAME")
        labels+=("$PARTLABEL")
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

    (( ${#candidates[@]} > 0 )) || die "no candidate root partitions found on $DISK_DEVICE"

    # 1) Prefer an "_empty" slot
    for i in "${!candidates[@]}"; do
        if [[ "${labels[$i]}" == "_empty" ]]; then
            ROOT_PART="${candidates[$i]}"
            echo "==> Selected empty root slot for seed: $ROOT_PART (label=_empty)"
            return 0
        fi
    done

    # 2) If not in --yes mode, ask the user which slot to overwrite
    if [[ "$ASSUME_YES" != true ]]; then
        echo "Existing root slots on $DISK_DEVICE:"
        for i in "${!candidates[@]}"; do
            printf "  [%d] %s (PARTLABEL=%s)\n" "$i" "${candidates[$i]}" "${labels[$i]}"
        done
        echo
        echo "All root slots appear to be in use. Choose which one to overwrite."
        echo "Type the full device path (e.g. ${candidates[0]}) and press Enter:"
        read -r choice
        for i in "${!candidates[@]}"; do
            if [[ "$choice" == "${candidates[$i]}" ]]; then
                ROOT_PART="$choice"
                echo "==> Selected root slot for seed: $ROOT_PART (label=${labels[$i]})"
                return 0
            fi
        done
        die "no matching root slot for choice: $choice"
    fi

    # 3) With --yes and no _empty slots, pick a deterministic slot:
    #    lowest lexicographic PARTLABEL, fallback to first candidate.
    local best_idx=0 best_label="${labels[0]}"
    for i in "${!labels[@]}"; do
        if [[ "${labels[$i]}" < "$best_label" ]]; then
            best_label="${labels[$i]}"
            best_idx="$i"
        fi
    done

    ROOT_PART="${candidates[$best_idx]}"
    echo "==> Selected root slot for seed (auto --yes): $ROOT_PART (PARTLABEL=${labels[$best_idx]})"
    return 0
}

# --reflash helpers ---------------------------------------------------------

# Non-destructive "is there already an A/B layout here?" probe. Used by
# the auto-mode dispatcher to decide between reflash and repartition.
# Returns 0 if the target has ≥1 ESP partition and ≥2 root-shaped slots
# (ext4 or unformatted, PARTLABEL not in {ESP,USBDATA,DATA,HOME});
# returns 1 in every other case. Never dies — even on a fresh disk
# with no partition table, lsblk is a clean no-op and we just return 1.
#
# Operates on a read-only loop attach for file targets so detection
# doesn't disturb the bootstrap path that re-attaches its own loop
# device. Block-device targets are inspected with lsblk directly.
detect_existing_ab_layout() {
  local target_real device tmp_loop=""
  target_real="$(readlink -f "$TARGET")"

  if [[ -b "$target_real" ]]; then
    device="$target_real"
  elif [[ -f "$target_real" ]]; then
    tmp_loop="$(losetup --find --show --partscan --read-only "$target_real" 2>/dev/null || true)"
    [[ -n "$tmp_loop" ]] || return 1
    device="$tmp_loop"
  else
    return 1
  fi

  local line NAME PARTLABEL FSTYPE TYPE esp_count=0 root_count=0
  while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue

    case "$PARTLABEL" in
      ESP)
        esp_count=$((esp_count + 1))
        ;;
      USBDATA|DATA|HOME)
        ;;
      *)
        if [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]]; then
          root_count=$((root_count + 1))
        fi
        ;;
    esac
  done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$device" 2>/dev/null)

  [[ -n "$tmp_loop" ]] && losetup -d "$tmp_loop" >/dev/null 2>&1 || true

  (( esp_count >= 1 && root_count >= 2 ))
}

# Validate that $DISK_DEVICE already has the GPT layout we expect:
# at least one ESP partition and two root-shaped partitions (ext4 or
# unformatted, PARTLABEL not in {ESP,USBDATA,DATA,HOME}). Errors out
# if the layout cannot be reused — the user should either drop
# --reflash to do a destructive bootstrap, or fix the disk manually.
validate_existing_ab_layout() {
    local line NAME PARTLABEL FSTYPE TYPE esp_count=0 root_count=0

    while read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue

        case "$PARTLABEL" in
            ESP)
                esp_count=$((esp_count + 1))
                ;;
            USBDATA|DATA|HOME)
                continue
                ;;
            *)
                if [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]]; then
                    root_count=$((root_count + 1))
                fi
                ;;
        esac
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

    (( esp_count >= 1 )) \
        || die "--reflash: target $DISK_DEVICE has no ESP partition; do a fresh write (drop --reflash) first"
    (( root_count >= 2 )) \
        || die "--reflash: target $DISK_DEVICE has fewer than 2 root slots ($root_count found); do a fresh write (drop --reflash) first"
}

# Read the loader.conf `default` entry on the USB's ESP and return
# the PARTUUID that entry's `options root=PARTUUID=...` resolves to.
# Empty string if the ESP can't be read, the default entry file
# is missing, or the entry has no root=PARTUUID= option.
#
# We match by PARTUUID rather than by PARTLABEL because a fresh-write
# always sets BOTH slots' PARTLABELs to "${IMAGE_ID}_${IMAGE_VERSION}"
# (sysupdate convention), and after the first reseed both slots end
# up with the same PARTLABEL — making PARTLABEL useless for telling
# the slots apart. PARTUUID, on the other hand, is assigned per-slot
# at systemd-repart time and stays stable as long as we don't
# repartition, so it's the right key for identifying "the slot the
# user is currently booting from".
read_default_entry_root_partuuid() {
    local esp_part esp_mount default_line default_entry options_line result="" line NAME PARTLABEL FSTYPE TYPE
    while read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        if [[ "$PARTLABEL" == "ESP" || "$FSTYPE" == "vfat" ]]; then
            esp_part="$NAME"
            break
        fi
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")
    [[ -n "$esp_part" ]] || { printf ''; return 0; }

    esp_mount="$(mktemp -d /tmp/ab-reflash-esp.XXXXXX)"
    if ! mount -o ro "$esp_part" "$esp_mount" 2>/dev/null; then
        rmdir "$esp_mount"
        printf ''
        return 0
    fi

    if [[ -f "$esp_mount/loader/loader.conf" ]]; then
        default_line="$(awk '/^default / { print $2; exit }' "$esp_mount/loader/loader.conf" || true)"
        default_entry="${default_line%.conf}"
        if [[ -n "$default_entry" && -f "$esp_mount/loader/entries/${default_entry}.conf" ]]; then
            options_line="$(awk '/^options / { sub(/^options /, ""); print; exit }' \
                "$esp_mount/loader/entries/${default_entry}.conf")"
            # Pull the PARTUUID value out of `root=PARTUUID=XXX`.
            # Use bash regex so we don't depend on awk/sed niceties.
            if [[ "$options_line" =~ root=PARTUUID=([A-Fa-f0-9-]+) ]]; then
                result="${BASH_REMATCH[1]}"
            fi
        fi
    fi

    umount "$esp_mount" 2>/dev/null || true
    rmdir "$esp_mount" 2>/dev/null || true
    printf '%s' "$result"
}

# --reflash slot selector. Picks the root slot whose PARTUUID is NOT
# the one referenced by the current loader.conf default entry's
# `root=PARTUUID=...` option — i.e. the slot the user is NOT booting
# from. Falls back to "_empty preferred, otherwise lex-smallest" if
# loader.conf can't be parsed.
select_inactive_root_slot_for_reseed() {
    local line NAME PARTLABEL FSTYPE TYPE partuuid
    local -a candidates=() labels=() partuuids=()
    local i active_partuuid active_idx=-1

    while IFS= read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        [[ -n "$NAME" ]] || continue

        case "$PARTLABEL" in
            ESP|USBDATA|DATA|HOME)
                continue
                ;;
        esac
        [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]] || continue

        partuuid="$(blkid -s PARTUUID -o value "$NAME" 2>/dev/null || true)"
        candidates+=("$NAME")
        labels+=("$PARTLABEL")
        partuuids+=("$partuuid")
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

    (( ${#candidates[@]} >= 2 )) \
        || die "--reflash: expected ≥2 root slots on $DISK_DEVICE, found ${#candidates[@]}"

    # 1) An empty slot is unambiguously "not the active one".
    for i in "${!candidates[@]}"; do
        if [[ "${labels[$i]}" == "_empty" ]]; then
            ROOT_PART="${candidates[$i]}"
            echo "==> --reflash: selected empty slot $ROOT_PART (label=_empty)"
            return 0
        fi
    done

    # 2) Match loader.conf default's root=PARTUUID against candidate PARTUUIDs.
    active_partuuid="$(read_default_entry_root_partuuid)"
    if [[ -n "$active_partuuid" ]]; then
        for i in "${!candidates[@]}"; do
            # PARTUUID comparison is case-insensitive in practice (some tools
            # uppercase, others lowercase). Normalize both sides.
            if [[ "${partuuids[$i]^^}" == "${active_partuuid^^}" ]]; then
                active_idx="$i"
                break
            fi
        done
    fi

    if (( active_idx >= 0 )); then
        for i in "${!candidates[@]}"; do
            if (( i != active_idx )); then
                ROOT_PART="${candidates[$i]}"
                echo "==> --reflash: selected inactive slot $ROOT_PART"
                echo "    (active is ${candidates[$active_idx]} PARTUUID=${active_partuuid})"
                return 0
            fi
        done
    fi

    # 3) Couldn't identify the active slot. With --yes pick the first
    # non-_empty candidate deterministically. Otherwise fall through
    # to the existing interactive picker.
    echo "==> --reflash: could not determine the active slot from loader.conf"
    echo "    (loader.conf default=$(read_default_entry_root_partuuid || echo none))"
    if [[ "$ASSUME_YES" == true ]]; then
        ROOT_PART="${candidates[0]}"
        echo "==> --reflash: --yes, defaulting to first candidate $ROOT_PART (PARTLABEL=${labels[0]})"
        return 0
    fi
    select_root_slot_for_seed
}

# Returns 0 if the existing USBDATA partition already has a usable
# filesystem (exfat/vfat/ntfs/etc) — i.e. a re-flash should NOT mkfs
# it, because that wipes the user's USB-stick contents which is
# precisely the regression --reflash is meant to avoid.
usbdata_partition_already_formatted() {
    local part fstype
    part="$(find_usb_storage_partition || true)"
    [[ -n "$part" ]] || return 1
    fstype="$(blkid -s TYPE -o value "$part" 2>/dev/null || true)"
    [[ -n "$fstype" ]] || return 1
    return 0
}
# --- end --reflash helpers -------------------------------------------------

# Seed the chosen ROOT_PART with ${prefix}.root.raw and relabel it to
# ${IMAGE_ID}_${IMAGE_VERSION}. This replaces the previous
# systemd-sysupdate --image seeding flow.
seed_first_root_slot() {
    local prefix partnum new_label
    
    [[ -n "${IMAGE_ID:-}" && -n "${IMAGE_VERSION:-}" && -n "${IMAGE_ARCH:-}" ]] \
        || die "seed_first_root_slot: IMAGE_ID/IMAGE_VERSION/IMAGE_ARCH not set"
    
    prefix="${IMAGE_ID}_${IMAGE_VERSION}_${IMAGE_ARCH}"
    [[ -f "$SOURCE_DIR/${prefix}.root.raw" ]] \
        || die "root filesystem image not found: $SOURCE_DIR/${prefix}.root.raw"

    if [[ "$REFLASH" == true ]]; then
        select_inactive_root_slot_for_reseed
    else
        select_root_slot_for_seed
    fi
    
    # Write the filesystem image into the chosen partition
    echo "==> Writing root filesystem image into $ROOT_PART from ${prefix}.root.raw"
    dd if="$SOURCE_DIR/${prefix}.root.raw" of="$ROOT_PART" bs=4M status=progress conv=fsync
    
    # Detect the root filesystem type so LUKS-specific paths skip steps
    # that only apply to plain ext4 roots.
    local root_fstype
    root_fstype="$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null || true)"
    echo "==> Detected root partition type: ${root_fstype:-unknown}"

    # Grow the ext4 filesystem to fill the partition (best-effort).
    # Skip entirely for LUKS: e2fsck misreads the LUKS header as a corrupt
    # ext4 superblock and irrecoverably overwrites LUKS metadata.
    if [[ "$root_fstype" == "crypto_LUKS" ]]; then
        echo "==> Root is LUKS-encrypted; skipping e2fsck/resize2fs"
    elif command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
        echo "==> Running e2fsck + resize2fs on $ROOT_PART"
        e2fsck -f -y "$ROOT_PART" || true
        resize2fs "$ROOT_PART" || true
    else
        echo "WARNING: e2fsck/resize2fs not available; skipping filesystem grow step" >&2
    fi
    
    # Update the GPT PARTLABEL for this partition so it encodes
    # IMAGE_ID + IMAGE_VERSION. We assume util-linux (sfdisk) is present.
    new_label="${IMAGE_ID}_${IMAGE_VERSION}"
    partnum="${ROOT_PART##*[!0-9]}"
    if command -v sfdisk >/dev/null 2>&1; then
        if [[ -n "$partnum" ]]; then
            echo "==> Setting GPT PARTLABEL for $ROOT_PART -> $new_label"
            sfdisk --part-label "$DISK_DEVICE" "$partnum" "$new_label" || \
                echo "WARNING: failed to update PARTLABEL for $ROOT_PART" >&2
        else
            echo "WARNING: could not determine partition number for $ROOT_PART; PARTLABEL unchanged" >&2
        fi
    else
        echo "WARNING: sfdisk not available; leaving PARTLABEL for $ROOT_PART unchanged" >&2
    fi
    
    # Wait for block devices to reappear after sfdisk altered the partition table
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 >/dev/null 2>&1 || true
    fi
    
    # A tiny sleep ensures that even if udevadm returns instantly, the kernel has 
    # definitely finished recreating the /dev/sdaX nodes before mount fires.
    sleep 2
    
    # Mount the seeded root for bundle copy
    ROOT_MOUNT="$(mktemp -d /tmp/ab-live-root.XXXXXX)"
    echo "==> Mounting seeded root $ROOT_PART on $ROOT_MOUNT"
    if [[ "$root_fstype" == "crypto_LUKS" ]]; then
        command -v cryptsetup >/dev/null 2>&1 \
            || die "cryptsetup is required to mount a LUKS-encrypted root; install cryptsetup on the build host"
        # ── Passphrase handling ───────────────────────────────────────────
        # Write passphrase to a chmod-600 tmpfile so luksOpen and resize
        # both use --key-file= (no pipe/stdin races). Loop on empty input
        # or wrong passphrase so a stray Enter from a previous step does
        # not silently abort the flash.
        local _luks_pass_file
        _luks_pass_file="$(mktemp /tmp/ab-luks-pass.XXXXXX)"
        chmod 600 "$_luks_pass_file"
        LUKS_PASS_FILE="$_luks_pass_file"   # registered for cleanup

        local luks_map="ab-live-root-luks-$$"

        if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
            # Passphrase already supplied externally (e.g. by a parent script).
            printf '%s' "$LUKS_PASSPHRASE" > "$_luks_pass_file"
            echo "==> Opening LUKS container $ROOT_PART -> /dev/mapper/$luks_map"
            cryptsetup luksOpen "$ROOT_PART" "$luks_map" --key-file="$_luks_pass_file"
        else
            echo "==> $ROOT_PART is LUKS-encrypted and no passphrase was supplied"
            local _luks_attempts=0
            while true; do
                (( _luks_attempts++ )) || true
                LUKS_PASSPHRASE=""
                read -rsp "    Enter LUKS passphrase (input hidden, not saved to history): " \
                    LUKS_PASSPHRASE </dev/tty
                echo >&2   # newline after hidden input
                if [[ -z "$LUKS_PASSPHRASE" ]]; then
                    echo "    (empty passphrase — please try again)" >&2
                    continue
                fi
                printf '%s' "$LUKS_PASSPHRASE" > "$_luks_pass_file"
                echo "==> Opening LUKS container $ROOT_PART -> /dev/mapper/$luks_map"
                if cryptsetup luksOpen "$ROOT_PART" "$luks_map" \
                        --key-file="$_luks_pass_file" 2>/dev/null; then
                    break   # success
                fi
                # Wrong passphrase — clear file and retry
                printf '%s' "" > "$_luks_pass_file"
                if (( _luks_attempts >= 5 )); then
                    die "Failed to open LUKS container $ROOT_PART after 5 attempts"
                fi
                echo "    Incorrect passphrase (attempt $_luks_attempts/5), try again." >&2
            done
        fi
        LUKS_MAP="$luks_map"
        # The .root.raw image is smaller than the allocated partition.
        # Expand the LUKS container to fill the full partition, then grow
        # the inner filesystem to match — otherwise the root has no free
        # space for the installer bundle.
        echo "==> Expanding LUKS container $luks_map to fill partition $ROOT_PART"
        cryptsetup resize "$luks_map" --key-file="$_luks_pass_file"
        if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
            echo "==> Running e2fsck + resize2fs on /dev/mapper/$luks_map"
            e2fsck -f -y "/dev/mapper/$luks_map" || true
            resize2fs "/dev/mapper/$luks_map" || true
        else
            echo "WARNING: e2fsck/resize2fs not available; inner filesystem not grown" >&2
        fi
        mount "/dev/mapper/$luks_map" "$ROOT_MOUNT"
    else
        mount "$ROOT_PART" "$ROOT_MOUNT"
    fi

    # Determine PARTUUID of the seeded root partition for boot entry
    local root_partuuid="" luks_uuid=""
    if command -v blkid >/dev/null 2>&1; then
        root_partuuid="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
        if [[ -z "$root_partuuid" ]]; then
            echo "WARNING: could not determine PARTUUID for $ROOT_PART; boot entry will not be patched" >&2
        else
            echo "==> Seeded root PARTUUID: $root_partuuid"
        fi
        # For LUKS roots, also capture the LUKS header UUID (different from PARTUUID).
        # blkid -s UUID on a LUKS partition returns the UUID stored inside the LUKS
        # header, which is what rd.luks.uuid= / cryptdevice=UUID= must reference.
        if [[ "$root_fstype" == "crypto_LUKS" ]]; then
            luks_uuid="$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)"
            [[ -n "$luks_uuid" ]] && echo "==> LUKS container UUID: $luks_uuid"
        fi
    else
        echo "WARNING: blkid not available; boot entry will not be patched with PARTUUID." >&2
    fi

    # --- Seed the ESP ---
    # We also need to copy the UKI (.efi) and bootloader entry (.conf) to the ESP,
    # because we skipped systemd-sysupdate which normally handles this step.
    
    # Wait for udev to see the new partitions from systemd-repart
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=5 >/dev/null 2>&1 || true
    fi
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt "$DISK_DEVICE" >/dev/null 2>&1 || true
    fi
    
    local esp_part="" line NAME PARTLABEL FSTYPE TYPE
    while read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        if [[ "$PARTLABEL" == "ESP" ]]; then
            esp_part="$NAME"
            break
        fi
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")
    if [[ -n "$esp_part" ]]; then
        local esp_mount
        esp_mount="$(mktemp -d /tmp/ab-live-esp.XXXXXX)"
        echo "==> Mounting ESP $esp_part to seed bootloader files"
        mount "$esp_part" "$esp_mount"
        
        install -d -m 0755 "$esp_mount/EFI/Linux" "$esp_mount/loader/entries"

        # In --reflash mode the entry filename is suffixed with the
        # target slot's basename so both A and B slots can coexist as
        # named entries in /loader/entries/. The previously-default
        # entry stays in place as a known-good fallback you can pick
        # from the systemd-boot menu if the new one fails to come up.
        # In fresh-write mode the entry file is just ${prefix}.conf
        # and any stale entries from a previous flash get wiped, since
        # the rest of the disk has already been repartitioned anyway.
        local entry_basename
        if [[ "$REFLASH" == true ]]; then
            entry_basename="${prefix}_$(basename "$ROOT_PART")"
            echo "==> --reflash: keeping previously-installed boot entries as fallback"
        else
            entry_basename="${prefix}"
            echo "==> Wiping old boot entries from USB ESP"
            rm -f "$esp_mount/loader/entries/"*.conf
        fi

        # Set the new entry as the explicit default in loader.conf so
        # systemd-boot picks the freshly-flashed slot on next boot.
        echo "==> Setting ${entry_basename}.conf as the default boot entry"
        if [[ -f "$esp_mount/loader/loader.conf" ]]; then
            sed -i -E "s/^default .*/default ${entry_basename}.conf/" "$esp_mount/loader/loader.conf"
        else
            printf "default %s.conf\ntimeout 5\nconsole-mode keep\n" "${entry_basename}" > "$esp_mount/loader/loader.conf"
        fi
        
        # ── Extract kernel + initrd from the UKI for Type 1 BLS booting ──────────
        # Why not boot the UKI as Type 2: systemd-stub bakes its cmdline into the
        # .cmdline PE section at UKI build time. For Type 2 entries the .conf's
        # `options` line is treated inconsistently across systemd-boot versions
        # (sometimes appended, sometimes ignored), and the previous fix that
        # patched the UKI's .cmdline section in-place via `objcopy --update-section`
        # is fragile: PE section sizes are fixed at build, and growing the cmdline
        # past the existing pad shifts later sections, corrupting the UKI and
        # producing exactly the "boot failure with no useful message" symptom.
        #
        # Type 1 BLS sidesteps the whole problem: kernel and initrd are loaded
        # directly from named files on the ESP, and `options` in the .conf is
        # the authoritative cmdline. No post-build rewriting required.
        #
        # `objcopy -O binary --only-section=` is a *read* operation that emits a
        # fresh file — it does not mutate the UKI, so the PE-vs-ELF target
        # ambiguity that broke `--update-section` does not apply here.
        local _uki_src=""
        if [[ -f "$SOURCE_DIR/${prefix}.efi" ]]; then
            _uki_src="$SOURCE_DIR/${prefix}.efi"
        fi

        if [[ -n "$_uki_src" ]]; then
            if ! command -v objcopy >/dev/null 2>&1; then
                die "objcopy is required to extract kernel/initrd from the UKI; install binutils on the build host"
            fi

            local _kernel_dst="$esp_mount/EFI/Linux/${prefix}.linux"
            local _initrd_dst="$esp_mount/EFI/Linux/${prefix}.initrd"

            # Clean up stale kernel/initrd files from PREVIOUS reflashes into
            # this same slot so old versions do not accumulate on the ESP.
            # We delete any *.linux / *.initrd file whose name starts with
            # IMAGE_ID_IMAGE_ARCH (same image family) but is NOT the current
            # prefix (i.e. an older version).  This keeps exactly 2 pairs on
            # the ESP at any time — one per slot — regardless of reflash count.
            local _img_base="${IMAGE_ID}_${IMAGE_ARCH}"
            find "$esp_mount/EFI/Linux/" -maxdepth 1 \
                \( -name "${_img_base}_*.linux"  -o -name "${_img_base}_*.initrd" \
                   -o -name "${_img_base}.linux"  -o -name "${_img_base}.initrd" \) \
                ! -name "${prefix}.linux" ! -name "${prefix}.initrd" \
                -delete 2>/dev/null || true

            echo "==> Extracting .linux from UKI -> $(basename "$_kernel_dst")"
            objcopy -O binary --only-section=.linux "$_uki_src" "$_kernel_dst"
            echo "==> Extracting .initrd from UKI -> $(basename "$_initrd_dst")"
            objcopy -O binary --only-section=.initrd "$_uki_src" "$_initrd_dst"

            [[ -s "$_kernel_dst" ]] || die "extracted kernel from UKI is empty (.linux section missing or unreadable)"
            [[ -s "$_initrd_dst" ]] || die "extracted initrd from UKI is empty (.initrd section missing or unreadable)"

            chmod 0644 "$_kernel_dst" "$_initrd_dst"

            # Diagnostic: confirm the T2 keyboard/touchbar modules actually made
            # it into the initrd. Without these the built-in keyboard is dead
            # before the real root is up, so Ctrl+Alt+F<n> can't switch tty.
            if command -v lsinitramfs >/dev/null 2>&1; then
                if lsinitramfs "$_initrd_dst" 2>/dev/null | grep -qE 'apple_bce|apple-bce|apple_ib|apple-ib|appletb'; then
                    echo "==> Initrd contains Apple T2 keyboard/touchbar modules"
                else
                    echo "WARNING: initrd does NOT appear to contain apple_bce / apple_ib_* / appletb modules." >&2
                    echo "         Built-in MacBook keyboard will not work in early boot," >&2
                    echo "         and Ctrl+Alt+F<n> will not switch tty before /sysroot mounts." >&2
                    echo "         Use an external USB keyboard, or rebuild with mkosi.finalize" >&2
                    echo "         forcing update-initramfs after ExtraTrees are applied." >&2
                fi
            fi
        else
            die "no UKI found at $SOURCE_DIR/${prefix}.efi; cannot construct Type 1 BLS entry"
        fi

        if [[ -f "$SOURCE_DIR/${prefix}.conf" ]]; then
            # entry_basename is set above; in --reflash mode it's
            # ${prefix}_<root-slot-basename>, otherwise ${prefix}.
            local conf_dest="$esp_mount/loader/entries/${entry_basename}.conf"

            # Read source options (everything after the leading "options ").
            local _src_options
            _src_options="$(grep '^options ' "$SOURCE_DIR/${prefix}.conf" | sed 's/^options //')"

            # Replace any baked-in root= (the build-time value uses PARTLABEL,
            # but PARTUUID is what we just learned from the actual seeded slot).
            if [[ -n "$root_partuuid" ]]; then
                _src_options="$(echo "$_src_options" | sed -E 's#root=[^ ]*##g')"
                if [[ "$root_fstype" == "crypto_LUKS" && -n "$luks_uuid" ]]; then
                    # LUKS root: the initrd must unlock the LUKS container before it
                    # can mount /sysroot. rd.luks.uuid tells systemd-cryptsetup (or
                    # cryptsetup-initramfs) which container to unlock; the mapper
                    # device is then available as /dev/mapper/luks-<UUID>.
                    # Note: luks_uuid is the UUID from the LUKS header (blkid UUID),
                    # NOT the GPT PARTUUID — they are different values.
                    _src_options="rd.luks.uuid=$luks_uuid root=/dev/mapper/luks-$luks_uuid rootwait $_src_options"
                    echo "==> Setting rd.luks.uuid=$luks_uuid root=/dev/mapper/luks-$luks_uuid in boot entry"
                elif [[ "$root_fstype" == "crypto_LUKS" ]]; then
                    echo "WARNING: could not determine LUKS UUID; boot entry may not unlock the root" >&2
                    _src_options="root=PARTUUID=$root_partuuid rootwait $_src_options"
                    echo "==> Setting root=PARTUUID=$root_partuuid in boot entry (LUKS UUID unknown)"
                else
                    _src_options="root=PARTUUID=$root_partuuid rootfstype=ext4 rootwait $_src_options"
                    echo "==> Setting root=PARTUUID=$root_partuuid in boot entry"
                fi
            else
                echo "WARNING: root PARTUUID unknown; leaving boot entry root= unchanged." >&2
            fi

            if [[ "$DIAGNOSTIC_MODE" == true ]]; then
                echo "==> Diagnostic mode: appending initrd debug params to boot entry"
                _src_options="${_src_options//quiet/}"
                # initramfs-tools-only flags (no rd.break, no
                # systemd.unit=debug-shell.service — both have caused boot
                # regressions before and neither helps here).
                local _diag_extras="break=mount break=bottom panic=0 loglevel=7 earlyprintk=vga systemd.log_level=debug systemd.log_target=console systemd.journald.forward_to_console=1 console=tty0 systemd.show_status=1 systemd.setenv=SYSTEMD_SULOGIN_FORCE=1 systemd.debug-shell=1"
                for p in $_diag_extras; do
                    if ! grep -qw "$p" <<<"$_src_options"; then
                        _src_options="$_src_options $p"
                    fi
                done
            fi

            # Collapse whitespace so the final cmdline is tidy in logs.
            _src_options="$(echo "$_src_options" | tr -s ' ' | sed -E 's#^ +##; s# +$##')"

            # Write a Type 1 BLS entry. Crucially: NO `uki` line, so systemd-boot
            # uses linux=/initrd=/options= directly and does not look for an
            # embedded cmdline.
            local _slot_tag=""
            [[ "$REFLASH" == true ]] && _slot_tag=" [slot=$(basename "$ROOT_PART")]"

            {
                echo "# Generated by bin/write-live-test-usb.sh (Type 1 BLS for live-test USB)"
                echo "title Debian TEST BOOT (${IMAGE_ID}) ${IMAGE_VERSION}${_slot_tag}"
                # sort-key includes slot basename so multiple coexisting
                # entries (one per slot) sort deterministically in the
                # systemd-boot menu instead of all collapsing on top of
                # each other and confusing the user about which is which.
                echo "sort-key ${IMAGE_ID}_$(basename "$ROOT_PART")"
                echo "version ${IMAGE_VERSION}"
                echo "linux /EFI/Linux/${prefix}.linux"
                echo "initrd /EFI/Linux/${prefix}.initrd"
                echo "options ${_src_options}"
            } > "$conf_dest"

            echo "==> Wrote Type 1 BLS boot entry: $conf_dest"
            echo "    cmdline: ${_src_options}"
        fi
        
        umount "$esp_mount"
        rmdir "$esp_mount"
    else
        echo "WARNING: Could not locate ESP partition to copy bootloader files." >&2
    fi
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
  local line NAME PARTLABEL FSTYPE TYPE
  while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue
    if [[ "$PARTLABEL" == "$USB_STORAGE_LABEL" ]]; then
      printf '%s\n' "$NAME"
      return 0
    fi
  done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")
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

  local usbdata_fallback=false

  if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < required + headroom )); then
    # Root has insufficient free space (common when the root image nearly fills
    # the slot, e.g. a 6 GiB LUKS image in an 8 GiB partition, leaving only
    # ~2 GiB free but the bundle needs ~6.5 GiB). Fall back to USBDATA which
    # typically has tens of GiB free, then plant a wrapper on the root that
    # mounts USBDATA and launches the installer from there.
    local usbdata_part
    usbdata_part="$(find_usb_storage_partition || true)"
    if [[ -z "$usbdata_part" ]]; then
      die "USB root filesystem does not have enough free space for the installer bundle (need about $(( (required + headroom) / 1024 / 1024 )) MiB free); no USBDATA partition available"
    fi
    echo "==> Root has $(( avail / 1024 / 1024 )) MiB free; bundle needs $(( (required + headroom) / 1024 / 1024 )) MiB"
    echo "==> Falling back: copying installer bundle to USBDATA ($usbdata_part)"
    USBDATA_BUNDLE_MOUNT="$(mktemp -d /tmp/ab-usbdata.XXXXXX)"
    mount "$usbdata_part" "$USBDATA_BUNDLE_MOUNT"
    local usbdata_avail
    usbdata_avail="$(df -B1 --output=avail "$USBDATA_BUNDLE_MOUNT" | tail -n1 | tr -d '[:space:]')" 
    if ! [[ "$usbdata_avail" =~ ^[0-9]+$ ]] || (( usbdata_avail < required + headroom )); then
      die "installer bundle needs $(( (required + headroom) / 1024 / 1024 )) MiB; root $(( avail / 1024 / 1024 )) MiB, USBDATA ${usbdata_avail:-0} bytes — not enough on either"
    fi
    bundle_root="$USBDATA_BUNDLE_MOUNT/ab-installer"
    usbdata_fallback=true
  fi

  echo "==> Copying installer bundle into ${usbdata_fallback:+USBDATA }$bundle_root"
  install -d -m 0700 "$bundle_root"
  install -d -m 0755 "$bundle_root/bin" "$bundle_root/installer" "$bundle_root/scripts/lib" "$bundle_root/mkosi.output" "$bundle_root/mkosi.sysupdate" "$bundle_root/deploy.repart"

  copy_file_preserving_layout "$PROJECT_ROOT/bin/bootstrap-ab-disk.sh" "$bundle_root/bin/bootstrap-ab-disk.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/installer/live-usb-install.sh" "$bundle_root/installer/live-usb-install.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/bin/sysupdate-local-update.sh" "$bundle_root/bin/sysupdate-local-update.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/scripts/lib/host-deps.sh" "$bundle_root/scripts/lib/host-deps.sh"
  copy_file_preserving_layout "$PROJECT_ROOT/scripts/lib/build-meta.sh" "$bundle_root/scripts/lib/build-meta.sh"
  chmod 0755 "$bundle_root/bin/bootstrap-ab-disk.sh" "$bundle_root/installer/live-usb-install.sh" "$bundle_root/bin/sysupdate-local-update.sh"

  cp -r --no-preserve=ownership "${GENERATED_DEFINITIONS_DIR:-$PROJECT_ROOT/mkosi.sysupdate}/." "$bundle_root/mkosi.sysupdate/"
  cp -r --no-preserve=ownership "$PROJECT_ROOT/deploy.repart/." "$bundle_root/deploy.repart/"

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

  # When the bundle went to USBDATA, plant a thin launcher on the root so
  # the operator can run the installer with the same path they'd expect
  # (/root/INSTALL-TO-INTERNAL-DISK.sh) even though the payload lives on
  # the USBDATA exFAT partition.
  if [[ "$usbdata_fallback" == true ]]; then
    install -d -m 0700 "$ROOT_MOUNT/root"
    cat > "$ROOT_MOUNT/root/INSTALL-TO-INTERNAL-DISK.sh" <<'WRAPPER'
#!/bin/bash
# Bundle is on USBDATA. Mount it, run the installer, unmount.
set -euo pipefail
USBDATA_PART="$(lsblk -nrpo NAME,LABEL | awk '$2=="USBDATA"{print "/dev/"$1; exit}')"
[[ -n "$USBDATA_PART" ]] || { echo "ERROR: USBDATA partition not found" >&2; exit 1; }
USBDATA_MNT="$(mktemp -d /tmp/usbdata.XXXXXX)"
mount "$USBDATA_PART" "$USBDATA_MNT"
trap "umount '$USBDATA_MNT'; rmdir '$USBDATA_MNT'" EXIT
exec "$USBDATA_MNT/ab-installer/installer/live-usb-install.sh" "$@"
WRAPPER
    chmod 0755 "$ROOT_MOUNT/root/INSTALL-TO-INTERNAL-DISK.sh"
    echo "==> Planted USBDATA launcher at /root/INSTALL-TO-INTERNAL-DISK.sh on root"
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

To iterate on the build without losing the USB's DATA/USBDATA partition,
use --reflash on the host:
  sudo ./bin/write-live-test-usb.sh --target /dev/sdX --reflash --yes
That writes the new image into whichever root slot is NOT currently the
default-boot slot, leaves the active slot in place as a known-good
fallback, and does not repartition or wipe USBDATA.

Subsequent updates of the *internal* disk after install go through
systemd-sysupdate (`./bin/sysupdate-local-update.sh`) which is also
non-destructive: it writes only the inactive root slot and never
touches DATA / HOME / ESP partition data.
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
    --diagnostic-mode)
      DIAGNOSTIC_MODE=true
      shift
      ;;
    --luks-passphrase)
      LUKS_PASSPHRASE="${2:?missing passphrase}"
      shift 2
      ;;
    --reflash)
      MODE="reflash"
      shift
      ;;
    --reimage|--repartition)
      MODE="repartition"
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

if ! ab_hostdeps_have_all_commands systemd-repart systemd-sysupdate bootctl mkfs.fat losetup lsblk df blkid objcopy; then
  # binutils provides objcopy, which we now use to extract the kernel and
  # initrd PE sections out of the UKI for Type 1 BLS booting (see comments
  # near the .linux/.initrd extraction below for why Type 1 BLS).
  ab_hostdeps_ensure_packages "hardware test USB prerequisites" systemd-container systemd-repart systemd-boot-tools systemd-boot-efi dosfstools fdisk util-linux binutils || exit 1
fi
ab_hostdeps_ensure_commands "hardware test USB prerequisites" systemd-repart systemd-sysupdate bootctl mkfs.fat losetup lsblk df blkid objcopy || {
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
need_cmd dd
need_cmd sfdisk
need_cmd blkid

[[ -f "$SOURCE_DIR/$IMAGE_BASENAME" ]] || die "built disk image not found: $SOURCE_DIR/$IMAGE_BASENAME"

# Resolve MODE → REFLASH. In auto mode this is where we peek at the
# target so the destructive-confirmation banner downstream knows
# whether the run is going to wipe everything or just rewrite the
# inactive slot. The peek is read-only and detaches its scratch loop
# device immediately so it does not interfere with bootstrap-ab-disk's
# own loop attachment.
case "$MODE" in
  reflash)
    REFLASH=true
    echo "==> Mode: --reflash (forced); will reuse existing A/B layout"
    ;;
  repartition)
    REFLASH=false
    echo "==> Mode: --repartition (forced); will WIPE and re-bootstrap the target"
    ;;
  auto)
    if detect_existing_ab_layout; then
      REFLASH=true
      echo "==> Mode: auto-detected existing A/B layout on $TARGET → using --reflash (non-destructive)"
      echo "    (pass --repartition to force a destructive re-bootstrap instead)"
    else
      REFLASH=false
      echo "==> Mode: no existing A/B layout on $TARGET → using --repartition (destructive bootstrap)"
      echo "    (pass --reflash to fail fast instead of bootstrapping)"
    fi
    ;;
  *)
    die "internal error: unknown MODE='$MODE'"
    ;;
esac

if [[ "$REFLASH" == true ]]; then
    # --reflash: validate the existing layout, skip systemd-repart and
    # bootctl install entirely. The user has already booted from this
    # USB at least once, so the systemd-boot binary on the ESP is
    # known-working; we don't need to rewrite it. We also don't touch
    # USBDATA — preserving the user's files on the stick is the whole
    # point of this mode.
    resolve_disk_device
    validate_existing_ab_layout
    confirm_usb_write_or_abort
    if usbdata_partition_already_formatted; then
        echo "==> --reflash: USBDATA partition already formatted, leaving it untouched"
    elif [[ "$INCLUDE_USB_STORAGE" == true ]]; then
        # Edge case: layout is valid but USBDATA was never mkfs'd
        # (e.g. an interrupted previous run). Format it so the live
        # session has a usable scratch partition; this is non-
        # destructive because there's no filesystem on it yet.
        format_usb_storage_partition
    fi
else
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
    format_usb_storage_partition
fi

# Seed the first system version directly by writing the root.raw image
# into a root slot, instead of using systemd-sysupdate --image on the
# entire disk. This avoids fragile systemd-dissect behavior on
# freshly-repartitioned, still-empty disks.
seed_first_root_slot

# With ROOT_MOUNT set by seed_first_root_slot(), copy the installer
# bundle onto the seeded root filesystem.
copy_bundle

echo "==> Syncing data to USB drive (this may take several minutes)..."
sync

echo "==> Hardware test USB is ready"
echo " Boot target: $TARGET"
echo " Seeded root: $ROOT_PART"
echo " Installer entry: /root/INSTALL-TO-INTERNAL-DISK.sh"
if [[ "$INCLUDE_USB_STORAGE" == true ]]; then
    STORAGE_PART="$(find_usb_storage_partition || true)"
    if [[ -n "$STORAGE_PART" ]]; then
        echo " exFAT storage: $STORAGE_PART (label=$USB_STORAGE_LABEL)"
    fi
fi
if [[ "$EMBED_FULL_IMAGE" == true ]]; then
    echo " Full raw image: copied into $BUNDLE_DIR/mkosi.output/"
fi
