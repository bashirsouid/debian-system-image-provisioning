#!/bin/bash
# scripts/verify-build-secrets.sh
#
# Refuses to build if any required secret is missing or malformed. Call
# this from the top of build.sh BEFORE invoking mkosi. Exits non-zero
# with a clear human-readable error on failure.
#
# Usage:
#   ./scripts/verify-build-secrets.sh [--strict] [--profile <p>] [--host <h>]
#
#   --strict        also fail on weak (but syntactically valid) secrets
#   --profile <p>   profile name (devbox, server, macbook) for scoped checks
#   --host <h>      host name for host-scoped checks
#
# Secrets live under .mkosi-secrets/ on the build host. That directory
# is in .gitignore. This script never prints a secret to stdout.
#
# Required layout:
#   .mkosi-secrets/tailscale-authkey         # text file, single line
#   .mkosi-secrets/cloudflared-token         # text file, single line
#   .mkosi-secrets/ssh-authorized-keys       # authorized_keys format
#
# Optional:
#   .mkosi-secrets/hosts/<host>/tailscale-authkey
#   .mkosi-secrets/hosts/<host>/cloudflared-token
#   .mkosi-secrets/hosts/<host>/ssh-authorized-keys
#       Per-host overrides. If present, take precedence over the
#       top-level files.

set -euo pipefail

STRICT="no"
PROFILE=""
HOST=""

while (($#)); do
    case "$1" in
        --strict)  STRICT="yes"; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --host)    HOST="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.mkosi-secrets"

fail() { printf '[verify-build-secrets] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[verify-build-secrets] WARN:  %s\n' "$*" >&2; }
ok()   { printf '[verify-build-secrets] ok:    %s\n' "$*" >&2; }

if [[ ! -d "${SECRETS_DIR}" ]]; then
    fail "${SECRETS_DIR} does not exist. Create it and populate:
    tailscale-authkey     (tskey-auth-...)
    cloudflared-token     (base64 tunnel token from CF dashboard)
    ssh-authorized-keys   (sk-ed25519@openssh.com ... entries)
See docs/remote-access.md for details."
fi

# Refuse to proceed if the secrets directory is world-readable.
mode="$(stat -c '%a' "${SECRETS_DIR}")"
if [[ "${mode}" != "700" && "${mode}" != "750" && "${mode}" != "500" ]]; then
    fail "${SECRETS_DIR} has permissions ${mode}. Run: chmod 700 ${SECRETS_DIR}"
fi

# Refuse to proceed if the secrets directory is tracked by git.
if git -C "${REPO_ROOT}" ls-files --error-unmatch .mkosi-secrets >/dev/null 2>&1; then
    fail ".mkosi-secrets/ appears to be tracked by git. Unstage it and add it to .gitignore."
fi

resolve_secret() {
    # Resolves a secret path, preferring per-host then top-level.
    local name="$1"
    if [[ -n "${HOST}" && -f "${SECRETS_DIR}/hosts/${HOST}/${name}" ]]; then
        printf '%s' "${SECRETS_DIR}/hosts/${HOST}/${name}"
        return 0
    fi
    if [[ -f "${SECRETS_DIR}/${name}" ]]; then
        printf '%s' "${SECRETS_DIR}/${name}"
        return 0
    fi
    return 1
}

check_file_perms() {
    local path="$1"
    local m
    m="$(stat -c '%a' "${path}")"
    case "${m}" in
        400|600|440|640) : ;;
        *) fail "${path} has permissions ${m}; expected 400, 440, 600, or 640. Run: chmod 600 ${path}" ;;
    esac
}

# --- tailscale auth key ---------------------------------------------------
if ! ts_path="$(resolve_secret tailscale-authkey)"; then
    fail "missing tailscale-authkey. Provision a reusable auth key at
  https://login.tailscale.com/admin/settings/keys and write it to
  ${SECRETS_DIR}/tailscale-authkey (single line, no trailing newline)."
fi
check_file_perms "${ts_path}"
ts_content="$(<"${ts_path}")"
ts_content="${ts_content%$'\n'}"
if [[ "${ts_content}" != tskey-auth-* && "${ts_content}" != tskey-* ]]; then
    fail "tailscale-authkey does not look like a Tailscale auth key
