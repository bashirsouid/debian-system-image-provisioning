#!/usr/bin/env bash
set -euo pipefail

DEEP=false
ALL=false

usage() {
  cat <<'USAGE'
Usage: ./clean.sh [--deep | --all]

  --deep   remove incremental build artifacts
  --all    remove incremental artifacts, package cache, and generated files
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep|-d|deep)
      DEEP=true
      shift
      ;;
    --all|-a|all)
      ALL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "Unexpected positional arguments: $*" >&2
  usage >&2
  exit 1
fi

echo "==> Cleaning build artifacts..."

if $ALL; then
  echo "==> Thorough cleanup (--all)..."
  mkosi clean -f -f
  rm -rf mkosi.cache mkosi.builddir mkosi.output .mkosi-secrets .mkosi-thirdparty .config-checksum image image.*
elif $DEEP; then
  echo "==> Deep cleanup (--deep)..."
  mkosi clean -f
else
  mkosi clean
fi

echo "==> Cleanup complete!"
