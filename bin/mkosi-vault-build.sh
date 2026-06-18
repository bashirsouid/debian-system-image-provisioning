#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_VAULT="${PROJECT_ROOT}/secrets/mkosi-secrets.json.age"
SECRETS_DIR="${PROJECT_ROOT}/.mkosi-secrets"
MARKER="${SECRETS_DIR}/.generated-by-mkosi-vault-build"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "${PROJECT_ROOT}/scripts/lib/host-deps.sh"

VAULT="${DEFAULT_VAULT}"
IDENTITY=""
KEEP_UNLOCKED=false
REPLACE_STAGING=false
BUILD_ARGS=()

usage() {
    cat <<'USAGE'
Usage: bin/mkosi-vault-build.sh [vault options] -- [build.sh options]

Decrypt a local age vault into .mkosi-secrets/, run ./build.sh, then remove
the temporary plaintext staging directory.

Vault options:
  --vault PATH        encrypted age JSON file
                      (default: secrets/mkosi-secrets.json.age)
  --identity PATH     age identity file for recipient-encrypted vaults
  --replace-staging  deprecated no-op: a stale .mkosi-secrets/ is now always
                     replaced automatically
  --keep-unlocked    leave .mkosi-secrets/ in place after the build
  -h, --help         show this help

Examples:
  bin/mkosi-vault-build.sh -- --host x1g13
  bin/mkosi-vault-build.sh --vault secrets/laptop.json.age -- --profile "devbox ssh-server"

The vault schema is documented in docs/local-secret-vault.md.
USAGE
}

fail() {
    printf 'mkosi-vault-build: ERROR: %s\n' "$*" >&2
    exit 1
}

tmp_parent() {
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        printf '%s\n' /dev/shm
    else
        printf '%s\n' "${TMPDIR:-/tmp}"
    fi
}

config_value() {
    local key="$1" file="${VAULT}.conf"
    [[ -f "$file" ]] || return 1
    awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

expand_path() {
    local path="$1" tilde tilde_slash
    printf -v tilde '\176'
    tilde_slash="${tilde}/"
    if [[ "$path" == "$tilde" ]]; then
        printf '%s\n' "$HOME"
    elif [[ "${path:0:2}" == "$tilde_slash" ]]; then
        printf '%s/%s\n' "$HOME" "${path:2}"
    else
        printf '%s\n' "$path"
    fi
}

decrypt_vault() {
    local dest="$1" mode identity
    mode="$(config_value mode || true)"
    mode="${mode:-passphrase}"
    identity="${MKOSI_VAULT_IDENTITY:-${IDENTITY:-$(config_value identity || true)}}"

    # Make the upcoming age prompt unambiguous: it wants the VAULT passphrase,
    # which is distinct from the per-image LUKS disk passphrase build.sh asks
    # for later, and from any login password.
    vault_prompt_banner() {
        printf '\n==> Unlocking encrypted secret vault: %s\n' "$VAULT" >&2
        printf '    At the prompt below, enter the VAULT passphrase\n' >&2
        printf '    (the age secret-vault password — NOT your login or LUKS disk passphrase).\n\n' >&2
    }

    case "$mode" in
        passphrase)
            vault_prompt_banner
            age --decrypt "$VAULT" >"$dest"
            ;;
        recipient)
            if [[ -n "$identity" ]]; then
                printf '\n==> Unlocking encrypted secret vault %s with age identity %s\n' "$VAULT" "$identity" >&2
                age --decrypt --identity "$(expand_path "$identity")" "$VAULT" >"$dest"
            else
                vault_prompt_banner
                age --decrypt "$VAULT" >"$dest"
            fi
            ;;
        *)
            fail "unknown vault mode in ${VAULT}.conf: $mode"
            ;;
    esac
}

