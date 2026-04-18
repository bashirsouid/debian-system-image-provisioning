#!/bin/bash
# scripts/fetch-third-party-keys.sh
#
# Fetches the public signing keys for the third-party apt repos used
# at mkosi build time, verifies them against PINNED fingerprints, and
# installs them under mkosi.extra/etc/apt/keyrings/ in dearmored form.
#
# Fingerprints are pinned below. If a key rotates, the fetch will
# FAIL LOUDLY rather than silently trusting a new key. Update the
# pinned fingerprint in this file only after you have independently
# verified the new key.
#
# Call this from update-3rd-party-deps.sh.

set -euo pipefail

log()  { printf '[fetch-keys] %s\n'       "$*" >&2; }
fail() { printf '[fetch-keys] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
KEYRING_DIR="${REPO_ROOT}/mkosi.extra/etc/apt/keyrings"
mkdir -p "${KEYRING_DIR}"

for bin in curl gpg; do
    command -v "${bin}" >/dev/null || fail "missing tool: ${bin}"
done

fetch_and_verify() {
    local name="$1" url="$2" expected_fp="$3" out="$4"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' RETURN

    log "fetching ${name} from ${url}"
    curl --fail --silent --show-error --location --max-time 30 \
        --output "${tmp}/raw" "${url}"

    # Normalize: accept either ASCII-armored or binary input; always
    # emit binary dearmored to ${out}.
    GNUPGHOME="${tmp}/gnupg" install -d -m 700 "${tmp}/gnupg"
    if ! GNUPGHOME="${tmp}/gnupg" gpg --quiet --import "${tmp}/raw" 2>/dev/null; then
        fail "${name}: gpg could not import fetched data"
    fi

    # Get fingerprints of imported keys, normalized (no spaces, upper-case).
    mapfile -t got_fps < <(
        GNUPGHOME="${tmp}/gnupg" gpg --with-colons --fingerprint \
          | awk -F: '$1=="fpr" {print $10}'
    )

    local expected_norm
    expected_norm="$(tr -d '[:space:]' <<<"${expected_fp}" | tr '[:lower:]' '[:upper:]')"

    local matched="no"
    for fp in "${got_fps[@]}"; do
        if [[ "${fp}" == "${expected_norm}" ]]; then
            matched="yes"
            break
        fi
    done

    if [[ "${matched}" != "yes" ]]; then
        printf '[fetch-keys] ERROR: %s fingerprint mismatch.\n' "${name}" >&2
        printf '  expected: %s\n' "${expected_norm}" >&2
        printf '  got:\n' >&2
        printf '    %s\n' "${got_fps[@]}" >&2
        return 1
    fi

    # Dearmor (even if already binary, this normalizes).
    GNUPGHOME="${tmp}/gnupg" gpg --batch --yes --export "${expected_norm}" >"${out}"
    chmod 0644 "${out}"
    log "${name}: verified fingerprint ${expected_norm}, installed -> ${out}"
}

# -----------------------------------------------------------------------
# Cloudflare pkg signing key.
#
# Source: https://pkg.cloudflare.com/cloudflare-main.gpg
# Fingerprint source: https://pkg.cloudflare.com/ (published alongside
# the key). Verify manually the first time you add this key and update
# the pin below.
#
# TODO before first real use: replace the placeholder fingerprint with
# the real one verified against Cloudflare's documentation and commit
# the change. Fingerprints below are intentionally wrong placeholders
# so an unreviewed run cannot silently succeed.
# -----------------------------------------------------------------------
CLOUDFLARE_URL="https://pkg.cloudflare.com/cloudflare-main.gpg"
# UID: CloudFlare Software Packaging <help@cloudflare.com>
# Verified 2026-04 from:
#   https://github.com/cloudflare/cloudflared/issues/1549
#   https://community.cloudflare.com/t/invalid-gpg-key-.../430399
# NOTE: Cloudflare rotates signing keys occasionally. Re-verify from
# their current official docs before every major rebuild, and update
# this fingerprint if it has rotated.
CLOUDFLARE_FP="FBA8C0EE63617C5EED695C43254B391D8CACCBF8"

# -----------------------------------------------------------------------
# Tailscale apt signing key.
#
# Source: https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg
# Fingerprint source: https://tailscale.com/kb/1044/installing-tailscale
# -----------------------------------------------------------------------
TAILSCALE_URL="https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg"
# UID: Tailscale Inc. (Package repository signing key) <info@tailscale.com>
# Verified 2026-04 from:
#   https://pkgs.tailscale.com/stable/ (key shown during apt install)
#   https://github.com/tailscale/tailscale/issues/10636 (fingerprint confirmed)
#   https://github.com/tailscale/tailscale/issues/15770 (fingerprint confirmed)
TAILSCALE_FP="2596A99EAAB33821893C0A79458CA832957F5868"

# -----------------------------------------------------------------------
# Run. If you have not filled in real fingerprints, we fail closed.
# -----------------------------------------------------------------------
errors=0

if [[ "${CLOUDFLARE_FP}" == REPLACE_* ]]; then
    log "SKIP cloudflare: pin the fingerprint in this script before enabling."
    errors=$((errors+1))
else
    fetch_and_verify \
        cloudflare \
        "${CLOUDFLARE_URL}" \
        "${CLOUDFLARE_FP}" \
        "${KEYRING_DIR}/cloudflare-main.gpg" || errors=$((errors+1))
fi

if [[ "${TAILSCALE_FP}" == REPLACE_* ]]; then
    log "SKIP tailscale: pin the fingerprint in this script before enabling."
    errors=$((errors+1))
else
    fetch_and_verify \
        tailscale \
        "${TAILSCALE_URL}" \
        "${TAILSCALE_FP}" \
        "${KEYRING_DIR}/tailscale-archive-keyring.gpg" || errors=$((errors+1))
fi

if (( errors > 0 )); then
    fail "${errors} key(s) not fetched. Pin fingerprints in scripts/fetch-third-party-keys.sh."
fi

log "all third-party keys fetched and verified."
