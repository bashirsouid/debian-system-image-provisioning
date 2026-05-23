#!/bin/sh
# Set the default monitor resolution to 1920x1200 on first X start.
# The script is safe to run multiple times; it simply applies the mode if the output exists.
OUTPUT=$(xrandr --listactivemonitors | awk 'NR==2 {print $4}')
if [ -n "$OUTPUT" ]; then
  xrandr --output "$OUTPUT" --mode 1920x1200 || true
fi
