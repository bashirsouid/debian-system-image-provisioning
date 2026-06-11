#!/usr/bin/env bash
# Report disk usage to help diagnose image size issues

# Run as the LAST finalize step (99- prefix) before mkosi generates the disk image
# This gives us visibility into what's consuming space in the final rootfs

ROOT="${BUILDROOT:?BUILDROOT is required}"

echo "==> [FINALIZE] Disk usage report (before image generation):"
echo "    Top-level directories:"
du -sh "$ROOT"/* 2>/dev/null | sort -h | tail -15

echo ""
echo "    Largest directories (>100M):"
find "$ROOT" -mindepth 2 -maxdepth 3 -type d -exec du -sh {} \; 2>/dev/null | sort -h | tail -20 | grep -E 'G|[1-9][0-9]{2}M'

echo ""
echo "    Total rootfs size:"
du -sh "$ROOT" 2>/dev/null
