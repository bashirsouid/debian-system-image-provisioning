#!/bin/bash
# /usr/local/libexec/ab-monitor/heartbeat.sh
#
# Dead-man's switch. Pings Healthchecks.io every few minutes. If the
# ping stops arriving, Healthchecks.io alerts you. This is the path
# that catches failures the local monitor cannot report (power loss,
# kernel panic, network totally dead).
#
# The ping URL is loaded as an encrypted systemd credential and looks
# like: https://hc-ping.com/<uuid>
#
# We ping the BASE url on success. On a detected local problem we
# ping /fail to deliberately trigger an alert right away rather than
# waiting for the grace period to expire.

set -uo pipefail

# shellcheck source=/dev/null
source /etc/default/ab-monitor

log() { printf '[ab-heartbeat] %s\n' "$*" >&2; }

: "${CREDENTIALS_DIRECTORY:?not set}"

if [[ ! -r "${CREDENTIALS_DIRECTORY}/healthchecks-ping-url" ]]; then
    log "no healthchecks-ping-url credential; heartbeat disabled."
    exit 0
fi

BASE_URL="$(cat "${CREDENTIALS_DIRECTORY}/healthchecks-ping-url")"
BASE_URL="${BASE_URL%$'\n'}"

# Quick local sanity: if critical services are all down we prefer to
# send /fail so Healthchecks.io escalates immediately.
fail_reason=""

if systemctl list-units --failed --no-legend 2>/dev/null | grep -q .; then
    fail_reason="failed systemd units present"
fi

if command -v tailscale >/dev/null && [[ -f /etc/credstore.encrypted/tailscale-authkey ]]; then
    if ! tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null; then
        fail_reason="${fail_reason:+${fail_reason}; }tailscale not Running"
    fi
fi

if systemctl list-unit-files cloudflared.service >/dev/null 2>&1 && [[ -f /etc/credstore.encrypted/cloudflared-token ]]; then
    if ! systemctl is-active --quiet cloudflared.service; then
        fail_reason="${fail_reason:+${fail_reason}; }cloudflared inactive"
    fi
fi

url="${BASE_URL}"
body_type="text/plain"
body_data="ok host=$(hostname -s) uptime=$(awk '{print int($1)}' /proc/uptime)s"

if [[ -n "${fail_reason}" ]]; then
    url="${BASE_URL}/fail"
    body_data="fail host=$(hostname -s) reasons: ${fail_reason}"
fi

# Healthchecks.io accepts optional body, useful for post-mortem.
if curl --silent --show-error --max-time "${AB_MONITOR_HTTP_TIMEOUT:-10}" \
        -H "Content-Type: ${body_type}" \
        --retry 3 --retry-delay 5 --retry-connrefused \
        --data-raw "${body_data}" \
        --output /dev/null \
        "${url}"; then
    log "ping ok -> ${url##*/}"
else
    log "ping FAILED to ${url}; healthchecks.io will alert once grace expires."
fi

unset BASE_URL
exit 0
