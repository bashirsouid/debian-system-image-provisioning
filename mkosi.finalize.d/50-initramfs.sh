#!/usr/bin/env bash
# Regenerate the initramfs so that firmware blobs added via --extra-tree
# (after the APT phase) end up inside the initrd.
#
# mkosi's incremental build reuses a cached rootfs from a prior APT run.
# If the extra tree added new firmware files, the cached initrd predates
# them and those devices fail firmware load inside the initrd before
# switch_root.  Running update-initramfs here, after the extra tree is
# applied, ensures the initrd always reflects the current /usr/lib/firmware.

set -euo pipefail

# Only regenerate if an initramfs-tools config exists in the image.
if [[ ! -f "$BUILDROOT/etc/initramfs-tools/initramfs.conf" ]]; then
    exit 0
fi

echo "==> [FINALIZE] regenerating initramfs with current firmware..."

# update-initramfs needs /proc for uname(1) used by some hooks, and /dev
# for mknod calls.  Mount them, clean up on exit.
for mp in proc dev; do
    mount --bind "/$mp" "$BUILDROOT/$mp" 2>/dev/null || true
done
cleanup() { for mp in dev proc; do umount "$BUILDROOT/$mp" 2>/dev/null || true; done; }
trap cleanup EXIT

chroot "$BUILDROOT" update-initramfs -u -k all

echo "==> [FINALIZE] initramfs regenerated."
