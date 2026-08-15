#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$SRCDIR/scripts/finalize-lib.sh"

if chroot "$ROOT" command -v fc-cache >/dev/null 2>&1; then
  echo "==> [FINALIZE] updating font cache (fc-cache -s -f)"
  chroot "$ROOT" fc-cache -s -f || true
fi
