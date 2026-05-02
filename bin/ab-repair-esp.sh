#!/usr/bin/env bash
# ab-repair-esp.sh — rebuild a broken ESP on an A/B disk without
# touching root slot data.
#
# When something has wiped the systemd-boot entries / kernel / initrd
# off the ESP (e.g. the prune bug that nuked the just-written entry),
# the root partitions on the disk are still fine — only the ESP needs
# to be re-seeded so the firmware can load a kernel again.
#
# Run this from any working Linux environment (a live USB, a sibling
# A/B install, evox2, etc.) targeting the broken disk.
#
# Examples:
#   # Repair the USB flash drive that won't boot, using the latest
#   # local mkosi build:
#   sudo ./bin/ab-repair-esp.sh --target /dev/sdX
#
#   # Repair the internal disk after booting the rescue USB; pick a
#   # specific slot as the default boot target:
#   sudo ./bin/ab-repair-esp.sh --target /dev/nvme0n1 --slot /dev/nvme0n1p2
#
#   # Provide an explicit UKI / build dir instead of the autodetect:
#   sudo ./bin/ab-repair-esp.sh --target /dev/sdX \
#       --build-dir /home/bashirs/src/my-mkosi-test/mkosi.output/builds/<ts>__<host>
#
# What it does (and does NOT do):
#   * (Re)installs systemd-boot binaries into the ESP via `bootctl install`.
#   * Extracts .linux + .initrd from the UKI in the build dir.
#   * Writes a Type 1 BLS entry per surviving root slot (LUKS-aware
#     cmdline if the slot is encrypted, plain root=PARTUUID= otherwise).
#   * Sets a sensible default (the --slot you named, otherwise the
#     newest-mtime root slot on the disk).
#   * Updates loader.conf default + timeout.
#   * Does NOT format, repartition, dd, or otherwise modify root slots.
#     If your data is on the slot, this script will not touch it.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "must run as root (try: sudo $0 ...)"
}

usage() {
    sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

# ---- arg parse ----
TARGET=""
SLOT=""
BUILD_DIR=""
UKI_SRC=""
TIMEOUT=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)        TARGET="${2:?}"; shift 2 ;;
        --slot)          SLOT="${2:?}"; shift 2 ;;
        --build-dir)     BUILD_DIR="${2:?}"; shift 2 ;;
        --image|--uki)   UKI_SRC="${2:?}"; shift 2 ;;
        --timeout)       TIMEOUT="${2:?}"; shift 2 ;;
        -h|--help)       usage ;;
        *)               die "unknown argument: $1 (see --help)" ;;
    esac
done

require_root
[[ -n "$TARGET" ]]    || die "--target is required"
[[ -b "$TARGET" ]]    || die "--target $TARGET is not a block device"

for cmd in lsblk blkid bootctl objcopy mount umount mktemp install sed awk stat; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done

# ---- locate the UKI source ----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null && pwd)"

if [[ -z "$BUILD_DIR" && -z "$UKI_SRC" ]]; then
    if [[ -d "$REPO_ROOT/mkosi.output/builds" ]]; then
        BUILD_DIR="$(ls -1dt "$REPO_ROOT"/mkosi.output/builds/*/ 2>/dev/null | head -n 1 | sed 's:/$::')"
    fi
    [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]] \
        || die "no build dir found under $REPO_ROOT/mkosi.output/builds; pass --build-dir or --image"
    echo "==> Auto-selected build dir: $BUILD_DIR"
fi

if [[ -z "$UKI_SRC" ]]; then
    UKI_SRC="$(ls -1t "$BUILD_DIR"/*.efi 2>/dev/null | head -n 1 || true)"
    [[ -n "$UKI_SRC" && -f "$UKI_SRC" ]] \
        || die "no .efi UKI found in $BUILD_DIR; pass --image explicitly"
fi
echo "==> UKI source: $UKI_SRC"

UKI_BASE="$(basename "$UKI_SRC")"
PREFIX="${UKI_BASE%.efi}"

# Pull a sane default cmdline out of the build's .conf next to the UKI.
SRC_CONF="${UKI_SRC%.efi}.conf"
if [[ -f "$SRC_CONF" ]]; then
    SRC_OPTIONS="$(grep '^options ' "$SRC_CONF" | sed 's/^options //' | head -n 1 || true)"
else
    SRC_OPTIONS=""
fi
if [[ -z "$SRC_OPTIONS" ]]; then
    # Fall back to a minimal-but-functional cmdline. The per-slot root=
    # / rd.luks.uuid= bits get prepended below; the rest is just the
    # baseline this project's mkosi build uses.
    SRC_OPTIONS="rootwait rw quiet"
fi

# ---- locate ESP + root slots on the target ----
echo "==> Scanning $TARGET for ESP and root slots"
ESP_PART=""
declare -a ROOTS=()
while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue
    case "$PARTLABEL" in
        ESP)         ESP_PART="$NAME"; continue ;;
        HOME|DATA)   continue ;;
    esac
    if [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]]; then
        ROOTS+=("$NAME")
    fi
done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$TARGET")

