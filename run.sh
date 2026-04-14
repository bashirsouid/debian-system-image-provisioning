#!/usr/bin/env bash
set -euo pipefail

PROFILE="devbox"

usage() {
  cat <<'USAGE'
Usage: ./run.sh [--profile NAME]

Boot the already-built image with mkosi's normal VM settings.
This deliberately does not append raw QEMU arguments because mkosi's CLI
syntax changed across releases, while plain `mkosi vm` already works here.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing profile name}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "==> Booting the image in QEMU GUI (profile: $PROFILE)..."
exec mkosi --profile="$PROFILE" vm
