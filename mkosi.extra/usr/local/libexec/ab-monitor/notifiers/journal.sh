#!/bin/bash
# /usr/local/libexec/ab-monitor/notifiers/journal.sh
#
# Always-on forensic record. Emits a structured message to the
# journal with MESSAGE_ID and fields that make filtering easy:
#
#   journalctl AB_MONITOR_EVENT=trigger
#   journalctl AB_MONITOR_KEY=tailscale_down --since -7d
#
# We emit via systemd-cat so the fields land as journald structured
# metadata rather than embedded in the message text.

set -uo pipefail

if command -v systemd-cat >/dev/null 2>&1; then
    {
        printf 'MESSAGE=%s\n'              "ab-monitor ${AB_EVENT}: ${AB_KEY} - ${AB_SUMMARY}"
        printf 'PRIORITY=%s\n'             "$(case "${AB_SEVERITY}" in critical) echo 2;; error) echo 3;; warning) echo 4;; *) echo 5;; esac)"
        printf 'AB_MONITOR_EVENT=%s\n'     "${AB_EVENT}"
        printf 'AB_MONITOR_KEY=%s\n'       "${AB_KEY}"
        printf 'AB_MONITOR_SEVERITY=%s\n'  "${AB_SEVERITY}"
        printf 'AB_MONITOR_HOST=%s\n'      "${AB_HOST}"
        printf 'AB_MONITOR_TIMESTAMP=%s\n' "${AB_TIMESTAMP}"
        printf 'AB_MONITOR_DETAILS=%s\n'   "${AB_DETAILS}"
    } | logger --journald || true
else
    logger -t ab-monitor -p daemon.warning -- "${AB_EVENT} ${AB_KEY}: ${AB_SUMMARY}"
fi

exit 0
