#!/usr/bin/env bash
set -euo pipefail

URL="https://zoom.us/client/latest/zoom_amd64.deb"
MARKER="/var/lib/zoom-web/installed"
TMP="$(mktemp --tmpdir zoom_amd64.XXXXXX.deb)"
trap 'rm -f "$TMP"' EXIT

if command -v zoom >/dev/null 2>&1; then
    install -d -m 0755 /var/lib/zoom-web
    touch "$MARKER"
    echo "Zoom is already installed."
    exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get is unavailable; cannot install Zoom."
    exit 0
fi

echo "Downloading Zoom client..."
if ! wget -O "$TMP" "$URL"; then
    echo "Unable to download Zoom; will retry on a later boot."
    exit 0
fi

echo "Installing Zoom..."
if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$TMP"; then
    install -d -m 0755 /var/lib/zoom-web
    touch "$MARKER"
else
    echo "Zoom install failed; will retry on a later boot."
fi
