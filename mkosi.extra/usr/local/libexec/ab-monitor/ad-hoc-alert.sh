#!/bin/bash
# /usr/local/libexec/ab-monitor/ad-hoc-alert.sh
#
# Fires a one-shot alert through the normal notify.sh path. Meant to
# be invoked from systemd OnFailure= via [email protected]
# or from the ab-monitor-test CLI.
#
# Usage:
#   ad-hoc-alert.sh <key> <severity> <summary> [<details_json>]

set -uo pipefail

LIBDIR=/usr/local/libexec/ab-monitor
# shellcheck source=/dev/null
source /etc/default/ab-monitor
# shellcheck source=/dev/null
source "${LIBDIR}/state.sh"

KEY="${1:-}"
SEVERITY="${2:-error}"
SUMMARY="${3:-}"
DETAILS="${4:-{\}}"

if [[ -z "${KEY}" || -z "${SUMMARY}" ]]; then
    echo "usage: ad-hoc-alert.sh <key> <severity> <summary> [<details_json>]" >&2
    exit 2
fi

state_init
# Go through state so we dedup correctly against the periodic monitor.
action="$(state_transition "${KEY}" "fail" "${SEVERITY}" "${SUMMARY}" "${DETAILS}")"
if [[ "${action}" == "notify_skip" ]]; then
    # If we are skipping because of dedup, still emit a journal line
    # so a human inspecting the log can see the OnFailure= fired.
    logger -t ab-monitor -p daemon.info -- "ad-hoc alert suppressed by dedup: ${KEY} / ${SUMMARY}"
    exit 0
fi

exec "${LIBDIR}/notify.sh" \
    --event trigger \
    --key "${KEY}" \
    --severity "${SEVERITY}" \
    --summary "${SUMMARY}" \
    --details "${DETAILS}"
