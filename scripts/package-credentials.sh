#!/usr/bin/env bash
# scripts/package-credentials.sh
#
# Takes plaintext secrets in .mkosi-secrets/ and produces build assets:
#
#   mkosi.extra/etc/credstore.encrypted/tailscale-authkey    (if provided)
#   mkosi.extra/etc/credstore.encrypted/cloudflared-token    (if provided)
#   mkosi.extra/etc/ssh/authorized_keys.d/<user>             (always, required)
#   mkosi.extra/etc/ssh/sshd_config.d/50-hardening.conf      (username substituted)
#   mkosi.extra/var/lib/systemd/credential.secret            (per-image key)
#
# Only ssh-authorized-keys is required. tailscale-authkey and
# cloudflared-token are optional: when absent, the corresponding
# systemd unit on the booted image will skip itself (ConditionPathExists=
# on /etc/credstore.encrypted/<name>).

set -euo pipefail

log()  { printf '[package-credentials] %s\n'        "$*" >&2; }
warn() { printf '[package-credentials] WARN: %s\n'  "$*" >&2; }
fail() { printf '[package-credentials] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.mkosi-secrets"
EXTRA_DIR="${REPO_ROOT}/mkosi.extra"

NON_INTERACTIVE="${AB_NON_INTERACTIVE:-false}"
HOST=""
USER_NAME=""

while (($#)); do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --user) USER_NAME="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) fail "unknown arg: $1" ;;
    esac
done

[[ -d "${SECRETS_DIR}" ]] || fail "${SECRETS_DIR} missing. Run scripts/verify-build-secrets.sh first."

# Resolve login username.
if [[ -z "${USER_NAME}" ]]; then
    if [[ -f "${REPO_ROOT}/.users.json" ]]; then
        USER_NAME="$(jq -r '[.[] | select(.can_login==true)][0].username // empty' "${REPO_ROOT}/.users.json")"
    fi
    if [[ -z "${USER_NAME}" ]] && [[ -f "${REPO_ROOT}/.env" ]]; then
        USER_NAME="$(awk -F= '/^INITIAL_USERNAME=/ {print $2}' "${REPO_ROOT}/.env" | tr -d '"')"
    fi
    [[ -n "${USER_NAME}" ]] || fail "could not resolve login username. Pass --user."
fi
log "login user: ${USER_NAME}"

resolve_secret() {
    local name="$1"
    if [[ -n "${HOST}" && -f "${SECRETS_DIR}/hosts/${HOST}/${name}" ]]; then
        printf '%s' "${SECRETS_DIR}/hosts/${HOST}/${name}"; return 0
    fi
    if [[ -f "${SECRETS_DIR}/${name}" ]]; then
        printf '%s' "${SECRETS_DIR}/${name}"; return 0
    fi
    return 1
}

CREDSTORE="${EXTRA_DIR}/etc/credstore.encrypted"
AUTHKEYS_D="${EXTRA_DIR}/etc/ssh/authorized_keys.d"
SSHD_D="${EXTRA_DIR}/etc/ssh/sshd_config.d"
CRED_SECRET_DIR="${EXTRA_DIR}/var/lib/systemd"

mkdir -p "${CREDSTORE}" "${AUTHKEYS_D}" "${SSHD_D}" "${CRED_SECRET_DIR}"

# Per-image credential.secret
CRED_SECRET="${CRED_SECRET_DIR}/credential.secret"
if [[ ! -f "${CRED_SECRET}" ]]; then
    log "generating per-image credential.secret"
    umask 077
    head -c 32 /dev/urandom >"${CRED_SECRET}"
fi
chmod 0400 "${CRED_SECRET}"

SDC_ARGS=(--with-key=host)
FALLBACK_TO_HOST_KEY=0
if systemd-creds --help 2>&1 | grep -q -- --host-key-path; then
    SDC_ARGS+=(--host-key-path "${CRED_SECRET}")
else
    warn "This host's systemd-creds is too old for --host-key-path (per-image keys)."
    warn "We can fallback to using this host's master secret key instead, but the finished"
    warn "image will share a master key with this machine. This is a security risk."
    echo "" >&2

    # Check for sudo availability if we need to copy the host secret.
    SUDO_AVAILABLE=0
    if command -v sudo >/dev/null 2>&1; then
        SUDO_AVAILABLE=1
    fi

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        if [[ "${FORCE_HOST_KEY:-}" == "1" ]]; then
            log "FORCE_HOST_KEY=1 detected; proceeding with host secret fallback in non-interactive mode."
            FALLBACK_TO_HOST_KEY=1
        else
            warn "Non-interactive mode: skipping host-key fallback. Image may be broken."
            fail "Upgrade systemd (trixie 254+) or build interactively to accept the risk."
        fi
    elif [[ "${FORCE_HOST_KEY:-}" == "1" ]]; then
        log "FORCE_HOST_KEY=1 detected; proceeding with host secret fallback."
        FALLBACK_TO_HOST_KEY=1
    elif [[ -t 0 ]]; then
        if [[ "${SUDO_AVAILABLE}" == "0" ]]; then
            warn "sudo is NOT available; cannot copy host secret even if accepted. Skipping prompt."
            fail "Upgrade systemd (trixie 254+) or install sudo."
        fi

        REPLY="n"
        if read -t 30 -p "[package-credentials] Continue using host secret? [y/N] " -n 1 -r >&2; then
            echo "" >&2
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                FALLBACK_TO_HOST_KEY=1
            else
                fail "User rejected fallback. Upgrade systemd (trixie 254+) or build in a container."
            fi
        else
            echo "" >&2
            fail "Interactive prompt timed out (30s). Defaulting to No. Upgrade systemd."
        fi
    else
        fail "Terminal not interactive and --host-key-path missing. Upgrade systemd (trixie 254+) or build in an interactive terminal."
    fi
fi

if (( FALLBACK_TO_HOST_KEY )); then
    HOST_SECRET="/var/lib/systemd/credential.secret"
    if [[ ! -f "${HOST_SECRET}" ]]; then
        log "Host secret missing. Generating automatically via 'sudo systemd-creds setup'..."
        sudo systemd-creds setup || fail "Failed to generate host secret. Run 'sudo systemd-creds setup' manually."
    fi
    log "copying host secret to image (requires sudo)..."
    sudo cp "${HOST_SECRET}" "${CRED_SECRET}"
    sudo chown "$(id -u):$(id -g)" "${CRED_SECRET}"
    chmod 0400 "${CRED_SECRET}"
fi

encrypt_credential() {
    local name="$1" src="$2" dest="$3"
    log "encrypting ${name} -> ${dest}"
    if (( FALLBACK_TO_HOST_KEY )); then
        sudo systemd-creds encrypt "${SDC_ARGS[@]}" --name="${name}" "${src}" "${dest}"
        sudo chown "$(id -u):$(id -g)" "${dest}"
    else
        systemd-creds encrypt "${SDC_ARGS[@]}" --name="${name}" "${src}" "${dest}"
    fi
    chmod 0600 "${dest}"
}

# --- REQUIRED: ssh authorized_keys --------------------------------------
if ak_path="$(resolve_secret ssh-authorized-keys)"; then
    install -m 0644 -D "${ak_path}" "${AUTHKEYS_D}/${USER_NAME}"
    log "installed ${USER_NAME} authorized_keys"
else
    fail "ssh-authorized-keys is REQUIRED. Run scripts/verify-build-secrets.sh for details."
fi

# --- OPTIONAL: tailscale-authkey ----------------------------------------
if ts_path="$(resolve_secret tailscale-authkey)"; then
    encrypt_credential tailscale-authkey "${ts_path}" "${CREDSTORE}/tailscale-authkey"
else
    warn "tailscale-authkey absent; skipping. tailscale-up.service will no-op via ConditionPathExists="
fi

# --- OPTIONAL: cloudflared-token ----------------------------------------
if cf_path="$(resolve_secret cloudflared-token)"; then
    encrypt_credential cloudflared-token "${cf_path}" "${CREDSTORE}/cloudflared-token"
else
    warn "cloudflared-token absent; skipping. cloudflared.service will no-op via ConditionPathExists="
fi

# --- Template sshd_config hardening file --------------------------------
TEMPLATE="${SSHD_D}/50-hardening.conf"
if [[ -f "${TEMPLATE}" ]]; then
    if grep -q '__INITIAL_USERNAME__' "${TEMPLATE}"; then
        log "substituting __INITIAL_USERNAME__ -> ${USER_NAME}"
        tmp="$(mktemp)"
        sed "s/__INITIAL_USERNAME__/${USER_NAME}/g" "${TEMPLATE}" >"${tmp}"
        mv "${tmp}" "${TEMPLATE}"
        chmod 0644 "${TEMPLATE}"
    fi
else
    warn "${TEMPLATE} not found; skipping username substitution."
fi

log "done. Credentials under ${CREDSTORE} (only for present secrets)."
