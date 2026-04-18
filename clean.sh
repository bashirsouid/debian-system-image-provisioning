#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"

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

if ! ab_hostdeps_have_all_commands mkosi; then
  ab_hostdeps_ensure_packages "cleanup prerequisites" mkosi || exit 1
fi
ab_hostdeps_ensure_commands "cleanup prerequisites" mkosi || exit 1

echo "==> Cleaning build artifacts..."

if $ALL; then
  echo "==> Thorough cleanup (--all)..."
  mkosi -f -f clean
  rm -rf mkosi.cache mkosi.builddir mkosi.output .mkosi-secrets .mkosi-thirdparty .config-checksum image image.*
  rm -rf -- mkosi.extra/etc/credstore.encrypted
  rm -f  -- mkosi.extra/var/lib/systemd/credential.secret
  rm -rf -- mkosi.extra/etc/ssh/authorized_keys.d
  rm -f  -- mkosi.extra/etc/apt/keyrings/*.gpg
elif $DEEP; then
  echo "==> Deep cleanup (--deep)..."
  mkosi -f clean
else
  mkosi clean
fi

echo "==> Cleanup complete!"
