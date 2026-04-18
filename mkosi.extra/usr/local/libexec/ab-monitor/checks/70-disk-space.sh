#!/bin/bash
# checks/70-disk-space.sh - / and /home must stay below thresholds
set -uo pipefail

worst_pct=0
worst_mp=""
details="{}"

while read -r mp pct; do
    [[ -z "${pct}" ]] && continue
    p="${pct%%%}"
    [[ "${p}" =~ ^[0-9]+$ ]] || continue
    if (( p > worst_pct )); then
        worst_pct=$p
        worst_mp=$mp
    fi
    details="$(jq --arg m "$mp" --argjson p "$p" '. + {($m): $p}' <<<"${details}")"
done < <(df -P --output=target,pcent / /home /var /mnt/data 2>/dev/null | awk 'NR>1 {print $1, $2}')

if (( worst_pct >= 95 )); then
    jq -n --argjson p "${worst_pct}" --arg m "${worst_mp}" --argjson d "${details}" \
        '{key:"disk_full", status:"fail", severity:"critical",
          summary:($m + " at " + ($p|tostring) + "% full"),
          details:$d}'
elif (( worst_pct >= 90 )); then
    jq -n --argjson p "${worst_pct}" --arg m "${worst_mp}" --argjson d "${details}" \
        '{key:"disk_full", status:"fail", severity:"warning",
          summary:($m + " at " + ($p|tostring) + "% full"),
          details:$d}'
else
    jq -n --argjson p "${worst_pct}" --argjson d "${details}" \
        '{key:"disk_full", status:"ok", severity:"info",
          summary:("worst mount " + ($p|tostring) + "%"),
          details:$d}'
fi
