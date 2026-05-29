#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT="${PROJECT_ROOT}/secrets/mkosi-secrets.json.age"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "${PROJECT_ROOT}/scripts/lib/host-deps.sh"

usage() {
    cat <<'USAGE'
Usage: bin/mkosi-vault-edit.sh [--vault PATH] [--identity PATH]

Open the local mkosi age vault in $EDITOR. The helper decrypts to a temporary
file, opens the editor, and re-encrypts the vault when the editor exits.

Options:
  --vault PATH       vault to edit (default: secrets/mkosi-secrets.json.age)
  --identity PATH    age identity file for recipient-encrypted vaults
  -h, --help        show this help
USAGE
}

fail() {
    printf 'mkosi-vault-edit: ERROR: %s\n' "$*" >&2
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

    case "$mode" in
        passphrase)
            age --decrypt "$VAULT" >"$dest"
            ;;
        recipient)
            if [[ -n "$identity" ]]; then
                age --decrypt --identity "$(expand_path "$identity")" "$VAULT" >"$dest"
            else
                age --decrypt "$VAULT" >"$dest"
            fi
            ;;
        *)
            fail "unknown vault mode in ${VAULT}.conf: $mode"
            ;;
    esac
}

encrypt_vault() {
    local src="$1" mode out_tmp
    mode="$(config_value mode || true)"
    mode="${mode:-passphrase}"
    out_tmp="$(mktemp "$(tmp_parent)/mkosi-vault.XXXXXX.age")"

    case "$mode" in
        passphrase)
            age --passphrase --output "$out_tmp" "$src"
            ;;
        recipient)
            [[ -f "${VAULT}.recipients" ]] || fail "recipient vault missing ${VAULT}.recipients"
            age --recipients-file "${VAULT}.recipients" --output "$out_tmp" "$src"
            ;;
        *)
            rm -f -- "$out_tmp"
            fail "unknown vault mode in ${VAULT}.conf: $mode"
            ;;
    esac

    chmod 0600 "$out_tmp"
    mv -- "$out_tmp" "$VAULT"
}

IDENTITY=""
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

if ! ab_hostdeps_have_all_commands age; then
    ab_hostdeps_ensure_packages "local secret vault edit prerequisites" age || exit 1
fi
ab_hostdeps_ensure_commands "local secret vault edit prerequisites" age || exit 1

[[ -f "${VAULT}" ]] || fail "vault not found: ${VAULT}. Run bin/mkosi-vault-init.sh first."

tmp_plain="$(mktemp "$(tmp_parent)/mkosi-secrets.XXXXXX.json")"
cleanup() { rm -f -- "$tmp_plain"; }
trap cleanup EXIT

decrypt_vault "$tmp_plain"
chmod 0600 "$tmp_plain"

editor="${EDITOR:-${VISUAL:-vi}}"
"$editor" "$tmp_plain"

encrypt_vault "$tmp_plain"
