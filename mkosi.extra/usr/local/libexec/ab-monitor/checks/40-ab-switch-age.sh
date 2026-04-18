#!/bin/bash
# checks/40-ab-switch-age.sh
#
# "Last successful A/B switch" = mtime of /var/lib/ab-health/status.env,
# which ab-health-gate writes on a successful bless. If older than
# AB_MONITOR_STALE_AB_SECS, alert.
set -uo pipefail

# shellcheck source=/dev/null
source /etc/default/ab-monitor
stale_after="${AB_MONITOR_STALE_AB_SECS:-604800}"

marker=/var/lib/ab-health/status.env
if [[ ! -f "${marker}" ]]; then
    jq -n --argjson s "${stale_after}" \
        '{key:"ab_stale", status:"fail", severity:"warning",
          summary:"no /var/lib/ab-health/status.env; A/B bless never succeeded on this slot",
          details:{threshold_secs:$s}}'
    exit 0
fi

now=$(date +%s)
last=$(stat -c %Y "${marker}")
age=$(( now - last ))

if (( age > stale_after )); then
    days=$(( age / 86400 ))
    jq -n --argjson a "${age}" --argjson d "${days}" --argjson s "${stale_after}" \
        '{key:"ab_stale", status:"fail", severity:"warning",
          summary:("no successful A/B switch in " + ($d|tostring) + " days"),
          details:{age_secs:$a, age_days:$d, threshold_secs:$s}}'
else
    days=$(( age / 86400 ))
    jq -n --argjson a "${age}" --argjson d "${days}" \
        '{key:"ab_stale", status:"ok", severity:"info",
          summary:("last bless " + ($d|tostring) + " days ago"),
          details:{age_secs:$a, age_days:$d}}'
fi
