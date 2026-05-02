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
#   # Repair a USB stick that won't boot:
#   sudo ./bin/ab-repair-esp.sh --target /dev/sdX
#
#   # Same, but you only remember a partition path — script walks up:
#   sudo ./bin/ab-repair-esp.sh --target /dev/sdX1
#
#   # Make a specific slot the boot default:
#   sudo ./bin/ab-repair-esp.sh --target /dev/nvme0n1 --slot /dev/nvme0n1p2
#
#   # Provide an explicit UKI / build dir instead of the autodetect:
#   sudo ./bin/ab-repair-esp.sh --target /dev/sdX \
#       --build-dir /home/.../mkosi.output/builds/<ts>__<host>
#
# Kernel/initrd resolution order (first hit wins):
#   1. --image <foo.efi>           (UKI on disk; .linux/.initrd extracted)
#   2. --build-dir <dir>           (newest .efi UKI in the dir)
#   3. mkosi.output/builds/<latest> from the repo working tree
#   4. Reuse existing /EFI/Linux/*.linux + matching *.initrd already on
#      the ESP (recovery-only mode — no UKI needed at all)
#   5. Error
#
# Slot naming:
#   * If a UKI is in play we keep the project's original "<image-id>
#     [slot=<part>]" titles — same scheme the installer uses.
#   * In recovery-only mode (no UKI) we use generic "Slot A" / "Slot B"
#     titles, lettered by partition order on the disk, so the user sees
#     a sensible boot menu without needing the build artifacts.
#
# What it does (and does NOT do):
#   * (Re)installs systemd-boot binaries into the ESP via `bootctl`.
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
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
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

for cmd in lsblk blkid bootctl mount umount mktemp install sed awk stat; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done

# ---- if --target points at a partition, walk up to the parent disk ----
# lsblk -no TYPE returns "part" for partitions, "disk" for whole disks.
target_type="$(lsblk -no TYPE "$TARGET" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
if [[ "$target_type" == "part" ]]; then
    parent="$(lsblk -no PKNAME "$TARGET" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    [[ -n "$parent" ]] || die "$TARGET is a partition but its parent disk could not be resolved"
    NEW_TARGET="/dev/$parent"
    [[ -b "$NEW_TARGET" ]] || die "computed parent $NEW_TARGET is not a block device"
    echo "==> --target $TARGET is a partition; using parent disk $NEW_TARGET"
    TARGET="$NEW_TARGET"
elif [[ "$target_type" != "disk" && "$target_type" != "loop" ]]; then
    # Unusual but not necessarily fatal — warn and continue with what we got.
    echo "WARNING: --target $TARGET has lsblk TYPE='$target_type' (expected disk); proceeding anyway" >&2
fi

# ---- force a partition-table re-read so lsblk sees current state ----
# Symptom this fixes: the same `--target /dev/sda` invocation failing
# once, then succeeding on retry. udev sometimes hasn't caught up to a
# partition table change from a recent write, and lsblk caches.
if command -v udevadm  >/dev/null 2>&1; then udevadm settle --timeout=5 >/dev/null 2>&1 || true; fi
if command -v blockdev >/dev/null 2>&1; then blockdev --rereadpt "$TARGET" >/dev/null 2>&1 || true; fi
if command -v partprobe >/dev/null 2>&1; then partprobe "$TARGET" >/dev/null 2>&1 || true; fi
if command -v udevadm  >/dev/null 2>&1; then udevadm settle --timeout=5 >/dev/null 2>&1 || true; fi

# ---- locate ESP + root slots on the target ----
echo "==> Scanning $TARGET for ESP and root slots"
ESP_PART=""
declare -a ROOTS=()
declare -a ROOT_PARTNUMS=()
while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue

    # Detect ESP first, by either PARTLABEL=ESP (project convention)
    # or by the standard EFI System Partition PARTTYPE GUID. Doing
    # this before the FSTYPE filter matters because a vfat ESP would
    # otherwise be skipped (FSTYPE=vfat doesn't match the root-shaped
    # filesystem list).
    if [[ "$PARTLABEL" == "ESP" \
          || "${PARTTYPE,,}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
        [[ -z "$ESP_PART" ]] && ESP_PART="$NAME"
        continue
    fi

    # Skip well-known non-root labels.
    case "$PARTLABEL" in
        HOME|DATA) continue ;;
    esac

    # Anything else with a root-shaped filesystem is a candidate root slot.
    if [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]]; then
        ROOTS+=("$NAME")
        ROOT_PARTNUMS+=("${PARTN:-0}")
    fi
done < <(lsblk -P -npo NAME,PARTLABEL,PARTTYPE,PARTN,FSTYPE,TYPE "$TARGET")

[[ -n "$ESP_PART" ]]      || die "no ESP partition found on $TARGET (looked for PARTLABEL=ESP and ESP PARTTYPE GUID)"
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

