#!/usr/bin/env bash
set -euo pipefail

DEEP=false
ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep)
      DEEP=true
      shift
      ;;
    --all)
      ALL=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "==> Cleaning build artifacts..."

if $ALL; then
  echo "==> Thorough cleanup (--all)..."
  mkosi clean -ff
  rm -rf mkosi.cache mkosi.builddir mkosi.output .mkosi-secrets .config-checksum image image.*
elif $DEEP; then
  echo "==> Deep cleanup (--deep)..."
  mkosi clean -f
else
  mkosi clean
fi

echo "==> Cleanup complete!"
