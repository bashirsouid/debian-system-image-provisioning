#!/usr/bin/env bash
# Sign kernel modules for Secure Boot compatibility.
#
# When Secure Boot is enabled in integrity lockdown mode, unsigned kernel
# modules cannot be loaded. This script signs all kernel modules in the image
# with the Secure Boot db key so they load under Secure Boot + lockdown.
#
# Environment variables (set by mkosi / build.sh --environment):
#   BUILDROOT               - mkosi image root (required, set by mkosi)
#   SRCDIR                  - project root on the build host (set by mkosi)
#   AB_SECUREBOOT_ENABLED   - "yes" = signing is required; any failure is fatal
#   AB_PROJECT_ROOT         - fallback project root if SRCDIR is unavailable

set -euo pipefail

source "$SRCDIR/scripts/finalize-lib.sh"

SB_REQUIRED="${AB_SECUREBOOT_ENABLED:-no}"

# .secureboot/ is gitignored but lives in the real project root, which mkosi
# exposes to finalize scripts as SRCDIR (the actual host path, not /work/src).
KEY_DIR="${SRCDIR}/.secureboot"
if [[ ! -d "$KEY_DIR" && -n "${AB_PROJECT_ROOT:-}" ]]; then
    KEY_DIR="${AB_PROJECT_ROOT}/.secureboot"
fi

if [[ ! -f "$KEY_DIR/db.key" || ! -f "$KEY_DIR/db.crt" ]]; then
    if [[ "$SB_REQUIRED" == "yes" ]]; then
        echo "ERROR: [FINALIZE] AB_SECUREBOOT_ENABLED=yes but signing keys are missing" >&2
        echo "ERROR: [FINALIZE] Looked in: ${KEY_DIR}" >&2
        echo "ERROR: [FINALIZE] SRCDIR=${SRCDIR:-<unset>}  AB_PROJECT_ROOT=${AB_PROJECT_ROOT:-<unset>}" >&2
        echo "ERROR: [FINALIZE] Run ./bin/generate-secureboot-keys.sh on the build host" >&2
        exit 1
    fi
    echo "==> [FINALIZE] No Secure Boot keys found; skipping module signing"
    exit 0
fi

MODULES_DIR="${ROOT}/lib/modules"
if [[ ! -d "$MODULES_DIR" ]]; then
    echo "==> [FINALIZE] No kernel modules directory in image; skipping signing"
    exit 0
fi

# Find sign-file on the build host. Prefer a version matching the image kernel;
# fall back to any installed linux-headers. sign-file does not need to match the
# image kernel version — it only performs the cryptographic operation.
SIGNFILE=""
for kernel_dir in "$MODULES_DIR"/*/; do
    kver="$(basename "$kernel_dir")"
    if [[ -x "/usr/src/linux-headers-${kver}/scripts/sign-file" ]]; then
        SIGNFILE="/usr/src/linux-headers-${kver}/scripts/sign-file"
        echo "==> [FINALIZE] sign-file: /usr/src/linux-headers-${kver}/scripts/sign-file"
        break
    fi
done
if [[ -z "$SIGNFILE" ]]; then
    for header_dir in /usr/src/linux-headers-*; do
        if [[ -x "$header_dir/scripts/sign-file" ]]; then
            SIGNFILE="$header_dir/scripts/sign-file"
            echo "==> [FINALIZE] sign-file (version mismatch): ${SIGNFILE}"
            break
        fi
    done
fi

if [[ -z "$SIGNFILE" ]]; then
    if [[ "$SB_REQUIRED" == "yes" ]]; then
        echo "ERROR: [FINALIZE] sign-file not found in /usr/src/linux-headers-*/scripts/" >&2
        echo "ERROR: [FINALIZE] Install kernel headers on the build host:" >&2
        echo "ERROR: [FINALIZE]   apt-get install linux-headers-\$(uname -r)" >&2
        exit 1
    fi
    echo "==> [FINALIZE] sign-file not found on build host; skipping module signing"
    exit 0
fi

echo "==> [FINALIZE] Signing kernel modules with key: ${KEY_DIR}/db.key"

MOD_COUNT=0
MOD_SIGNED=0
MOD_FAILED=0

_sign_module() {
    local mod="$1"
    local sign_ok=false

    if [[ "$mod" == *.ko.xz ]]; then
        local tmp
        tmp="$(mktemp)"
        if xz -dc "$mod" > "$tmp" \
           && "$SIGNFILE" sha256 "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$tmp" \
           && xz --check=crc32 -6 "$tmp" \
           && mv "${tmp}.xz" "$mod"; then
            sign_ok=true
        fi
        rm -f "$tmp" "${tmp}.xz" 2>/dev/null || true

    elif [[ "$mod" == *.ko.zst ]]; then
        local tmp
        tmp="$(mktemp)"
        if zstd -d --stdout "$mod" > "$tmp" \
           && "$SIGNFILE" sha256 "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$tmp" \
           && zstd -T0 -19 "$tmp" \
           && mv "${tmp}.zst" "$mod"; then
            sign_ok=true
        fi
        rm -f "$tmp" "${tmp}.zst" 2>/dev/null || true

    elif [[ "$mod" == *.ko ]]; then
        if "$SIGNFILE" sha256 "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$mod"; then
            sign_ok=true
        fi
    fi

    if [[ "$sign_ok" == true ]]; then
        MOD_SIGNED=$((MOD_SIGNED + 1))
    else
        MOD_FAILED=$((MOD_FAILED + 1))
        echo "ERROR: [FINALIZE] Failed to sign: ${mod}" >&2
    fi
}

while IFS= read -r mod; do
    [[ -n "$mod" && -f "$mod" ]] || continue
    MOD_COUNT=$((MOD_COUNT + 1))
    _sign_module "$mod"
done < <(find "$MODULES_DIR" \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.zst" \) -type f 2>/dev/null)

echo "==> [FINALIZE] Signed ${MOD_SIGNED}/${MOD_COUNT} kernel modules (${MOD_FAILED} failed)"

if [[ "$MOD_FAILED" -gt 0 ]]; then
    if [[ "$SB_REQUIRED" == "yes" ]]; then
        echo "ERROR: [FINALIZE] ${MOD_FAILED} module(s) failed to sign; aborting Secure Boot build" >&2
        exit 1
    fi
    echo "WARNING: [FINALIZE] ${MOD_FAILED} module(s) failed to sign (Secure Boot not required for this build)"
fi
