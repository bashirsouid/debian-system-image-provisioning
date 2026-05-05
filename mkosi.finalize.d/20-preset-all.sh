#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$SRCDIR/scripts/finalize-lib.sh"

echo "==> [FINALIZE] running systemctl preset-all"
systemctl --root="${BUILDROOT}" preset-all
