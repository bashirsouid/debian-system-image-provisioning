#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin

LOCKFILE=/run/lock/monitor-recovery.lock
LOGTAG=monitor-recovery
RETRIES=10
SLEEP_BETWEEN=2

log() {
    logger -t "$LOGTAG" -- "$*"
}

session_prop() {
    loginctl show-session "$1" -p "$2" --value 2>/dev/null || true
}

list_x11_sessions() {
    local sid type remote user leader active display
    while read -r sid; do
        [[ -n "$sid" ]] || continue
        type=$(session_prop "$sid" Type)
        remote=$(session_prop "$sid" Remote)
        user=$(session_prop "$sid" Name)
        leader=$(session_prop "$sid" Leader)
        active=$(session_prop "$sid" Active)
        display=$(session_prop "$sid" Display)

        [[ "$type" == "x11" ]] || continue
        [[ "$remote" == "no" ]] || continue
        [[ -n "$user" ]] || continue
        [[ "$leader" =~ ^[0-9]+$ ]] || continue

        printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$user" "$leader" "$active" "$display"
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
}

pick_x11_session() {
    local fallback="" sid user leader active display
    while IFS=$'\t' read -r sid user leader active display; do
        [[ -n "$sid" ]] || continue
        if [[ "$active" == "yes" ]]; then
            printf '%s\t%s\t%s\t%s\n' "$sid" "$user" "$leader" "$display"
            return 0
        fi
        if [[ -z "$fallback" ]]; then
            fallback=$(printf '%s\t%s\t%s\t%s' "$sid" "$user" "$leader" "$display")
        fi
    done < <(list_x11_sessions)

    [[ -n "$fallback" ]] || return 1
    printf '%b\n' "$fallback"
}

pid_env() {
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null || true
}

env_get() {
    local env_blob="$1" key="$2"
    sed -n "s/^${key}=//p" <<<"$env_blob" | head -n1
}

find_x_env() {
    local user="$1" leader="$2" display_hint="${3:-}" uid pid env_blob

    DISPLAY_VAL=""
    XAUTHORITY_VAL=""

    uid=$(id -u "$user")
    XDG_RUNTIME_DIR_VAL="/run/user/$uid"
    DBUS_SESSION_BUS_ADDRESS_VAL="unix:path=${XDG_RUNTIME_DIR_VAL}/bus"

    env_blob=$(pid_env "$leader")
    if [[ -n "$env_blob" ]]; then
        DISPLAY_VAL=$(env_get "$env_blob" DISPLAY)
        XAUTHORITY_VAL=$(env_get "$env_blob" XAUTHORITY)
        XDG_RUNTIME_DIR_VAL=$(env_get "$env_blob" XDG_RUNTIME_DIR || true)
        DBUS_SESSION_BUS_ADDRESS_VAL=$(env_get "$env_blob" DBUS_SESSION_BUS_ADDRESS || true)
    fi

    [[ -n "$DISPLAY_VAL" ]] || DISPLAY_VAL="$display_hint"
    [[ -n "$XDG_RUNTIME_DIR_VAL" ]] || XDG_RUNTIME_DIR_VAL="/run/user/$uid"
    [[ -n "$DBUS_SESSION_BUS_ADDRESS_VAL" ]] || DBUS_SESSION_BUS_ADDRESS_VAL="unix:path=${XDG_RUNTIME_DIR_VAL}/bus"

    if [[ -z "$DISPLAY_VAL" || -z "$XAUTHORITY_VAL" ]]; then
        while read -r pid; do
            [[ -r "/proc/$pid/environ" ]] || continue
            env_blob=$(pid_env "$pid")

            [[ -n "$DISPLAY_VAL" ]] || DISPLAY_VAL=$(env_get "$env_blob" DISPLAY)

            if [[ -z "$XAUTHORITY_VAL" ]]; then
                XAUTHORITY_VAL=$(env_get "$env_blob" XAUTHORITY)
            fi
            if [[ -z "$DBUS_SESSION_BUS_ADDRESS_VAL" ]]; then
                DBUS_SESSION_BUS_ADDRESS_VAL=$(env_get "$env_blob" DBUS_SESSION_BUS_ADDRESS)
            fi
            if [[ -z "$XDG_RUNTIME_DIR_VAL" ]]; then
                XDG_RUNTIME_DIR_VAL=$(env_get "$env_blob" XDG_RUNTIME_DIR)
            fi

            [[ -n "$DISPLAY_VAL" && -n "$XAUTHORITY_VAL" ]] && break
        done < <(pgrep -u "$user" 2>/dev/null || true)
    fi

    if [[ -z "$XAUTHORITY_VAL" && -e "/home/$user/.Xauthority" ]]; then
        XAUTHORITY_VAL="/home/$user/.Xauthority"
    fi

    [[ "$DISPLAY_VAL" == :* ]] || return 1
    [[ -n "$XAUTHORITY_VAL" && -e "$XAUTHORITY_VAL" ]] || return 1

    return 0
}

