#!/usr/bin/env bash
# Sign kernel modules for Secure Boot compatibility.
#
# IMPORTANT: this script only signs modules that are NOT already signed.
#
# Distribution kernels (Debian, Ubuntu, etc.) ship modules pre-signed with the
# distro's key, which is embedded in the kernel's built-in trusted keyring.
# Those modules load fine under Secure Boot lockdown without any action here.
#
# If we appended a second signature with our custom key, the kernel would check
# only the LAST signature — overriding the distro's trusted signature with ours,
# which is not in the built-in keyring.  That breaks every distro module.
#
# We therefore skip already-signed modules and only sign unsigned ones (DKMS /
# out-of-tree modules).  For those to load, enroll the key on the target machine:
#   mokutil --import .secureboot/db.crt
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
# fall back to any installed linux-headers. sign-file only does crypto — it does
# not need to match the image kernel version.
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

echo "==> [FINALIZE] Scanning for unsigned kernel modules (key: ${KEY_DIR}/db.key)"

MOD_COUNT=0
MOD_SIGNED=0
MOD_SKIPPED=0
MOD_FAILED=0

# Detect whether a decompressed .ko file already has a module signature.
# MODULE_SIG_STRING = "~Module signature appended~\n" is always the last 28
# bytes of a signed module file.
_ko_is_signed() {
    tail -c 28 "$1" 2>/dev/null | grep -qF '~Module signature appended~'
}

_sign_module() {
    local mod="$1"
    local sign_ok=false

    if [[ "$mod" == *.ko.xz ]]; then
        local tmp
        tmp="$(mktemp)"
        if xz -dc "$mod" > "$tmp"; then
            if _ko_is_signed "$tmp"; then
                MOD_SKIPPED=$((MOD_SKIPPED + 1))
                rm -f "$tmp"
                return 0
            fi
            # Unsigned module: sign then recompress.
            # xz --check=crc32 matches scripts/Makefile.modinst in the kernel
            # tree — the Debian kernel has CONFIG_XZ_DEC_CRC64 disabled, so
            # the default CRC64 produces XZ_OPTIONS_ERROR on module load.
            if "$SIGNFILE" sha256 "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$tmp" \
               && xz --check=crc32 -6 "$tmp" \
               && mv "${tmp}.xz" "$mod"; then
                sign_ok=true
            fi
        fi
        rm -f "$tmp" "${tmp}.xz" 2>/dev/null || true

    elif [[ "$mod" == *.ko.zst ]]; then
        local tmp
        tmp="$(mktemp)"
        if zstd -d --stdout "$mod" > "$tmp"; then
            if _ko_is_signed "$tmp"; then
                MOD_SKIPPED=$((MOD_SKIPPED + 1))
                rm -f "$tmp"
                return 0
            fi
            if "$SIGNFILE" sha256 "$KEY_DIR/db.key" "$KEY_DIR/db.crt" "$tmp" \
               && zstd -T0 -19 "$tmp" \
               && mv "${tmp}.zst" "$mod"; then
                sign_ok=true
            fi
        fi
        rm -f "$tmp" "${tmp}.zst" 2>/dev/null || true

    elif [[ "$mod" == *.ko ]]; then
        if _ko_is_signed "$mod"; then
            MOD_SKIPPED=$((MOD_SKIPPED + 1))
            return 0
        fi
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

echo "==> [FINALIZE] Modules: ${MOD_COUNT} total, ${MOD_SIGNED} newly signed, ${MOD_SKIPPED} skipped (already signed), ${MOD_FAILED} failed"

if [[ "$MOD_FAILED" -gt 0 ]]; then
    if [[ "$SB_REQUIRED" == "yes" ]]; then
        echo "ERROR: [FINALIZE] ${MOD_FAILED} module(s) failed to sign; aborting Secure Boot build" >&2
        exit 1
    fi
    echo "WARNING: [FINALIZE] ${MOD_FAILED} module(s) failed to sign (Secure Boot not required for this build)"
fi
