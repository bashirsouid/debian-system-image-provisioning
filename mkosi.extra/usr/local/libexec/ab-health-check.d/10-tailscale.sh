#!/bin/bash
# /usr/local/libexec/ab-health-check.d/10-tailscale.sh
#
# Exits 0 if Tailscale is healthy (BackendState==Running).
# Exits non-zero to mark the current A/B slot unhealthy.
#
# If the tailscale-authkey credential was never provisioned, this hook
# treats the stack as "not configured for Tailscale" and exits 0. That
# way images that intentionally do not use Tailscale are not flagged.

set -euo pipefail

log() { printf '[ab-health 10-tailscale] %s\n' "$*" >&2; }

if [[ ! -f /etc/credstore.encrypted/tailscale-authkey ]]; then
    log "tailscale not configured (no credential); skipping."
    exit 0
fi

# Is the daemon even running?
if ! systemctl is-active --quiet tailscaled.service; then
    log "FAIL: tailscaled.service is not active."
    exit 1
fi

# Give tailscaled a generous window after boot before we flag it. The
# outer gate already sleeps AB_HEALTH_DELAY_SECS, so we only add a
# short extra cushion here.
for _ in $(seq 1 15); do
    state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
    [[ "${state}" == "Running" ]] && break
    sleep 2
done

state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
case "${state}" in
    Running)
        log "ok: BackendState=Running"
        exit 0
        ;;
    NeedsLogin)
        log "FAIL: tailscale needs login; auth key invalid or revoked?"
        exit 1
        ;;
    *)
        log "FAIL: BackendState=${state}"
        exit 1
        ;;
esac
