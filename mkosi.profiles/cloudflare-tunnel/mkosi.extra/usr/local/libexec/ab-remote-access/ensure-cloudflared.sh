#!/bin/bash
# /usr/local/libexec/ab-remote-access/ensure-cloudflared.sh
#
# Probes cloudflared's metrics /ready endpoint. If the endpoint is not
# reachable or not reporting healthy connection count > 0, restart the
# cloudflared service.
#
# This is belt-and-suspenders with systemd's built-in Restart=always:
# restart handles crashes, this catches the "process is up but all
# tunnels are wedged" case.

set -euo pipefail

log() { printf '[ensure-cloudflared] %s\n' "$*" >&2; }

METRICS_URL="http://127.0.0.1:45123/ready"

# /ready returns JSON like:
#   {"status":200,"readyConnections":4,"connectorId":"..."}
# A healthy tunnel has status==200 and readyConnections>=1.

body="$(curl --silent --show-error --max-time 5 "${METRICS_URL}" || true)"

if [[ -z "${body}" ]]; then
    log "metrics endpoint unreachable; restarting cloudflared.service"
    systemctl restart cloudflared.service
    exit 0
fi

status="$(jq -r '.status // 0' <<<"${body}" 2>/dev/null || echo 0)"
ready="$(jq -r '.readyConnections // 0' <<<"${body}" 2>/dev/null || echo 0)"

if [[ "${status}" != "200" || "${ready}" -lt 1 ]]; then
    log "unhealthy: status=${status} readyConnections=${ready}; restarting."
    systemctl restart cloudflared.service
    exit 0
fi

log "healthy: status=${status} readyConnections=${ready}"
exit 0
