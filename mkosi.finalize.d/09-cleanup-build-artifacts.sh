#!/usr/bin/env bash
# Clean up large build artifacts that don't belong in the final image

ROOT="${BUILDROOT:?BUILDROOT is required}"

echo "==> [FINALIZE] Cleaning up build artifacts..."

# Remove linux-headers if they were installed for CS8409/DKMS build
# The compiled modules are installed separately; we don't need the full headers
if [[ -d "$ROOT/usr/src" ]]; then
    echo "==> [FINALIZE] removing kernel source/headers from /usr/src"
    du -sh "$ROOT/usr/src" 2>/dev/null || true
    rm -rf "$ROOT/usr/src"/*
fi

# Remove DKMS build artifacts (they're large and not needed in the image)
if [[ -d "$ROOT/var/lib/dkms" ]]; then
    echo "==> [FINALIZE] cleaning up DKMS build artifacts from /var/lib/dkms"
    du -sh "$ROOT/var/lib/dkms" 2>/dev/null || true
    # Keep only the module installation, remove build trees
    find "$ROOT/var/lib/dkms" -type d -name "build" -exec rm -rf {} + 2>/dev/null || true
fi

# Clean apt cache if it exists (shouldn't, but be safe)
if [[ -d "$ROOT/var/cache/apt" ]]; then
    echo "==> [FINALIZE] cleaning up apt cache"
    rm -rf "$ROOT/var/cache/apt"/*
fi

echo "==> [FINALIZE] build artifacts cleanup complete"
