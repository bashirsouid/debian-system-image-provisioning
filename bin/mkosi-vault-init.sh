#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT="${PROJECT_ROOT}/secrets/mkosi-secrets.json.age"
EXAMPLE="${PROJECT_ROOT}/secrets/mkosi-secrets.example.json"
AGE_KEYS="${HOME}/.config/mkosi-vault/age/keys.txt"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "${PROJECT_ROOT}/scripts/lib/host-deps.sh"

usage() {
    cat <<'USAGE'
Usage: bin/mkosi-vault-init.sh [options]

Interactive first-run setup for the local mkosi age vault.

Options:
  --vault PATH     vault to create (default: secrets/mkosi-secrets.json.age)
  --force          replace existing vault/config after confirmation
  -h, --help      show this help

The flow seeds an encrypted placeholder vault and can open it for editing.
USAGE
}

fail() {
    printf 'mkosi-vault-init: ERROR: %s\n' "$*" >&2
    exit 1
}

ask_yes_no() {
    local prompt="$1" default="${2:-no}" answer suffix
    case "$default" in
        yes) suffix='[Y/n]' ;;
        *) suffix='[y/N]' ;;
    esac
    read -r -p "${prompt} ${suffix} " answer
    answer="${answer:-$default}"
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

tmp_parent() {
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        printf '%s\n' /dev/shm
    else
        printf '%s\n' "${TMPDIR:-/tmp}"
    fi
}

write_config() {
    local mode="$1" identity="${2:-}"
    {
        printf 'mode=%s\n' "$mode"
        [[ -n "$identity" ]] && printf 'identity=%s\n' "$identity"
    } >"${VAULT}.conf"
    chmod 0600 "${VAULT}.conf"
}

encrypt_plaintext() {
    local plaintext="$1" mode="$2" out_tmp
    out_tmp="$(mktemp "$(tmp_parent)/mkosi-vault.XXXXXX.age")"
    case "$mode" in
        passphrase)
            age --passphrase --output "$out_tmp" "$plaintext"
            ;;
        recipient)
            age --recipients-file "${VAULT}.recipients" --output "$out_tmp" "$plaintext"
            ;;
        *)
            rm -f -- "$out_tmp"
            fail "unknown vault mode: $mode"
            ;;
    esac
    chmod 0600 "$out_tmp"
    mv -- "$out_tmp" "$VAULT"
}

FORCE=false
while (($#)); do
    case "$1" in
        --vault)
            [[ $# -ge 2 ]] || fail "--vault requires a path"
            VAULT="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
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

[[ -f "${EXAMPLE}" ]] || fail "example vault schema missing: ${EXAMPLE}"

if ! ab_hostdeps_have_all_commands age jq age-keygen; then
    ab_hostdeps_ensure_packages "local secret vault setup prerequisites" age jq || exit 1
fi
ab_hostdeps_ensure_commands "local secret vault setup prerequisites" age jq age-keygen || exit 1

if [[ -e "${VAULT}" && "${FORCE}" != true ]]; then
    fail "${VAULT} already exists. Use bin/mkosi-vault-edit.sh to edit it, or rerun with --force."
fi

echo "==> Local mkosi secret vault setup"
echo
echo "Choose how age should encrypt the vault:"
echo "  1) Password prompt (recommended simple Debian-native flow)"
echo "  2) Generate/use a local age identity"
echo "  3) Use an existing age recipient"
echo
echo "For hardware-backed unlock, age needs an age-compatible hardware-token"
echo "plugin/recipient. FIDO2 SSH keys are not unlocked through ssh-agent here."
echo

read -r -p "Selection [1]: " selection
selection="${selection:-1}"

mode=""
identity=""
install -d -m 0700 "$(dirname -- "${VAULT}")"

case "$selection" in
    1)
        mode="passphrase"
        rm -f -- "${VAULT}.recipients"
        write_config "$mode"
        ;;
    2)
        mode="recipient"
        install -d -m 0700 "$(dirname -- "${AGE_KEYS}")"
        if [[ ! -f "${AGE_KEYS}" ]]; then
            echo "==> Generating age identity: ${AGE_KEYS}"
            age-keygen -o "${AGE_KEYS}"
            chmod 0600 "${AGE_KEYS}"
        else
            echo "==> Reusing existing age identity: ${AGE_KEYS}"
            chmod 0600 "${AGE_KEYS}"
        fi
        age-keygen -y "${AGE_KEYS}" >"${VAULT}.recipients"
        chmod 0600 "${VAULT}.recipients"
        identity="${AGE_KEYS}"
        write_config "$mode" "$identity"
        ;;
    3)
        mode="recipient"
        read -r -p "Paste age recipient (age1... or plugin recipient): " recipient
        [[ -n "${recipient}" ]] || fail "recipient is required"
        printf '%s\n' "${recipient}" >"${VAULT}.recipients"
        chmod 0600 "${VAULT}.recipients"
        read -r -p "Optional identity file for decrypting this recipient: " identity
        write_config "$mode" "$identity"
        ;;
    *)
        fail "unknown selection: ${selection}"
        ;;
esac

tmp_plain="$(mktemp "$(tmp_parent)/mkosi-secrets.XXXXXX.json")"
cleanup() { rm -f -- "$tmp_plain"; }
trap cleanup EXIT

install -m 0600 "${EXAMPLE}" "${tmp_plain}"

echo "==> Encrypting placeholder vault: ${VAULT}"
encrypt_plaintext "$tmp_plain" "$mode"

echo "==> Vault initialized."
echo "    Vault:  ${VAULT}"
echo "    Config: ${VAULT}.conf"
[[ -f "${VAULT}.recipients" ]] && echo "    Recipients: ${VAULT}.recipients"
echo

if ask_yes_no "Open the encrypted vault for editing now?" yes; then
    "${PROJECT_ROOT}/bin/mkosi-vault-edit.sh" --vault "$VAULT"
fi
