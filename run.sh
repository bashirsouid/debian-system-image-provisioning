#!/usr/bin/env bash
set -euo pipefail

# run.sh — Boots the mkosi image in QEMU
#
# Usage: ./run.sh [--profile <role>]
# Default: devbox

PROFILE="devbox"

if [[ "${1-}" == "--profile" ]]; then
  PROFILE="${2-devbox}"
fi

echo "==> Booting the image in QEMU GUI (profile: $PROFILE)..."

# virtio-gpu + gtk display for larger, resizable windows.
# spice-vdagent in guest will sync resolution.
# Fallback to gl=off if necessary.
mkosi --profile="$PROFILE" vm \
    -vga virtio \
    -display gtk,gl=on || \
mkosi --profile="$PROFILE" vm \
    -vga virtio \
    -display gtk,gl=off