# ---- locate the UKI source (optional in recovery-only mode) ----
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null && pwd)"

if [[ -z "$BUILD_DIR" && -z "$UKI_SRC" && -d "$REPO_ROOT/mkosi.output/builds" ]]; then
    BUILD_DIR="$(ls -1dt "$REPO_ROOT"/mkosi.output/builds/*/ 2>/dev/null | head -n 1 | sed 's:/$::' || true)"
    [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]] || BUILD_DIR=""
fi

if [[ -z "$UKI_SRC" && -n "$BUILD_DIR" ]]; then
    [[ -d "$BUILD_DIR" ]] || die "--build-dir $BUILD_DIR does not exist"
    UKI_SRC="$(ls -1t "$BUILD_DIR"/*.efi 2>/dev/null | head -n 1 || true)"
fi

if [[ -n "$UKI_SRC" && ! -f "$UKI_SRC" ]]; then
    die "--image $UKI_SRC is not a file"
fi

if [[ -n "$UKI_SRC" ]]; then
    command -v objcopy >/dev/null 2>&1 || die "objcopy not found in PATH (binutils); needed to extract kernel/initrd from UKI"
    echo "==> UKI source: $UKI_SRC"
else
    echo "==> No UKI source found — entering recovery-only mode (will reuse kernel/initrd already on the ESP if any)"
fi

UKI_BASE=""; PREFIX=""; SRC_OPTIONS=""
if [[ -n "$UKI_SRC" ]]; then
    UKI_BASE="$(basename "$UKI_SRC")"
    PREFIX="${UKI_BASE%.efi}"
    SRC_CONF="${UKI_SRC%.efi}.conf"
    if [[ -f "$SRC_CONF" ]]; then
        SRC_OPTIONS="$(grep '^options ' "$SRC_CONF" | sed 's/^options //' | head -n 1 || true)"
    fi
fi
# Baseline cmdline used when the UKI's .conf can't be read or there's
# no UKI at all. Per-slot root=/rd.luks.uuid= bits get prepended later.
[[ -n "$SRC_OPTIONS" ]] || SRC_OPTIONS="rootwait rw quiet"

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
    bootctl --esp-path="$ESP_MNT" update 2>/dev/null || true
fi

install -d -m 0755 "$ESP_MNT/EFI/Linux" "$ESP_MNT/loader/entries"

# ---- resolve kernel + initrd to use ----
# Two paths: extract from UKI, or reuse what's already on the ESP.
KERNEL_RELPATH=""
INITRD_RELPATH=""

if [[ -n "$UKI_SRC" ]]; then
    KERNEL_DST="$ESP_MNT/EFI/Linux/${PREFIX}.linux"
    INITRD_DST="$ESP_MNT/EFI/Linux/${PREFIX}.initrd"
    echo "==> Extracting .linux from UKI -> $(basename "$KERNEL_DST")"
    objcopy -O binary --only-section=.linux  "$UKI_SRC" "$KERNEL_DST"
    echo "==> Extracting .initrd from UKI -> $(basename "$INITRD_DST")"
    objcopy -O binary --only-section=.initrd "$UKI_SRC" "$INITRD_DST"
    [[ -s "$KERNEL_DST" ]] || die "extracted kernel is empty (.linux section missing)"
    [[ -s "$INITRD_DST" ]] || die "extracted initrd is empty (.initrd section missing)"
    chmod 0644 "$KERNEL_DST" "$INITRD_DST"
    KERNEL_RELPATH="/EFI/Linux/${PREFIX}.linux"
    INITRD_RELPATH="/EFI/Linux/${PREFIX}.initrd"