while (($#)); do
    case "$1" in
        --vault)
            [[ $# -ge 2 ]] || fail "--vault requires a path"
            VAULT="$2"
            shift 2
            ;;
        --identity)
            [[ $# -ge 2 ]] || fail "--identity requires a path"
            IDENTITY="$2"
            shift 2
            ;;
        --replace-staging)
            REPLACE_STAGING=true
            shift
            ;;
        --keep-unlocked)
            KEEP_UNLOCKED=true
            shift
            ;;
        --)
            shift
            BUILD_ARGS=("$@")
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option before --: $1"
            ;;
    esac
done

if ! ab_hostdeps_have_all_commands age jq; then
    ab_hostdeps_ensure_packages "local secret vault prerequisites" age jq || exit 1
fi
ab_hostdeps_ensure_commands "local secret vault prerequisites" age jq || exit 1

[[ -f "${VAULT}" ]] || fail "vault not found: ${VAULT}"

# The staging dir holds the DECRYPTED vault — it is ephemeral and must never
# survive between runs. Always clear any leftover (e.g. from a previous build
# that was interrupted before its cleanup trap fired) so the user never has to
# remove it by hand. --keep-unlocked only affects the POST-build cleanup below,
# not this pre-clean. --replace-staging is now the default and kept only for
# backward-compatible invocations.
if [[ -e "${SECRETS_DIR}" ]]; then
    rm -rf -- "${SECRETS_DIR}" 2>/dev/null \
        || fail "could not remove stale ${SECRETS_DIR} (owned by another user — a prior 'sudo' run?). Remove it manually: sudo rm -rf '${SECRETS_DIR}'"
fi

tmp_json="$(mktemp "$(tmp_parent)/mkosi-secrets.XXXXXX.json")"
# Scrub all plaintext secrets the instant we leave — normal completion, error,
# or Ctrl-C (e.g. at build.sh's LUKS passphrase prompt) — so decrypted material
# lives on disk only while the build genuinely needs it.
cleanup() {
    rm -f -- "${tmp_json}"
    if [[ "${KEEP_UNLOCKED}" != true && -f "${MARKER}" ]]; then
        rm -rf -- "${SECRETS_DIR}"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

decrypt_vault "${tmp_json}"
chmod 0600 "${tmp_json}"

install -d -m 0700 "${SECRETS_DIR}"
printf 'generated by bin/mkosi-vault-build.sh from %s\n' "${VAULT}" >"${MARKER}"
chmod 0600 "${MARKER}"

write_value() {
    local jq_expr="$1" relpath="$2" dest type
    dest="${SECRETS_DIR}/${relpath}"

    if ! jq -e "${jq_expr} != null" "${tmp_json}" >/dev/null; then
        return 0
    fi

    type="$(jq -r "${jq_expr} | type" "${tmp_json}")"
    install -d -m 0700 "$(dirname -- "${dest}")"

    if [[ "${type}" == "string" ]]; then
        jq -r "${jq_expr}" "${tmp_json}" >"${dest}"
    else
        jq "${jq_expr}" "${tmp_json}" >"${dest}"
    fi
    chmod 0600 "${dest}"
}

for name in \
    ssh-authorized-keys \
    tailscale-authkey \
    cloudflared-token \
    mailjet_public_key \
    mailjet_private_key \
    pagerduty-routing-key \
    healthchecks-ping-url \
    wifi-ssid \
    wifi-psk \
    s3-backup-credentials.json \
    users.json
do
    write_value ".[\"${name}\"]" "${name}"
done

# Kopia secrets are dynamically named (kopia-password, kopia-password-<name>,
# kopia-s3-creds-<name>.json, kopia-*-healthcheck-url), so enumerate every
# top-level key with the kopia- prefix rather than listing them above.
while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    write_value ".[\"${name}\"]" "${name}"
done < <(jq -r 'keys[] | select(startswith("kopia-"))' "${tmp_json}")

while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        write_value ".hosts[\"${host}\"][\"${name}\"]" "hosts/${host}/${name}"
    done < <(jq -r --arg host "${host}" '.hosts[$host] | keys[]' "${tmp_json}")
done < <(jq -r '.hosts // {} | keys[]' "${tmp_json}")

(
    cd "${PROJECT_ROOT}"
    ./build.sh "${BUILD_ARGS[@]}"
)
