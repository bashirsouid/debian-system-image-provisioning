#!/bin/bash
# /usr/local/libexec/ab-health-check.d/20-cloudflared.sh
#
# Fails health if cloudflared is configured but not serving connections.

set -euo pipefail

log() { printf '[ab-health 20-cloudflared] %s\n' "$*" >&2; }

if [[ ! -f /etc/credstore.encrypted/cloudflared-token ]]; then
    log "cloudflared not configured (no credential); skipping."
    exit 0
fi

if ! systemctl is-active --quiet cloudflared.service; then
    log "FAIL: cloudflared.service is not active."
    exit 1
fi

# Cloudflared takes a few seconds to establish tunnels after start.
for _ in $(seq 1 30); do
    body="$(curl --silent --max-time 3 http://127.0.0.1:45123/ready || true)"
    if [[ -n "${body}" ]]; then
        status="$(jq -r '.status // 0' <<<"${body}" 2>/dev/null || echo 0)"
        ready="$(jq -r '.readyConnections // 0' <<<"${body}" 2>/dev/null || echo 0)"
        if [[ "${status}" == "200" && "${ready}" -ge 1 ]]; then
            log "ok: status=${status} readyConnections=${ready}"
            exit 0
        fi
    fi
    sleep 2
done

log "FAIL: cloudflared metrics did not report healthy tunnel in time."
exit 1
