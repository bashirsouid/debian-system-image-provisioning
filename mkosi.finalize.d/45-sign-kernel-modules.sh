#!/usr/bin/env bash
# Sign kernel modules for Secure Boot compatibility.
#
# When Secure Boot is enabled in integrity lockdown mode, unsigned kernel modules
# cannot be loaded. This script signs all kernel modules in the image with the
# Secure Boot key so they can be loaded under Secure Boot.
#
# Requires:
# - BUILDROOT environment variable (provided by mkosi)
# - .secureboot/db.key and .secureboot/db.crt (Secure Boot signing key)
#
# Called by mkosi during the finalize phase after package installation.

set -euo pipefail

# Source shared library
# SRCDIR is set by mkosi to /work/src, but scripts/ may not be visible there.
# Use AB_PROJECT_ROOT as a fallback since scripts/ is not gitignored.
if [[ -d "${SRCDIR}/scripts" ]]; then
    source "${SRCDIR}/scripts/finalize-lib.sh"
elif [[ -n "${AB_PROJECT_ROOT:-}" && -d "${AB_PROJECT_ROOT}/scripts" ]]; then
    source "${AB_PROJECT_ROOT}/scripts/finalize-lib.sh"
else
    # Fallback: compute from script location (works when script runs from original location)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../scripts/finalize-lib.sh"
fi

# Determine project root for accessing .secureboot keys
# When finalize scripts run in a sandbox (SRCDIR=/work/src), .secureboot is not
# visible there because it's gitignored. Use AB_PROJECT_ROOT when available.
if [[ -n "${AB_PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$AB_PROJECT_ROOT"
else
    PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
KEY_DIR="${PROJECT_ROOT}/.secureboot"

# Check if Secure Boot key exists (opt-in for SB-enabled builds)
if [[ ! -f "$KEY_DIR/db.key" || ! -f "$KEY_DIR/db.crt" ]]; then
    echo "==> [FINALIZE] No Secure Boot key found; skipping module signing"
    exit 0
fi

# Check if kernel modules exist in the image
MODULES_DIR="${ROOT}/lib/modules"
if [[ ! -d "$MODULES_DIR" ]]; then
    echo "==> [FINALIZE] No kernel modules directory; skipping signing"
    exit 0
fi

# Find sign-file in installed kernel headers
SIGNFILE=""
for header_dir in /usr/src/linux-headers-*; do
    if [[ -x "$header_dir/scripts/sign-file" ]]; then
        SIGNFILE="$header_dir/scripts/sign-file"
        break
    fi
done

if [[ -z "$SIGNFILE" ]]; then
    echo "==> [FINALIZE] WARNING: sign-file not found in kernel headers; skipping module signing"
    exit 0
fi

echo "==> [FINALIZE] Signing kernel modules with ${SIGNFILE}..."

# Sign all modules in the image
# sign-file [-dp] <hash algo> <key> <x509> <module> [<dest>]
MOD_COUNT=0
MOD_SIGNED=0

# Process modules from find output stored in array to avoid subshell issues
while IFS= read -r mod; do
    if [[ -n "$mod" && -f "$mod" ]]; then
        MOD_COUNT=$((MOD_COUNT + 1))
        if [[ "$mod" == *.ko.xz ]]; then
            # .ko.xz files: decompress, sign, recompress
            TMPMOD="$(mktemp)"
            if xz -dc "$mod" > "$TMPMOD" 2>/dev/null; then
                if "$SIGNFILE" sha256 "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$TMPMOD" 2>/dev/null; then
                    if xz -9 "$TMPMOD" 2>/dev/null; then
                        mv "${TMPMOD}.xz" "$mod" 2>/dev/null || true
                        MOD_SIGNED=$((MOD_SIGNED + 1))
                    fi
                fi
            fi
            rm -f "$TMPMOD" "${TMPMOD}.xz" 2>/dev/null || true
        elif [[ "$mod" == *.ko ]]; then
            # Plain .ko files: sign directly
            if "$SIGNFILE" sha256 "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$mod" 2>/dev/null; then
                MOD_SIGNED=$((MOD_SIGNED + 1))
            fi
        fi
    fi
done < <(find "$MODULES_DIR" -name "*.ko*" -type f 2>/dev/null)

echo "==> [FINALIZE] Signed ${MOD_SIGNED}/${MOD_COUNT} kernel modules"