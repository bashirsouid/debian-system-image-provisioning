#!/bin/bash
# /usr/local/libexec/ab-monitor/check.sh
#
# Main monitoring loop. Run from ab-monitor.timer every 5 minutes.
#
# Flow:
#   1. Source config and state helpers.
#   2. Skip if system has been up for less than AB_MONITOR_STARTUP_GRACE_SECS.
#   3. Iterate check modules (checks/*.sh + checks.d/*.sh), run each,
#      parse its JSON output.
#   4. For each check, call state_transition to figure out whether to
#      notify. If so, call notify.sh.
#   5. Exit 0 even if individual checks failed; a failing check is NOT
#      a failed monitor run.

set -uo pipefail

LIBDIR=/usr/local/libexec/ab-monitor
# shellcheck source=/dev/null
source /etc/default/ab-monitor
# shellcheck source=/dev/null
source "${LIBDIR}/state.sh"

log() { printf '[ab-monitor] %s\n' "$*" >&2; logger -t ab-monitor -p daemon.info -- "$*" 2>/dev/null || true; }

# Early exits --------------------------------------------------------------

uptime_secs="$(awk '{print int($1)}' /proc/uptime)"
if (( uptime_secs < AB_MONITOR_STARTUP_GRACE_SECS )); then
    log "in startup grace (uptime=${uptime_secs}s < ${AB_MONITOR_STARTUP_GRACE_SECS}s); skipping."
    exit 0
fi

state_init

# Identity ----------------------------------------------------------------
HOST="${AB_MONITOR_HOSTNAME:-$(hostname -s)}"
export AB_MONITOR_HOSTNAME="${HOST}"

# Collect ambient context once so every check can reference it without
# re-shelling. Checks consume this via env vars AB_CTX_*.
ab_ctx_ab_slot=""
ab_ctx_ab_version=""
if command -v ab-status >/dev/null 2>&1; then
    # ab-status is provided by the base repo. If its shape changes, update here.
    ab_ctx_ab_slot="$(ab-status 2>/dev/null | awk -F': *' '/^root partition/ {print $2; exit}')"
    ab_ctx_ab_version="$(ab-status 2>/dev/null | awk -F': *' '/^installed version/ {print $2; exit}')"
fi
export AB_CTX_SLOT="${ab_ctx_ab_slot}"
export AB_CTX_VERSION="${ab_ctx_ab_version}"

# Run checks --------------------------------------------------------------

run_one_check() {
    local script="$1"
    local name; name="$(basename "${script}" .sh)"
    name="${name#[0-9][0-9]-}"  # strip NN- prefix

    local output rc
    output="$("${script}" 2>/dev/null)"
    rc=$?

    if (( rc != 0 )); then
        log "check ${name} exited ${rc}; treating as fail"
        output="$(jq -n --arg k "${name}" --arg s "check script exited ${rc}" \
            '{key:$k, status:"fail", severity:"error", summary:$s, details:{}}')"
    fi

    # Validate JSON output
    if ! jq -e . >/dev/null 2>&1 <<<"${output}"; then
        log "check ${name} produced invalid JSON; skipping"
        return 0
    fi

    local key status severity summary details
    key="$(jq -r '.key // empty' <<<"${output}")"
    status="$(jq -r '.status // "unknown"' <<<"${output}")"
    severity="$(jq -r '.severity // "error"' <<<"${output}")"
    summary="$(jq -r '.summary // ""' <<<"${output}")"
    details="$(jq -c '.details // {}' <<<"${output}")"

    [[ -n "${key}" ]] || { log "check ${name} did not emit a key"; return 0; }

    local action
    action="$(state_transition "${key}" "${status}" "${severity}" "${summary}" "${details}")"

    case "${action}" in
        notify_trigger)
            log "TRIGGER alert: ${key} (${severity}) ${summary}"
            "${LIBDIR}/notify.sh" \
                --event trigger \
                --key "${key}" \
                --severity "${severity}" \
                --summary "${summary}" \
                --details "${details}" \
                || log "notify.sh failed for ${key} trigger"
            ;;
        notify_resolve)
            log "RESOLVE alert: ${key}"
            "${LIBDIR}/notify.sh" \
                --event resolve \
                --key "${key}" \
                --severity "${severity}" \
                --summary "${summary}" \
                --details "${details}" \
                || log "notify.sh failed for ${key} resolve"
            ;;
        notify_skip)
            : # no-op, but log at debug level
            ;;
    esac
}

declare -a checks=()
if [[ -d "${AB_MONITOR_CHECKS_DIR}" ]]; then
    while IFS= read -r f; do checks+=("$f"); done < <(find "${AB_MONITOR_CHECKS_DIR}" -maxdepth 1 -type f -executable | sort)
fi
if [[ -d "${AB_MONITOR_EXTRA_CHECKS_DIR}" ]]; then
    while IFS= read -r f; do checks+=("$f"); done < <(find "${AB_MONITOR_EXTRA_CHECKS_DIR}" -maxdepth 1 -type f -executable | sort)
fi

if (( ${#checks[@]} == 0 )); then
    log "no checks found in ${AB_MONITOR_CHECKS_DIR}; nothing to do."
    exit 0
fi

log "running ${#checks[@]} checks"
for c in "${checks[@]}"; do
    run_one_check "$c"
done

exit 0
