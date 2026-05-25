#!/bin/bash
# System-level Fn+F8 screen reactivation script
# Works at login screen (GDM) and in user sessions

sleep 0.5  # Brief pause for possible hotplug race

# Loop through all running Xorg processes to support login screens and user sessions
for PID in $(pgrep -f "Xorg"); do
    # Extract the X11 display (e.g., :0)
    DISPLAY_NUM=$(ps -p "$PID" -o args= | grep -oP ':[0-9]+' | head -n 1)
    # Extract the XAUTHORITY file path used by the session
    XAUTH_PATH=$(ps -p "$PID" -o args= | grep -oP -- '-auth \K[^ ]+')
    if [ -n "$DISPLAY_NUM" ] && [ -n "$XAUTH_PATH" ]; then
        export DISPLAY="$DISPLAY_NUM"
        export XAUTHORITY="$XAUTH_PATH"
        # Identify the built-in display (eDP*)
        INTERNAL_DISPLAY=$(xrandr | grep -E "^(eDP-?[0-9]+) connected" | awk '{print $1}')
        if [ -n "$INTERNAL_DISPLAY" ]; then
            xrandr --output "$INTERNAL_DISPLAY" --auto --primary
        else
            xrandr --auto
        fi
    fi
done
