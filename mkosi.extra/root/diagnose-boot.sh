#!/usr/bin/env bash
# diagnose-boot.sh
#
# Collects comprehensive boot diagnostics and writes to BOTH the screen and a
# timestamped text file. Safe to run any time.
#
# Works in two environments:
#   1. Booted system (normal case)       -> writes to /root/boot-diagnosis-*.txt
#   2. Initrd shell from rd.break        -> writes to /sysroot/root/ if mounted,
#                                            else /tmp, so the file survives
#                                            into the booted system later.
#
# Usage:
#     ./diagnose-boot.sh             # run with defaults
#     ./diagnose-boot.sh -o FILE     # explicit output path
#     ./diagnose-boot.sh --copy-to-usbdata   # also copy output to the exFAT
#                                              USBDATA partition (label=USBDATA)
#                                              so you can read it on another machine
set -u

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
COPY_TO_USBDATA=0
EXPLICIT_OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) EXPLICIT_OUT="$2"; shift 2 ;;
        --copy-to-usbdata) COPY_TO_USBDATA=1; shift ;;
        -h|--help)
            sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Detect environment
if [[ -d /sysroot && ! -f /etc/os-release ]]; then
    ENV="initrd"
    DEFAULT_DIR="/sysroot/root"
    [[ -w "$DEFAULT_DIR" ]] 2>/dev/null || DEFAULT_DIR="/tmp"
else
    ENV="booted"
    DEFAULT_DIR="/root"
    [[ -w "$DEFAULT_DIR" ]] 2>/dev/null || DEFAULT_DIR="/tmp"
fi

OUT_FILE="${EXPLICIT_OUT:-${DEFAULT_DIR}/boot-diagnosis-${TIMESTAMP}.txt}"

# Redirect everything through tee so both screen and file get the output.
exec > >(tee -a "$OUT_FILE") 2>&1

banner() { printf '\n============================================================\n%s\n============================================================\n' "$*"; }
section() { printf '\n--- %s ---\n' "$*"; }

banner " Boot diagnostics -- $(date -u 2>/dev/null || echo unknown)"
echo " Environment:  $ENV"
echo " Output file:  $OUT_FILE"
echo " Hostname:     $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"

section "Kernel command line (/proc/cmdline)"
cat /proc/cmdline 2>/dev/null || echo "(unavailable)"

section "Kernel version"
uname -a 2>/dev/null || echo "(uname failed)"

section "Block devices (lsblk)"
if command -v lsblk >/dev/null 2>&1; then
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,PARTLABEL,MOUNTPOINT 2>/dev/null
else
    ls -la /dev/sd* /dev/nvme* /dev/mmc* 2>/dev/null
fi

section "Partitions by PARTUUID"
ls -la /dev/disk/by-partuuid/ 2>/dev/null || echo "(not available)"

section "Partitions by PARTLABEL"
ls -la /dev/disk/by-partlabel/ 2>/dev/null || echo "(not available)"

section "Partitions by LABEL"
ls -la /dev/disk/by-label/ 2>/dev/null || echo "(not available)"

section "Current mounts"
mount 2>/dev/null || cat /proc/mounts

section "Device mapper state (dm-verity, etc.)"
if command -v dmsetup >/dev/null 2>&1; then
    dmsetup ls 2>/dev/null || echo "(no dm devices)"
    echo
    dmsetup table 2>/dev/null || true
else
    echo "(dmsetup not installed)"
fi

if [[ "$ENV" == "initrd" ]]; then
    section "/sysroot inspection (did root actually mount?)"
    if mountpoint -q /sysroot 2>/dev/null; then
        echo "/sysroot IS a mountpoint."
    else
        echo "/sysroot is NOT a mountpoint -- this is the bug."
    fi
    echo
    echo "Top-level /sysroot contents:"
    find /sysroot/ -maxdepth 1 -ls 2>/dev/null | head -40
    echo
    echo "Critical init binaries:"
    for p in /sysroot/sbin/init \
             /sysroot/usr/lib/systemd/systemd \
             /sysroot/lib/systemd/systemd \
             /sysroot/bin/init; do
        if [[ -e "$p" ]]; then
            echo "  OK      $p -> $(readlink -f "$p" 2>/dev/null)"
        else
            echo "  MISSING $p"
        fi
    done
