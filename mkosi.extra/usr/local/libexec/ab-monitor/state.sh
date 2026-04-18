#!/bin/bash
# /usr/local/libexec/ab-monitor/state.sh
#
# Stateful helpers for alert dedup. Sourced by check.sh.
#
# State file: $AB_MONITOR_STATE_DIR/state.json
# Shape:
#   {
#     "<alert_key>": {
#       "status":           "ok" | "fail",
#       "severity":         "critical" | "error" | "warning" | "info",
#       "first_detected":   <unix ts>,
#       "last_changed":     <unix ts>,
#       "last_notified":    <unix ts>,
#       "notified_count":   <int>,
#       "summary":          "...",
#       "details":          {...}
#     },
#     ...
#   }

# shellcheck shell=bash

state_path() { printf '%s/state.json' "${AB_MONITOR_STATE_DIR}"; }

state_init() {
    install -d -m 0700 "${AB_MONITOR_STATE_DIR}"
    local p; p="$(state_path)"
    if [[ ! -f "${p}" ]]; then
        printf '{}\n' >"${p}"
        chmod 0600 "${p}"
    fi
}

# state_get <key>
# Prints the JSON object for <key>, or 'null' if absent.
state_get() {
    local key="$1"
    jq --arg k "${key}" '.[$k] // null' "$(state_path)"
}

# state_set <key> <json_object>
# Atomically replaces the entry for <key>.
state_set() {
    local key="$1" obj="$2"
    local p; p="$(state_path)"
    local tmp; tmp="$(mktemp "${AB_MONITOR_STATE_DIR}/.state.XXXXXX")"
    jq --arg k "${key}" --argjson v "${obj}" '.[$k] = $v' "${p}" >"${tmp}"
    chmod 0600 "${tmp}"
    mv -f "${tmp}" "${p}"
}

# Transition state for an alert and decide whether to notify.
# Usage:
#   state_transition <key> <new_status> <severity> <summary> <details_json>
# Returns one of these strings on stdout (exactly one line):
#   notify_trigger   -> state went ok->fail or was already fail but
#                       enough time has passed to re-notify
#   notify_resolve   -> state went fail->ok
#   notify_skip      -> no notification needed (no change, or within
#                       dedup window)
state_transition() {
    local key="$1" new_status="$2" severity="$3" summary="$4" details="$5"
    local now; now="$(date +%s)"
    local prev; prev="$(state_get "${key}")"

    local prev_status prev_first prev_last_notified prev_count
    if [[ "${prev}" == "null" ]]; then
        prev_status="unknown"
        prev_first=0
        prev_last_notified=0
        prev_count=0
    else
        prev_status="$(jq -r '.status' <<<"${prev}")"
        prev_first="$(jq -r '.first_detected // 0' <<<"${prev}")"
        prev_last_notified="$(jq -r '.last_notified // 0' <<<"${prev}")"
        prev_count="$(jq -r '.notified_count // 0' <<<"${prev}")"
    fi

    local action="notify_skip"
    local first_detected="${prev_first}"
    local last_notified="${prev_last_notified}"
    local notified_count="${prev_count}"

    case "${prev_status}|${new_status}" in
        "ok|fail"|"unknown|fail")
            action="notify_trigger"
            first_detected="${now}"
            last_notified="${now}"
            notified_count=1
            ;;
        "fail|fail")
            local delta=$(( now - prev_last_notified ))
            if (( delta >= AB_MONITOR_REMIND_AFTER_SECS )); then
                action="notify_trigger"
                last_notified="${now}"
                notified_count=$((prev_count + 1))
            fi
            ;;
        "fail|ok")
            action="notify_resolve"
            last_notified="${now}"
            notified_count=$((prev_count + 1))
            ;;
        "ok|ok"|"unknown|ok")
            action="notify_skip"
            ;;
    esac

    local new_entry
    new_entry="$(jq -n \
        --arg st "${new_status}" \
        --arg sev "${severity}" \
        --arg summ "${summary}" \
        --argjson det "${details:-{\}}" \
        --argjson fd "${first_detected}" \
        --argjson lc "${now}" \
        --argjson ln "${last_notified}" \
        --argjson nc "${notified_count}" \
        '{status:$st, severity:$sev, summary:$summ, details:$det,
          first_detected:$fd, last_changed:$lc,
          last_notified:$ln, notified_count:$nc}')"

    state_set "${key}" "${new_entry}"
    printf '%s\n' "${action}"
}

# Dump full state as JSON (for debugging / status CLI)
state_dump() {
    cat "$(state_path)"
}
