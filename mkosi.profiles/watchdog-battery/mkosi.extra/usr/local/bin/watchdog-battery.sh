#!/usr/bin/env bash
# watchdog-battery.sh – suspend when battery capacity ≤ 5 %.
# This script is run as root via a systemd service.
# It checks all power‑supply devices of type "Battery" and suspends
# if any reports a capacity of 5 % or lower.

set -euo pipefail

# Iterate over battery devices under /sys/class/power_supply.
for bat in /sys/class/power_supply/*; do
    if [[ -f "$bat/type" ]] && grep -qi battery "$bat/type"; then
        cap_file="$bat/capacity"
        if [[ -r "$cap_file" ]]; then
            capacity=$(<"$cap_file")
            # Trim possible whitespace.
            capacity=$(printf "%s" "$capacity" | tr -d '[:space:]')
            if [[ -n "$capacity" ]] && (( capacity <= 5 )); then
                /usr/bin/systemctl suspend
            fi
        fi
        # Only act on the first battery device found.
        exit 0
    fi
done

# No battery device found – nothing to do.
exit 0