fi

section "Kernel messages - last 100 lines (dmesg)"
dmesg 2>/dev/null | tail -100 || echo "(dmesg not accessible)"

section "Kernel errors/warnings (filtered)"
dmesg 2>/dev/null | grep -iE 'error|fail|warn|verity|cannot|unable|denied|timeout' | tail -60

section "Failed systemd units"
if command -v systemctl >/dev/null 2>&1; then
    systemctl --failed --no-pager --no-legend 2>/dev/null || echo "(systemctl not responsive)"
fi

section "Status of boot-critical units"
if command -v systemctl >/dev/null 2>&1; then
    for unit in initrd-switch-root.service \
                initrd-root-fs.target \
                sysroot.mount \
                systemd-fsck-root.service \
                systemd-remount-fs.service \
                local-fs.target; do
        echo "### $unit ###"
        systemctl status "$unit" --no-pager --full 2>/dev/null | head -30
        echo
    done
fi

section "Journal (this boot) - last 200 lines"
if command -v journalctl >/dev/null 2>&1; then
    journalctl -xb --no-pager 2>/dev/null | tail -200 || echo "(journalctl unavailable)"
fi

section "Journal errors only (this boot)"
if command -v journalctl >/dev/null 2>&1; then
    journalctl -xb -p err --no-pager 2>/dev/null | tail -80
fi

section "Loaded kernel modules (top 60)"
lsmod 2>/dev/null | head -60 || echo "(lsmod unavailable)"

section "USB-storage, NVMe, ext4, dm-verity module presence"
for mod in usb_storage uas xhci_pci xhci_hcd nvme ext4 dm_verity dm_mod apple_bce; do
    if lsmod 2>/dev/null | grep -q "^$mod "; then
        echo "  loaded:    $mod"
    else
        echo "  not loaded: $mod"
    fi
done

section "ESP / boot entries"
for mnt in /boot /boot/efi /efi /sysroot/boot /sysroot/efi; do
    if [[ -d "$mnt/loader/entries" ]] || [[ -d "$mnt/EFI" ]]; then
        echo "Found ESP-like content at: $mnt"
        find "$mnt" -maxdepth 4 \( -name '*.efi' -o -name '*.conf' \) 2>/dev/null | head -30
        for conf in "$mnt"/loader/entries/*.conf; do
            [[ -f "$conf" ]] || continue
            echo
            echo "### $conf ###"
            cat "$conf"
        done
    fi
done

section "Boot timing (if bootable)"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze 2>/dev/null || echo "(boot not complete, timing unavailable)"
    systemd-analyze blame 2>/dev/null | head -20 || true
fi

banner " Diagnostics complete"
echo " Output file: $OUT_FILE"

if [[ "$COPY_TO_USBDATA" == "1" ]]; then
    echo
    echo "--- Copying to USBDATA partition ---"
    USBDATA_DEV="$(blkid -L USBDATA 2>/dev/null || true)"
    if [[ -n "$USBDATA_DEV" ]]; then
        MNT="$(mktemp -d)"
        if mount "$USBDATA_DEV" "$MNT" 2>/dev/null; then
            cp "$OUT_FILE" "$MNT/" && echo "Copied to $USBDATA_DEV as $(basename "$OUT_FILE")"
            sync
            umount "$MNT"
        else
            echo "Failed to mount $USBDATA_DEV"
        fi
        rmdir "$MNT" 2>/dev/null
    else
        echo "USBDATA partition not found"
    fi
fi

echo
echo " To read this from another machine:"
echo "   mount the USBDATA exFAT partition and copy $OUT_FILE off,"
echo "   or re-run with: $0 --copy-to-usbdata"
