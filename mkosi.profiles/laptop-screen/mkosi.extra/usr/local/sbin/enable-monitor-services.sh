#!/usr/bin/env bash
set -euo pipefail

# Enable the fallback monitor timer and reload udev rules.
# Also ensure triggerhappy service is active (for Fn+F8 keybind).

# Enable timer
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now monitor-fallback.timer || true
    # Enable triggerhappy if installed
    if systemctl list-unit-files | grep -q '^triggerhappy.service'; then
        systemctl enable --now triggerhappy.service || true
    fi
fi

# Reload udev rules (in case new rule was added after udev has started)
udeadm control --reload || true
