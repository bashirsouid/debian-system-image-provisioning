#!/bin/bash
# checks/80-time-sync.sh - clock must be NTP-synced
set -uo pipefail

synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
if [[ "${synced}" == "yes" ]]; then
    jq -n '{key:"time_desync", status:"ok", severity:"info", summary:"clock synced", details:{}}'
else
    jq -n --arg s "${synced}" \
        '{key:"time_desync", status:"fail", severity:"warning",
          summary:"clock not NTP-synced; TLS cert verification will fail",
          details:{ntp_synchronized:$s}}'
fi
