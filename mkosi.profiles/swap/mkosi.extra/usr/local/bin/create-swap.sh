#!/usr/bin/env bash
# create-swap.sh – creates a 2 GiB swap file if missing and enables it.

SWAPFILE="/swapfile"
SIZE_MB=2048

# Only create the file if it doesn't already exist.
if [[ ! -f "$SWAPFILE" ]]; then
    echo "Creating $SWAPFILE (${SIZE_MB}MiB) with fallocate..."
    fallocate -l "${SIZE_MB}M" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
fi

# Ensure the swap is active.
swapon "$SWAPFILE" || true