else
    # Recovery-only: pick the newest existing .linux + matching
    # .initrd already on the ESP. Match by basename so we pair
    # kernel/initrd from the SAME build, not random combos.
    shopt -s nullglob
    declare -a candidates=("$ESP_MNT"/EFI/Linux/*.linux)
    shopt -u nullglob
    if (( ${#candidates[@]} == 0 )); then
        die "no UKI source provided and no existing /EFI/Linux/*.linux on the ESP — nothing to boot. Pass --image <foo.efi> or --build-dir <dir>."
    fi
    # Sort by mtime, newest first.
    newest_kernel=""
    newest_mtime=0
    for k in "${candidates[@]}"; do
        mt="$(stat -c '%Y' "$k" 2>/dev/null || echo 0)"
        if (( mt > newest_mtime )); then
            initrd_candidate="${k%.linux}.initrd"
            if [[ -s "$initrd_candidate" ]]; then
                newest_kernel="$k"
                newest_mtime="$mt"
            fi
        fi
    done
    [[ -n "$newest_kernel" ]] \
        || die "no UKI source provided and no kernel/initrd PAIR (.linux + matching .initrd) on the ESP"
    initrd_match="${newest_kernel%.linux}.initrd"
    KERNEL_RELPATH="/EFI/Linux/$(basename "$newest_kernel")"
    INITRD_RELPATH="/EFI/Linux/$(basename "$initrd_match")"
    echo "==> Reusing existing kernel: $KERNEL_RELPATH"
    echo "==> Reusing existing initrd: $INITRD_RELPATH"
fi

# ---- write one BLS entry per root slot, LUKS-aware ----
default_basename=""
default_mtime=0
declare -a written_basenames=()

# Letter-index slots in partition order (lowest part num = A).
# Build a parallel array of letters aligned to ROOTS[].
declare -a ROOT_LETTERS=()
{
    # Sort ROOTS by partition number so letter order is deterministic.
    # Fall back to lexical NAME order if PARTN is missing.
    declare -a indices=()
    for i in "${!ROOTS[@]}"; do indices+=("$i"); done
    # bash sort by ROOT_PARTNUMS using a simple selection sort (n is tiny).
    for ((i=0; i<${#indices[@]}; i++)); do
        for ((j=i+1; j<${#indices[@]}; j++)); do
            ai="${indices[$i]}"; aj="${indices[$j]}"
            ni="${ROOT_PARTNUMS[$ai]:-0}"; nj="${ROOT_PARTNUMS[$aj]:-0}"
            if (( ni > nj )); then
                tmp="${indices[$i]}"; indices[$i]="${indices[$j]}"; indices[$j]="$tmp"
            fi
        done
    done
    # Initialize ROOT_LETTERS sized to ROOTS.
    for i in "${!ROOTS[@]}"; do ROOT_LETTERS[$i]=""; done
    letters=({A..Z})
    for ((k=0; k<${#indices[@]}; k++)); do
        idx="${indices[$k]}"
        ROOT_LETTERS[$idx]="${letters[$k]:-X}"
    done
}

for i in "${!ROOTS[@]}"; do
    r="${ROOTS[$i]}"
    letter="${ROOT_LETTERS[$i]}"
    pu="$(blkid -s PARTUUID -o value "$r" 2>/dev/null || true)"
    fstype="$(blkid -s TYPE -o value "$r" 2>/dev/null || true)"
    luks_uu=""
    [[ "$fstype" == "crypto_LUKS" ]] && luks_uu="$(blkid -s UUID -o value "$r" 2>/dev/null || true)"

    [[ -n "$pu" ]] || { echo "    - skipping $r: no PARTUUID"; continue; }

    # Build cmdline: strip any baked-in root=/rd.luks.uuid=/rootfstype=
    # and prepend slot-specific bits.
    opts="$(echo "$SRC_OPTIONS" | sed -E 's#root=[^ ]*##g; s#rd\.luks\.uuid=[^ ]*##g; s#rootfstype=[^ ]*##g')"
    if [[ "$fstype" == "crypto_LUKS" && -n "$luks_uu" ]]; then
        opts="rd.luks.uuid=$luks_uu root=/dev/mapper/luks-$luks_uu rootwait $opts"
        echo "==> $r (Slot $letter): LUKS, rd.luks.uuid=$luks_uu"
    else
        opts="root=PARTUUID=$pu rootfstype=ext4 rootwait $opts"
        echo "==> $r (Slot $letter): plain root=PARTUUID=$pu"
    fi
    opts="$(echo "$opts" | tr -s ' ' | sed -E 's#^ +##; s# +$##')"

    # Entry filename + title differ between UKI mode and recovery mode.
    # UKI mode keeps the project-native naming so entries written by
    # ab-install.sh and ab-repair-esp.sh interleave cleanly.
    if [[ -n "$PREFIX" ]]; then
        entry_base="${PREFIX}_$(basename "$r")"
        title="Debian (${PREFIX}) [slot=$(basename "$r")]"
        sortkey="${PREFIX}_$(basename "$r")"
        version="${PREFIX}"
    else
        entry_base="slot-${letter,,}-$(basename "$r")"
        title="Slot ${letter} — $(basename "$r")"
        [[ "$fstype" == "crypto_LUKS" ]] && title="${title} (LUKS)"
        sortkey="slot-${letter}-$(basename "$r")"
        version="recovered-$(date -u +%Y%m%dT%H%M%SZ)"
    fi

    conf="$ESP_MNT/loader/entries/${entry_base}.conf"
    {
        echo "# Generated by bin/ab-repair-esp.sh"
        echo "title ${title}"
        echo "sort-key ${sortkey}"
        echo "version ${version}"
        echo "linux ${KERNEL_RELPATH}"
        echo "initrd ${INITRD_RELPATH}"
        echo "options ${opts}"
    } > "$conf"
    echo "    wrote $(basename "$conf"): \"${title}\""
    written_basenames+=("$entry_base")

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
echo "    Default entry:   ${default_basename}.conf"
echo "    Entries written: ${written_basenames[*]}"
[[ -z "$UKI_SRC" ]] && echo "    Mode:            recovery-only (kernel/initrd reused from ESP)"
