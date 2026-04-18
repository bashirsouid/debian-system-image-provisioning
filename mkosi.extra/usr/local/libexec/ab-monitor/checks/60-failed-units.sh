#!/bin/bash
# checks/60-failed-units.sh - any systemd unit in 'failed' state
set -uo pipefail

# Exclude units we know we don't care about (our own watchdogs might
# briefly be failed between retries).
IGNORE='^(tailscale-watchdog|cloudflared-watchdog)\.service$'

list="$(systemctl list-units --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -Ev "${IGNORE}" || true)"

if [[ -z "${list}" ]]; then
    jq -n '{key:"failed_units", status:"ok", severity:"info", summary:"no failed units", details:{}}'
    exit 0
fi

count=$(wc -l <<<"${list}")
sample=$(head -n5 <<<"${list}" | tr '\n' ',' | sed 's/,$//')

jq -n --argjson c "${count}" --arg s "${sample}" --arg l "${list}" \
    '{key:"failed_units", status:"fail", severity:"error",
      summary:(($c|tostring) + " failed unit(s): " + $s),
      details:{count:$c, units:($l | split("\n") | map(select(length>0)))}}'
