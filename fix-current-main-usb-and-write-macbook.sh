#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: sudo ./fix-current-main-usb-and-write-macbook.sh /dev/sdX" >&2
  exit 1
fi
PROJECT_ROOT="$(pwd)"
cd "$PROJECT_ROOT"
perl -0pi -e 's/bootctl --esp-path="\$ESP_MOUNT" --install-source=host install/bootctl --esp-path="\$ESP_MOUNT" --no-variables install/' scripts/bootstrap-ab-disk.sh
chmod +x scripts/bootstrap-ab-disk.sh
TMPDEFS="$(mktemp -d)"
trap 'rm -rf "$TMPDEFS"' EXIT
for f in mkosi.sysupdate/*.transfer; do
  sed 's/debian-provisioning/macbookpro13-2019-t2/g' "$f" > "$TMPDEFS/$(basename "$f")"
done
sudo ./scripts/write-live-test-usb.sh \
  --target "$TARGET" \
  --profile macbook \
  --host macbookpro13-2019-t2 \
  --definitions "$TMPDEFS"
