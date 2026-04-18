#!/bin/bash
# /usr/local/libexec/ab-monitor/notifiers/pagerduty.sh
#
# Sends an Events API v2 enqueue request to PagerDuty. Uses a stable
# dedup_key per (host, alert_key) so that repeated triggers auto-group
# into a single incident, and 'resolve' events properly close it.
#
# Docs: https://developer.pagerduty.com/docs/ZG9jOjExMDI5NTYx-events-api-v2

set -uo pipefail

# shellcheck source=/dev/null
source /etc/default/ab-monitor

log() { printf '[pagerduty] %s\n' "$*" >&2; }

: "${CREDENTIALS_DIRECTORY:?not set; pagerduty notifier must be run from a systemd unit with LoadCredentialEncrypted=}"

if [[ ! -r "${CREDENTIALS_DIRECTORY}/pagerduty-routing-key" ]]; then
    log "no pagerduty-routing-key credential; cannot page."
    exit 1
fi

ROUTING_KEY="$(cat "${CREDENTIALS_DIRECTORY}/pagerduty-routing-key")"

case "${AB_EVENT}" in
    trigger) action="trigger" ;;
    resolve) action="resolve" ;;
    *)
        log "unknown event ${AB_EVENT}; skipping."
        exit 0
        ;;
esac

# PagerDuty accepts severities: critical, error, warning, info.
case "${AB_SEVERITY}" in
    critical|error|warning|info) pd_sev="${AB_SEVERITY}" ;;
    *) pd_sev="error" ;;
esac

payload="$(jq -n \
    --arg rk "${ROUTING_KEY}" \
    --arg act "${action}" \
    --arg dk "${AB_DEDUP_KEY}" \
    --arg src "${AB_HOST}" \
    --arg sev "${pd_sev}" \
    --arg summary "${AB_SUMMARY:-${AB_KEY}}" \
    --arg comp "${AB_KEY}" \
    --arg grp "${AB_MONITOR_ENV:-home}" \
    --arg cls "monitor" \
    --arg ts "${AB_TIMESTAMP}" \
    --arg runbook "${AB_RUNBOOK_URL}" \
    --argjson details "${AB_DETAILS:-{\}}" \
    '{
      routing_key: $rk,
      event_action: $act,
      dedup_key: $dk,
      payload: {
        summary:   ($summary | .[0:1024]),
        source:    $src,
        severity:  $sev,
        timestamp: $ts,
        component: $comp,
        group:     $grp,
        class:     $cls,
        custom_details: $details
      },
      links: (if $runbook != "" then [{href:$runbook, text:"Runbook"}] else [] end)
    }')"

# PagerDuty resolve events should not send a full payload other than
# routing_key + event_action + dedup_key, strictly speaking. A full
# payload on resolve is tolerated but payload fields are ignored.

http_code="$(curl \
    --silent --show-error \
    --max-time "${AB_MONITOR_HTTP_TIMEOUT:-10}" \
    --output /dev/null \
    --write-out '%{http_code}' \
    -X POST https://events.pagerduty.com/v2/enqueue \
    -H "Content-Type: application/json" \
    --data-raw "${payload}" 2>&1)"
rc=$?

unset ROUTING_KEY

if (( rc != 0 )); then
    log "curl exit ${rc}"
    exit 2
fi

if [[ "${http_code}" != "202" ]]; then
    log "PagerDuty returned HTTP ${http_code}"
    exit 3
fi

log "sent: ${action} ${AB_DEDUP_KEY} (HTTP ${http_code})"
exit 0
