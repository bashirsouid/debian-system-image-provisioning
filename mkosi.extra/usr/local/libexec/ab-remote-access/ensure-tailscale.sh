#!/bin/bash
# /usr/local/libexec/ab-remote-access/ensure-tailscale.sh
#
# Idempotent: safe to run on every boot and periodically.
# Exits 0 if tailscale ends up in the Running state.
# Exits non-zero and logs a clear reason otherwise.

set -euo pipefail

log() { printf '[ensure-tailscale] %s\n' "$*" >&2; }

# Wait a short while for tailscaled to be ready. We are ordered After=
# it in the unit but `tailscale status` can still fail briefly right
# after the daemon starts.
for _ in $(seq 1 10); do
    if tailscale status --json >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
log "current BackendState=${state}"

case "${state}" in
    Running)
        log "already authenticated; nothing to do."
        exit 0
        ;;
    Starting)
        # Daemon is mid-handshake. Give it a beat, then accept it.
        sleep 5
        state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
        if [[ "${state}" == "Running" ]]; then
            exit 0
        fi
        ;;
    NeedsLogin|Stopped|NoState|Unknown)
        : # fall through to re-auth
        ;;
    *)
        log "unexpected BackendState=${state}; attempting re-auth anyway."
        ;;
esac

# At this point we need to re-authenticate. The encrypted auth key must
# have been loaded by systemd via LoadCredentialEncrypted=.
if [[ -z "${CREDENTIALS_DIRECTORY:-}" || ! -r "${CREDENTIALS_DIRECTORY}/tailscale-authkey" ]]; then
    log "ERROR: tailscale-authkey credential not available; cannot re-auth."
    log "Hint: check that /etc/credstore.encrypted/tailscale-authkey exists and"
    log "      was built with scripts/package-credentials.sh on the build host."
    exit 1
fi

authkey="$(cat "${CREDENTIALS_DIRECTORY}/tailscale-authkey")"
if [[ -z "${authkey}" ]]; then
    log "ERROR: tailscale-authkey credential is empty."
    exit 1
fi

# Optional overrides from /etc/default/tailscale-up
: "${TAILSCALE_LOGIN_SERVER:=}"
: "${TAILSCALE_HOSTNAME:=$(hostname -s)}"
: "${TAILSCALE_TAGS:=}"
: "${TAILSCALE_ACCEPT_DNS:=true}"
: "${TAILSCALE_ACCEPT_ROUTES:=false}"
: "${TAILSCALE_SSH:=false}"
: "${TAILSCALE_OPERATOR:=}"

args=(
    --authkey="${authkey}"
    --hostname="${TAILSCALE_HOSTNAME}"
    --accept-dns="${TAILSCALE_ACCEPT_DNS}"
    --accept-routes="${TAILSCALE_ACCEPT_ROUTES}"
    --ssh="${TAILSCALE_SSH}"
    --reset
)

if [[ -n "${TAILSCALE_LOGIN_SERVER}" ]]; then
    args+=(--login-server="${TAILSCALE_LOGIN_SERVER}")
fi
if [[ -n "${TAILSCALE_TAGS}" ]]; then
    args+=(--advertise-tags="${TAILSCALE_TAGS}")
fi
if [[ -n "${TAILSCALE_OPERATOR}" ]]; then
    args+=(--operator="${TAILSCALE_OPERATOR}")
fi

log "running: tailscale up (authkey redacted) hostname=${TAILSCALE_HOSTNAME}"
if ! tailscale up "${args[@]}"; then
    log "ERROR: tailscale up failed."
    # Do not leak the authkey into process tables / cores.
    unset authkey
    exit 2
fi
unset authkey

# Verify. If this fails, the higher-layer health gate will flip the A/B
# slot bad and the system will roll back on the next boot.
state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
if [[ "${state}" != "Running" ]]; then
    log "ERROR: after auth, BackendState=${state} (expected Running)."
    exit 3
fi

log "authenticated; BackendState=Running."
exit 0
