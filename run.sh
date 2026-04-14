#!/usr/bin/env bash
set -euo pipefail

PROFILE="devbox"

if [[ "${1-}" == "--profile" ]]; then
  PROFILE="${2-devbox}"
fi

echo "==> Booting the image in QEMU GUI (profile: $PROFILE)..."

mkosi --profile="$PROFILE" vm -- \
    -vga virtio \
    -display gtk,gl=on || \
mkosi --profile="$PROFILE" vm -- \
    -vga virtio \
    -display gtk,gl=off
