#!/bin/bash
# scripts/usb-write-and-verify.sh
#
# Writes a raw image to a USB device and then verifies the write by
# hashing back the exact number of bytes from the device and comparing
# against the source hash. Does NOT report success unless the verify
# pass succeeds.
#
# Usage:
#   sudo ./scripts/usb-write-and-verify.sh \
#       --source <path-to-image.raw> \
#       --target /dev/sdX \
#       [--bs 4M] [--assume-yes] [--keep-cache]
#
# Designed to be called from bin/write-live-test-usb.sh *after*
# that script has produced the image and confirmed the target device.
# It can also be used standalone when you just want to flash an
# already-built image.
#
# Safety checks (refuses to proceed unless all pass):
#   1. --target must be a block device, not a regular file.
#   2. --target must be removable (sysfs /sys/block/<dev>/removable == 1)
#      OR --i-know-this-is-not-removable was passed.
#   3. --target must not be currently mounted.
#   4. --target must not be the host root disk.

set -euo pipefail

log()  { printf '[usb-write] %s\n'        "$*" >&2; }
fail() { printf '[usb-write] ERROR: %s\n' "$*" >&2; exit 1; }

SOURCE=""
TARGET=""
BS="4M"
ASSUME_YES="no"
ALLOW_NONREMOVABLE="no"
KEEP_CACHE="no"

while (($#)); do
    case "$1" in
        --source) SOURCE="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --bs)     BS="$2";     shift 2 ;;
        --assume-yes|-y) ASSUME_YES="yes"; shift ;;
        --i-know-this-is-not-removable) ALLOW_NONREMOVABLE="yes"; shift ;;
        --keep-cache) KEEP_CACHE="yes"; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) fail "unknown arg: $1" ;;
    esac
done

[[ -n "${SOURCE}" ]] || fail "--source is required"
[[ -n "${TARGET}" ]] || fail "--target is required"
[[ -f "${SOURCE}" ]] || fail "source file does not exist: ${SOURCE}"
[[ -b "${TARGET}" ]] || fail "target is not a block device: ${TARGET}"

if [[ $EUID -ne 0 ]]; then
    fail "must run as root (for raw block device writes)"
fi

# --- safety: refuse to write to the host root disk ----------------------
HOST_ROOT_SRC="$(findmnt -n -o SOURCE /)"
HOST_ROOT_DEV=""
if [[ -n "${HOST_ROOT_SRC}" ]]; then
    HOST_ROOT_DEV="$(lsblk -no pkname "${HOST_ROOT_SRC}" 2>/dev/null || true)"
    [[ -n "${HOST_ROOT_DEV}" ]] && HOST_ROOT_DEV="/dev/${HOST_ROOT_DEV}"
fi
target_parent="$(lsblk -no pkname "${TARGET}" 2>/dev/null || true)"
target_whole="${TARGET}"
[[ -n "${target_parent}" ]] && target_whole="/dev/${target_parent}"

if [[ -n "${HOST_ROOT_DEV}" && "${HOST_ROOT_DEV}" == "${target_whole}" ]]; then
    fail "${TARGET} is on the host root disk (${HOST_ROOT_DEV}). Refusing."
fi

# --- safety: removable ------------------------------------------------------
target_base="$(basename "${target_whole}")"
removable_path="/sys/block/${target_base}/removable"
if [[ -r "${removable_path}" ]]; then
    rem="$(cat "${removable_path}")"
    if [[ "${rem}" != "1" && "${ALLOW_NONREMOVABLE}" != "yes" ]]; then
        fail "${TARGET} is not a removable device (sysfs removable=${rem}). Pass --i-know-this-is-not-removable if intentional."
    fi
fi

# --- safety: no mounted partitions ------------------------------------------
if lsblk -nlo MOUNTPOINT "${TARGET}" | awk 'NF' | grep -q .; then
    log "the following mountpoints exist on ${TARGET}:"
    lsblk -o NAME,SIZE,MOUNTPOINT "${TARGET}" >&2
    fail "unmount all partitions on ${TARGET} first."
fi

# --- info / confirm ---------------------------------------------------------
src_size="$(stat -c '%s' "${SOURCE}")"
src_size_mib=$(( src_size / 1024 / 1024 ))

log "SOURCE : ${SOURCE} (${src_size} bytes, ~${src_size_mib} MiB)"
log "TARGET : ${TARGET}"
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,REMOVABLE "${TARGET}" >&2 || true

if [[ "${ASSUME_YES}" != "yes" ]]; then
    printf '\n*** EVERYTHING ON %s WILL BE DESTROYED ***\nType the device name to confirm: ' "${TARGET}" >&2
    read -r confirm
    if [[ "${confirm}" != "${TARGET}" ]]; then
        fail "confirmation did not match; aborting."
    fi
fi

# --- hash the source once ---------------------------------------------------
log "hashing source..."
src_hash="$(sha256sum "${SOURCE}" | awk '{print $1}')"
log "source sha256 = ${src_hash}"

# --- write ------------------------------------------------------------------
log "writing with dd (this can take a while; progress will be shown)..."
# conv=fsync forces fdatasync at the end so we actually flush before
# moving on. oflag=direct bypasses page cache to reduce cross-talk.
dd if="${SOURCE}" of="${TARGET}" bs="${BS}" status=progress conv=fsync oflag=direct

# Kernel-side flush + settle.
sync
if command -v blockdev >/dev/null; then
    blockdev --flushbufs "${TARGET}" || true
fi
udevadm settle || true

# Drop the source and first-bytes-of-target from page cache so the
# re-read truly comes from the device, not RAM.
if [[ "${KEEP_CACHE}" != "yes" ]]; then
    log "dropping page cache for an honest read-back..."
    sync
    sysctl -w vm.drop_caches=3 >/dev/null 2>&1 || echo 3 >/proc/sys/vm/drop_caches || true
fi

# --- verify -----------------------------------------------------------------
log "reading back first ${src_size} bytes of ${TARGET} and hashing..."
# Read exactly src_size bytes with dd and pipe to sha256sum so we do
# not rely on the device appearing at exactly the source size.
dst_hash="$(dd if="${TARGET}" bs=1M iflag=fullblock count=$(( (src_size + 1024*1024 - 1) / (1024*1024) )) 2>/dev/null | head -c "${src_size}" | sha256sum | awk '{print $1}')"
log "device sha256 = ${dst_hash}"

if [[ "${src_hash}" != "${dst_hash}" ]]; then
    fail "VERIFY FAILED: source and device hashes differ. DO NOT boot this USB."
fi

log "VERIFY OK: source and device first ${src_size} bytes match."
log "done. Safe to remove ${TARGET} after sync completes."
sync