run_xrandr() {
    runuser -u "$X_USER" -- env \
        DISPLAY="$DISPLAY_VAL" \
        XAUTHORITY="$XAUTHORITY_VAL" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR_VAL" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS_VAL" \
        xrandr "$@"
}

query_outputs_connected() {
    awk '/ connected/ {print $1}' <<<"$1"
}

query_outputs_disconnected() {
    awk '$2=="disconnected" {print $1}' <<<"$1"
}

query_outputs_all() {
    awk '/ connected| disconnected/ {print $1}' <<<"$1"
}

query_outputs_active_fallback() {
    awk '/ connected/ && /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/ {print $1}' <<<"$1"
}

list_active_outputs() {
    local active
    active=$(run_xrandr --listactivemonitors 2>/dev/null || true)
    if [[ -n "$active" && "$active" != "Monitors: 0" ]]; then
        awk 'NR > 1 && NF {print $NF}' <<<"$active"
    else
        query_outputs_active_fallback "$1"
    fi
}

internal_outputs_from_list() {
    grep -E '^(eDP|LVDS)(-[0-9]+)?$' || true
}

external_outputs_from_list() {
    grep -Ev '^(eDP|LVDS)(-[0-9]+)?$' || true
}

first_internal_connected() {
    query_outputs_connected "$1" | internal_outputs_from_list | head -n1 || true
}

first_any_connected() {
    query_outputs_connected "$1" | head -n1 || true
}

build_cleanup_disconnected_cmds() {
    local query="$1" out
    while read -r out; do
        [[ -n "$out" ]] || continue
        printf '%s\0%s\0' --output "$out"
        printf '%s\0' --off
    done < <(query_outputs_disconnected "$query")
}

apply_recovery_layout() {
    local query="$1" target="$2" out
    local -a cmd=()

    while IFS= read -r -d '' token; do
        cmd+=("$token")
    done < <(build_cleanup_disconnected_cmds "$query")

    cmd+=(--output "$target" --auto --primary)

    while read -r out; do
        [[ -n "$out" && "$out" != "$target" ]] || continue
        cmd+=(--output "$out" --off)
    done < <(query_outputs_all "$query" | grep -Fxv "$target" || true)

    run_xrandr "${cmd[@]}"
}

main() {
    local session_info sid leader display_hint
    local query target internal external_any active_after i

    exec 9>"$LOCKFILE"
    flock -n 9 || exit 0

    session_info=$(pick_x11_session) || exit 0
    IFS=$'\t' read -r sid X_USER leader display_hint <<<"$session_info"

    find_x_env "$X_USER" "$leader" "$display_hint" || {
        log "No usable X11 environment found for user $X_USER"
        exit 0
    }

    for ((i=1; i<=RETRIES; i++)); do
        query=$(run_xrandr --query 2>/dev/null || true)
        [[ -n "$query" ]] || { sleep "$SLEEP_BETWEEN"; continue; }

        external_any=$(query_outputs_connected "$query" | external_outputs_from_list || true)
        if [[ -n "$external_any" ]]; then
            log "External monitor still connected; no-op"
            exit 0
        fi

        internal=$(first_internal_connected "$query")
        target="$internal"

        if [[ -z "$target" ]]; then
            target=$(first_any_connected "$query")
        fi

        [[ -n "$target" ]] || { sleep "$SLEEP_BETWEEN"; continue; }

        if list_active_outputs "$query" | grep -Fxq "$target"; then
            exit 0
        fi

        if apply_recovery_layout "$query" "$target"; then
            sleep 1
        else
            sleep "$SLEEP_BETWEEN"
            continue
        fi

        query=$(run_xrandr --query 2>/dev/null || true)
        active_after=$(list_active_outputs "$query" || true)

        if grep -Fxq "$target" <<<"$active_after"; then
            log "Recovered display using output $target for user $X_USER on $DISPLAY_VAL"
            exit 0
        fi

        sleep "$SLEEP_BETWEEN"
    done

    log "Failed to recover a working monitor after $RETRIES attempts"
    exit 1
}

main "$@"