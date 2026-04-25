#!/bin/bash
# checks/10-tailscale.sh - Tailscale session health
set -uo pipefail

if [[ ! -f /etc/credstore.encrypted/tailscale-authkey ]]; then
    jq -n '{key:"tailscale_down", status:"ok", severity:"info", summary:"not configured", details:{}}'
    exit 0
fi

if ! systemctl is-active --quiet tailscaled.service; then
    jq -n '{key:"tailscale_down", status:"fail", severity:"critical",
            summary:"tailscaled.service inactive",
            details:{daemon:"inactive"}}'
    exit 0
fi

state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')"
peers_online="$(tailscale status --json 2>/dev/null | jq '[.Peer[]? | select(.Online==true)] | length' 2>/dev/null || echo 0)"

if [[ "${state}" == "Running" ]]; then
    jq -n --arg s "${state}" --argjson p "${peers_online:-0}" \
        '{key:"tailscale_down", status:"ok", severity:"info",
          summary:"Running",
          details:{backend_state:$s, peers_online:$p}}'
else
    jq -n --arg s "${state}" \
        '{key:"tailscale_down", status:"fail", severity:"critical",
          summary:("Tailscale BackendState=" + $s),
          details:{backend_state:$s}}'
fi
