#!/bin/bash
# scripts/package-credentials.sh
#
# Takes the plaintext secrets in .mkosi-secrets/ and transforms them
# into assets that get baked into the image:
#
#   mkosi.extra/etc/credstore.encrypted/tailscale-authkey
#   mkosi.extra/etc/credstore.encrypted/cloudflared-token
#         -> encrypted by `systemd-creds encrypt`. Only systemd on the
#            target host can decrypt them, via the service units'
#            LoadCredentialEncrypted= directives.
#
#   mkosi.extra/etc/ssh/authorized_keys.d/<user>
#         -> plaintext public keys, owned root:root mode 644. Public
#            key material, not secret.
#
#   mkosi.extra/etc/ssh/sshd_config.d/50-hardening.conf
#         -> has __INITIAL_USERNAME__ replaced with the actual login
#            user. This file is under mkosi.extra/ so mkosi copies it
#            verbatim.
#
# Encryption mode for systemd-creds:
#
#   The "cleanest" option is --with-key=tpm2. That produces a blob
#   that is cryptographically bound to the target machine's TPM. But
#   the target TPM does not exist at build time, so you cannot
#   --with-key=tpm2 on the build host for a target you have never
#   booted.
#
#   The option that works at build time and still keeps plaintext off
#   the image is --with-key=null, which writes a credential encrypted
#   with a static zero key. Anyone with the image file can recover
#   the plaintext. That is worse than plaintext on a 0600 file for
#   this use case, so we do NOT use --with-key=null by default.
#
#   What this script does instead: generate a fresh per-image
#   credential secret in
#       mkosi.extra/var/lib/systemd/credential.secret
#   and encrypt the secrets with --with-key=host against that file.
#   The credential.secret is baked into the image at 0400 root:root.
#   systemd on the target will find it at /var/lib/systemd/credential.secret
#   on first boot and use it transparently.
#
#   Threat model: if someone steals the built image, they can recover
#   plaintext. That is no worse than plaintext on 0600 root-only,
#   which is your current baseline via ExtraTrees. We are not making
#   it worse, we are removing the footgun of "one wrong file in
#   .mkosi-secrets/ lands at /" by making secret placement explicit.
#
#   The upgrade path, once Secure Boot + LUKS + TPM is wired in, is
#   to drop credential.secret from the image and re-encrypt the
#   credstore on first boot with --with-key=tpm2. That is a separate
#   change; this script gives you a clean place to make it.

set -euo pipefail

log()  { printf '[package-credentials] %s\n' "$*" >&2; }
fail() { printf '[package-credentials] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.mkosi-secrets"
EXTRA_DIR="${REPO_ROOT}/mkosi.extra"

HOST=""
USER_NAME=""

while (($#)); do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --user) USER_NAME="$2"; shift 2 ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) fail "unknown arg: $1" ;;
    esac
done

[[ -d "${SECRETS_DIR}" ]] || fail "${SECRETS_DIR} missing. Run scripts/verify-build-secrets.sh first."

# Resolve the login username from .users.json if not explicitly given.
if [[ -z "${USER_NAME}" ]]; then
    if [[ -f "${REPO_ROOT}/.users.json" ]]; then
        USER_NAME="$(jq -r '[.[] | select(.can_login==true)][0].username // empty' "${REPO_ROOT}/.users.json")"
    fi
    if [[ -z "${USER_NAME}" ]]; then
        if [[ -f "${REPO_ROOT}/.env" ]]; then
            # shellcheck disable=SC1091
            USER_NAME="$(awk -F= '/^INITIAL_USERNAME=/ {print $2}' "${REPO_ROOT}/.env" | tr -d '"')"
        fi
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

# --- prepare target paths ------------------------------------------------
CREDSTORE="${EXTRA_DIR}/etc/credstore.encrypted"
AUTHKEYS_D="${EXTRA_DIR}/etc/ssh/authorized_keys.d"
SSHD_D="${EXTRA_DIR}/etc/ssh/sshd_config.d"
CRED_SECRET_DIR="${EXTRA_DIR}/var/lib/systemd"

mkdir -p "${CREDSTORE}" "${AUTHKEYS_D}" "${SSHD_D}" "${CRED_SECRET_DIR}"

# --- per-image credential.secret ----------------------------------------
CRED_SECRET="${CRED_SECRET_DIR}/credential.secret"
if [[ ! -f "${CRED_SECRET}" ]]; then
    log "generating per-image credential.secret"
    umask 077
    head -c 32 /dev/urandom >"${CRED_SECRET}"
fi
chmod 0400 "${CRED_SECRET}"

# systemd-creds looks up the host key at /var/lib/systemd/credential.secret
# by default. We run it with --with-key=host and redirect the lookup
# via --host-key-path (available on systemd 254+, trixie ships 256+).
SDC_ARGS=(--with-key=host)
if systemd-creds --help 2>&1 | grep -q -- --host-key-path; then
    SDC_ARGS+=(--host-key-path "${CRED_SECRET}")
else
    # Fallback: temporarily symlink our file into place on the build
    # host. Only works if the build host does not have its own
    # credential.secret (rare).
    fail "this host's systemd-creds is too old (need --host-key-path). Upgrade systemd or build in a container with trixie+."
fi

encrypt_credential() {
    local name="$1" src="$2" dest="$3"
    log "encrypting ${name} -> ${dest}"
    # --name= binds the credential to a specific consumer name so it
    # cannot be used under a different LoadCredential= name.
    systemd-creds encrypt "${SDC_ARGS[@]}" --name="${name}" "${src}" "${dest}"
    chmod 0600 "${dest}"
}

# --- tailscale-authkey ---------------------------------------------------
if ts_path="$(resolve_secret tailscale-authkey)"; then
    encrypt_credential tailscale-authkey "${ts_path}" "${CREDSTORE}/tailscale-authkey"
else
    fail "tailscale-authkey missing; run scripts/verify-build-secrets.sh first."
fi

# --- cloudflared-token ---------------------------------------------------
if cf_path="$(resolve_secret cloudflared-token)"; then
    encrypt_credential cloudflared-token "${cf_path}" "${CREDSTORE}/cloudflared-token"
else
    fail "cloudflared-token missing; run scripts/verify-build-secrets.sh first."
fi

# --- authorized_keys -----------------------------------------------------
if ak_path="$(resolve_secret ssh-authorized-keys)"; then
    install -m 0644 "${ak_path}" "${AUTHKEYS_D}/${USER_NAME}"
    log "installed authorized_keys -> /etc/ssh/authorized_keys.d/${USER_NAME}"
else
    fail "ssh-authorized-keys missing; run scripts/verify-build-secrets.sh first."
fi

# --- template sshd_config hardening file ---------------------------------
TEMPLATE="${SSHD_D}/50-hardening.conf"
if [[ -f "${TEMPLATE}" ]]; then
    if grep -q '__INITIAL_USERNAME__' "${TEMPLATE}"; then
        log "substituting __INITIAL_USERNAME__ -> ${USER_NAME} in 50-hardening.conf"
        # Write to a tmpfile then move, to keep the file atomic and to
        # preserve behavior across re-runs.
        tmp="$(mktemp)"
        sed "s/__INITIAL_USERNAME__/${USER_NAME}/g" "${TEMPLATE}" >"${tmp}"
        mv "${tmp}" "${TEMPLATE}"
        chmod 0644 "${TEMPLATE}"
    fi
else
    log "WARNING: ${TEMPLATE} not found; skipping username substitution."
fi

log "done. Credential blobs under ${CREDSTORE}, host key at ${CRED_SECRET}."