(expected to start with tskey-auth-...). File: ${ts_path}"
fi
if [[ "${#ts_content}" -lt 40 ]]; then
    fail "tailscale-authkey looks truncated (${#ts_content} chars)."
fi
if [[ "${STRICT}" == "yes" && "${ts_content}" != tskey-auth-*-* ]]; then
    warn "tailscale-authkey is not a tagged reusable key; --strict mode
        recommends tagged ephemeral or tagged reusable keys only."
fi
ok "tailscale-authkey present and well-formed."

# --- cloudflared tunnel token --------------------------------------------
if ! cf_path="$(resolve_secret cloudflared-token)"; then
    fail "missing cloudflared-token. Create a Named Tunnel at
  https://one.dash.cloudflare.com/?to=/:account/networks/tunnels and copy
  the connector install token into ${SECRETS_DIR}/cloudflared-token."
fi
check_file_perms "${cf_path}"
cf_content="$(<"${cf_path}")"
cf_content="${cf_content%$'\n'}"
if [[ "${#cf_content}" -lt 80 ]]; then
    fail "cloudflared-token looks too short (${#cf_content} chars); expected a long base64 string."
fi
# Cloudflare tunnel tokens are eyJ... (base64-encoded JSON) in current
# dashboards, but older ones are opaque. Accept either shape; just
# require base64-safe characters.
if [[ ! "${cf_content}" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
    fail "cloudflared-token contains characters that do not look base64."
fi
ok "cloudflared-token present and plausible."

# --- ssh authorized_keys -------------------------------------------------
if ! ak_path="$(resolve_secret ssh-authorized-keys)"; then
    fail "missing ssh-authorized-keys. Generate a hardware-backed key on
your client:
    ssh-keygen -t ed25519-sk -O resident -O verify-required -C '<host>'
Then append the PUBLIC key to ${SECRETS_DIR}/ssh-authorized-keys."
fi
check_file_perms "${ak_path}"

have_sk_key="no"
line_no=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$((line_no+1))
    # Skip blanks and comments
    [[ -z "${line// }" || "${line}" =~ ^[[:space:]]*# ]] && continue
    case "${line}" in
        *sk-ed25519@openssh.com*|*sk-ecdsa-sha2-nistp256@openssh.com*)
            have_sk_key="yes"
            ;;
        ssh-rsa*|ssh-dss*)
            if [[ "${STRICT}" == "yes" ]]; then
                fail "line ${line_no} of ssh-authorized-keys uses a legacy key type (ssh-rsa / ssh-dss).
Use ed25519 or sk-ed25519 instead, or drop --strict."
            else
                warn "line ${line_no} uses a legacy key type (ssh-rsa / ssh-dss)."
            fi
            ;;
        ssh-ed25519*|ecdsa-sha2-nistp*)
            if [[ "${STRICT}" == "yes" ]]; then
                warn "line ${line_no} is a software-only key. --strict mode expects only hardware-backed sk-* keys."
            fi
            ;;
        *)
            warn "line ${line_no} has an unrecognized key type; continuing."
            ;;
    esac
done <"${ak_path}"

if [[ "${have_sk_key}" != "yes" ]]; then
    if [[ "${STRICT}" == "yes" ]]; then
        fail "ssh-authorized-keys contains no hardware-backed (sk-*) key.
--strict mode requires at least one sk-ed25519@openssh.com or
sk-ecdsa-sha2-nistp256@openssh.com entry."
    else
        warn "ssh-authorized-keys contains no hardware-backed (sk-*) key.
Consider generating one with: ssh-keygen -t ed25519-sk -O resident -O verify-required"
    fi
fi
ok "ssh-authorized-keys present (${line_no} lines read)."

# --- host tool prerequisites --------------------------------------------
for bin in systemd-creds jq; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
        fail "required host tool missing: ${bin}. Install with: sudo apt-get install --no-install-recommends systemd-container jq"
    fi
done
ok "host tools present: systemd-creds, jq."

printf '[verify-build-secrets] all required secrets validated (profile=%s host=%s strict=%s)\n' \
    "${PROFILE:-<none>}" "${HOST:-<none>}" "${STRICT}" >&2
exit 0