[[ -n "$ESP_PART" ]]      || die "no ESP partition (PARTLABEL=ESP) found on $TARGET"
(( ${#ROOTS[@]} > 0 ))    || die "no root-shaped partitions found on $TARGET"
echo "    ESP:        $ESP_PART"
echo "    Root slots: ${ROOTS[*]}"

if [[ -n "$SLOT" ]]; then
    [[ -b "$SLOT" ]] || die "--slot $SLOT is not a block device"
    found=no
    for r in "${ROOTS[@]}"; do
        [[ "$r" == "$SLOT" ]] && found=yes && break
    done
    [[ "$found" == "yes" ]] || die "--slot $SLOT is not one of the detected root slots: ${ROOTS[*]}"
fi

# ---- mount ESP ----
ESP_MNT="$(mktemp -d /tmp/ab-repair-esp.XXXXXX)"
cleanup() {
    if mountpoint -q "$ESP_MNT" 2>/dev/null; then
        umount "$ESP_MNT" || true
    fi
    rmdir "$ESP_MNT" 2>/dev/null || true
}
trap cleanup EXIT
echo "==> Mounting ESP $ESP_PART -> $ESP_MNT"
mount "$ESP_PART" "$ESP_MNT"

# ---- (re)install systemd-boot ----
echo "==> Installing systemd-boot into ESP"
if ! bootctl --esp-path="$ESP_MNT" install 2>/dev/null; then
    # `install` fails if it's already installed; try update.
    bootctl --esp-path="$ESP_MNT" update 2>/dev/null || true
fi

install -d -m 0755 "$ESP_MNT/EFI/Linux" "$ESP_MNT/loader/entries"

# ---- extract .linux / .initrd from UKI ----
KERNEL_DST="$ESP_MNT/EFI/Linux/${PREFIX}.linux"
INITRD_DST="$ESP_MNT/EFI/Linux/${PREFIX}.initrd"
echo "==> Extracting .linux from UKI -> $(basename "$KERNEL_DST")"
objcopy -O binary --only-section=.linux  "$UKI_SRC" "$KERNEL_DST"
echo "==> Extracting .initrd from UKI -> $(basename "$INITRD_DST")"
objcopy -O binary --only-section=.initrd "$UKI_SRC" "$INITRD_DST"
[[ -s "$KERNEL_DST" ]] || die "extracted kernel is empty (.linux section missing)"
[[ -s "$INITRD_DST" ]] || die "extracted initrd is empty (.initrd section missing)"
chmod 0644 "$KERNEL_DST" "$INITRD_DST"

# ---- write one BLS entry per root slot, LUKS-aware ----
default_basename=""
default_mtime=0
declare -a written_basenames=()

for r in "${ROOTS[@]}"; do
    pu="$(blkid -s PARTUUID -o value "$r" 2>/dev/null || true)"
    fstype="$(blkid -s TYPE -o value "$r" 2>/dev/null || true)"
    luks_uu=""
    [[ "$fstype" == "crypto_LUKS" ]] && luks_uu="$(blkid -s UUID -o value "$r" 2>/dev/null || true)"

    [[ -n "$pu" ]] || { echo "    - skipping $r: no PARTUUID"; continue; }

    # Build cmdline: strip any baked-in root= and prepend slot-specific bits.
    opts="$(echo "$SRC_OPTIONS" | sed -E 's#root=[^ ]*##g; s#rd\.luks\.uuid=[^ ]*##g; s#rootfstype=[^ ]*##g')"
    if [[ "$fstype" == "crypto_LUKS" && -n "$luks_uu" ]]; then
        opts="rd.luks.uuid=$luks_uu root=/dev/mapper/luks-$luks_uu rootwait $opts"
        echo "==> $r: LUKS root, rd.luks.uuid=$luks_uu"
    else
        opts="root=PARTUUID=$pu rootfstype=ext4 rootwait $opts"
        echo "==> $r: plain root=PARTUUID=$pu"
    fi
    opts="$(echo "$opts" | tr -s ' ' | sed -E 's#^ +##; s# +$##')"

    entry_base="${PREFIX}_$(basename "$r")"
    conf="$ESP_MNT/loader/entries/${entry_base}.conf"
    {
        echo "# Generated by bin/ab-repair-esp.sh"
        echo "title Debian (${PREFIX}) [slot=$(basename "$r")]"
        echo "sort-key ${PREFIX}_$(basename "$r")"
        echo "version ${PREFIX}"
        echo "linux /EFI/Linux/${PREFIX}.linux"
        echo "initrd /EFI/Linux/${PREFIX}.initrd"
        echo "options ${opts}"
    } > "$conf"
    echo "    wrote $(basename "$conf")"
    written_basenames+=("$entry_base")

    # Pick default: --slot if user named one, else newest-mtime slot.
    if [[ -n "$SLOT" && "$r" == "$SLOT" ]]; then
        default_basename="$entry_base"
    elif [[ -z "$SLOT" ]]; then
        mt="$(stat -c '%Y' "$r" 2>/dev/null || echo 0)"
        if (( mt > default_mtime )); then
            default_mtime="$mt"
            default_basename="$entry_base"
        fi
    fi
done

(( ${#written_basenames[@]} > 0 )) || die "no boot entries were written"

# Fall back to the first entry if nothing claimed default (e.g. all
# slots returned mtime 0).
[[ -n "$default_basename" ]] || default_basename="${written_basenames[0]}"

# ---- loader.conf ----
echo "==> Setting default boot entry: ${default_basename}.conf"
if [[ -f "$ESP_MNT/loader/loader.conf" ]]; then
    if grep -q '^default ' "$ESP_MNT/loader/loader.conf"; then
        sed -i -E "s/^default .*/default ${default_basename}.conf/" "$ESP_MNT/loader/loader.conf"
    else
        echo "default ${default_basename}.conf" >> "$ESP_MNT/loader/loader.conf"
    fi
    if ! grep -q '^timeout ' "$ESP_MNT/loader/loader.conf"; then
        echo "timeout ${TIMEOUT}" >> "$ESP_MNT/loader/loader.conf"
    fi
else
    printf "default %s.conf\ntimeout %s\nconsole-mode keep\n" \
        "${default_basename}" "${TIMEOUT}" > "$ESP_MNT/loader/loader.conf"
fi

sync
echo
echo "==> ESP repair complete on $TARGET"
echo "    Default entry: ${default_basename}.conf"
echo "    Entries written: ${written_basenames[*]}"
