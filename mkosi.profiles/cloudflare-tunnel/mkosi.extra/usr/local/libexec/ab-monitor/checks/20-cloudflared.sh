#!/bin/bash
# checks/20-cloudflared.sh - Cloudflare tunnel health
set -uo pipefail

if [[ ! -f /etc/credstore.encrypted/cloudflared-token ]]; then
    jq -n '{key:"cloudflared_down", status:"ok", severity:"info", summary:"not configured", details:{}}'
    exit 0
fi

if ! systemctl is-active --quiet cloudflared.service; then
    jq -n '{key:"cloudflared_down", status:"fail", severity:"critical",
            summary:"cloudflared.service inactive", details:{}}'
    exit 0
fi

body="$(curl --silent --max-time 3 http://127.0.0.1:45123/ready 2>/dev/null || true)"
if [[ -z "${body}" ]]; then
    jq -n '{key:"cloudflared_down", status:"fail", severity:"critical",
            summary:"cloudflared /ready unreachable",
            details:{metrics:"unreachable"}}'
    exit 0
fi

ready="$(jq -r '.readyConnections // 0' <<<"${body}")"
statusc="$(jq -r '.status // 0' <<<"${body}")"

if [[ "${statusc}" == "200" && "${ready}" -ge 1 ]]; then
    jq -n --argjson r "${ready}" --argjson s "${statusc}" \
        '{key:"cloudflared_down", status:"ok", severity:"info",
          summary:("ready_connections=" + ($r|tostring)),
          details:{status:$s, ready_connections:$r}}'
else
    jq -n --argjson r "${ready:-0}" --argjson s "${statusc:-0}" \
        '{key:"cloudflared_down", status:"fail", severity:"critical",
          summary:"cloudflared reports no ready connections",
          details:{status:$s, ready_connections:$r}}'
fi
