#!/bin/bash
# /usr/local/libexec/ab-monitor/notify.sh
#
# Fans one alert event out to all configured channels (SendGrid,
# PagerDuty, journal). Each notifier runs independently; one failing
# does not stop the others.
#
# Usage:
#   notify.sh --event {trigger|resolve} \
#             --key <alert_key> \
#             --severity <critical|error|warning|info> \
#             --summary "<one-line summary>" \
#             --details '<json>'
#
# Receives encrypted credentials via $CREDENTIALS_DIRECTORY set by the
# service unit that invoked us. See ab-monitor.service.

set -uo pipefail

LIBDIR=/usr/local/libexec/ab-monitor
# shellcheck source=/dev/null
source /etc/default/ab-monitor

log() { printf '[ab-notify] %s\n' "$*" >&2; logger -t ab-notify -p daemon.info -- "$*" 2>/dev/null || true; }

EVENT=""
KEY=""
SEVERITY=""
SUMMARY=""
DETAILS="{}"

while (($#)); do
    case "$1" in
        --event)    EVENT="$2";    shift 2 ;;
        --key)      KEY="$2";      shift 2 ;;
        --severity) SEVERITY="$2"; shift 2 ;;
        --summary)  SUMMARY="$2";  shift 2 ;;
        --details)  DETAILS="$2";  shift 2 ;;
        *)          log "unknown arg: $1"; shift ;;
    esac
done

[[ -n "${EVENT}" && -n "${KEY}" && -n "${SEVERITY}" ]] || { log "missing required args"; exit 2; }

HOST="${AB_MONITOR_HOSTNAME:-$(hostname -s)}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUNBOOK_URL=""
if [[ -n "${AB_MONITOR_RUNBOOK_URL:-}" ]]; then
    RUNBOOK_URL="${AB_MONITOR_RUNBOOK_URL%#*}#${KEY}"
fi

# Export a canonical event envelope that every notifier reads.
# Using env vars so each notifier is a simple consumer.
export AB_EVENT="${EVENT}"
export AB_KEY="${KEY}"
export AB_SEVERITY="${SEVERITY}"
export AB_SUMMARY="${SUMMARY}"
export AB_DETAILS="${DETAILS}"
export AB_HOST="${HOST}"
export AB_TIMESTAMP="${TIMESTAMP}"
export AB_RUNBOOK_URL="${RUNBOOK_URL}"
export AB_DEDUP_KEY="${HOST}-${KEY}"

# Always log to journal first; that is our forensic record.
"${LIBDIR}/notifiers/journal.sh" || true

# Fan out based on configured channels and PD min-severity floor.
severity_rank() {
    case "$1" in
        critical) echo 4 ;;
        error)    echo 3 ;;
        warning)  echo 2 ;;
        info)     echo 1 ;;
        *)        echo 0 ;;
    esac
}
cur_rank="$(severity_rank "${SEVERITY}")"
min_rank="$(severity_rank "${AB_MONITOR_PD_MIN_SEVERITY:-error}")"

for channel in ${AB_MONITOR_CHANNELS:-sendgrid pagerduty}; do
    case "${channel}" in
        sendgrid)
            "${LIBDIR}/notifiers/sendgrid.sh" || log "sendgrid notifier failed"
            ;;
        pagerduty)
            if (( cur_rank >= min_rank )); then
                "${LIBDIR}/notifiers/pagerduty.sh" || log "pagerduty notifier failed"
            else
                log "skip pagerduty: severity=${SEVERITY} below floor=${AB_MONITOR_PD_MIN_SEVERITY}"
            fi
            ;;
        journal)
            : # already ran
            ;;
        *)
            log "unknown channel: ${channel}"
            ;;
    esac
done

exit 0
