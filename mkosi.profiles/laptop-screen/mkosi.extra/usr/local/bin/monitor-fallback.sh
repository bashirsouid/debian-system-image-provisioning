#!/usr/bin/env bash
set -euo pipefail

# Detect the user owning the active X session.
# This function tries several strategies and falls back to the first regular user.

detect_x_user() {
    local user
    # Strategy 1: Use loginctl to find a session attached to DISPLAY=:0
    if command -v loginctl >/dev/null 2>&1; then
        # List sessions and inspect their Display property (if any)
        while read -r sid _uid _rest; do
            # Show session details; filter on Display property
            local display
            display=$(loginctl show-session "$sid" -p Display --value 2>/dev/null || true)
            if [[ "$display" == ":0" ]]; then
                user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null || true)
                [[ -n "$user" ]] && { echo "$user"; return; }
            fi
        done < <(loginctl list-sessions --no-legend | awk '{print $1, $3}')
    fi

    # Strategy 2: Parse the output of `who` for a line containing :0
    user=$(who | awk '/\(:[0-9]+\)/ {print $1; exit}')
    [[ -n "$user" ]] && { echo "$user"; return; }

    # Strategy 3: Use logname (works in many contexts)
    user=$(logname 2>/dev/null || true)
    [[ -n "$user" ]] && { echo "$user"; return; }

    # Strategy 4: Fallback to the first regular UID >=1000 (typical login user)
    user=$(awk -F: '($3>=1000 && $3<65534){print $1; exit}' /etc/passwd)
    [[ -n "$user" ]] && { echo "$user"; return; }

    # No user detected – exit silently.
    exit 0
}

X_USER=$(detect_x_user)
[[ -n "$X_USER" ]] || exit 0

# Export X11 environment variables for the detected user.
export DISPLAY=:0
export XAUTHORITY="/home/${X_USER}/.Xauthority"

# Internal laptop panel – commonly eDP-1. Adjust if your hardware uses a different name.
INTERNAL_OUTPUT="eDP-1"

# Verify the internal output exists and is connected.
if xrandr --listmonitors | grep -q "${INTERNAL_OUTPUT}"; then
    # If no external outputs are connected, re‑enable the internal panel.
    if ! xrandr --query | grep -E "^(HDMI|DP|VGA|DVI|USB[-]?C|DisplayPort)-?[A-Za-z0-9-]*[[:space:]]+connected" >/dev/null; then
        xrandr --output "${INTERNAL_OUTPUT}" --auto --primary || true
    fi
fi
