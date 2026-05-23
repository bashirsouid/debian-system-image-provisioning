#!/bin/sh
# Determine the primary connected output and set 1900x1200 resolution
OUTPUT=$(xrandr --listactivemonitors | awk 'NR==2 {print $4}')
if [ -n "$OUTPUT" ]; then
  xrandr --output "$OUTPUT" --mode 1920x1200 || true
fi
