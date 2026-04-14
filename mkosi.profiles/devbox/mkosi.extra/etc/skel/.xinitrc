#!/bin/sh
set -eu

if command -v xrandr >/dev/null 2>&1; then
    output="$(xrandr --query | awk '/ connected/{print $1; exit}')"
    if [ -n "$output" ]; then
        target_mode="${STARTX_RESOLUTION:-1280x720}"
        xrandr --output "$output" --mode "$target_mode" >/dev/null 2>&1 || \
        xrandr --output "$output" --auto >/dev/null 2>&1 || true
    fi
fi

if command -v spice-vdagent >/dev/null 2>&1; then
    spice-vdagent >/dev/null 2>&1 &
fi

exec dbus-run-session awesome
