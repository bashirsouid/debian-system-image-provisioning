#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
SOURCE_DIR="$PROJECT_ROOT/mkosi.output"
DEFINITIONS_DIR="/usr/lib/sysupdate.d"
REBOOT_AFTER=false

usage() {
  cat <<'USAGE'
Usage: sudo ./bin/sysupdate-local-update.sh [options]

Apply the native systemd-sysupdate flow to the currently installed system.
This expects the machine to have already been bootstrapped onto the new
systemd-repart + systemd-sysupdate layout.

Options:
  --source-dir DIR    directory containing versioned sysupdate artifacts
                      (default: ./mkosi.output)
  --definitions DIR   sysupdate transfer definitions (default: /usr/lib/sysupdate.d)
  --reboot            reboot after the update is staged
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      SOURCE_DIR="${2:?missing source dir}"
      shift 2
      ;;
    --definitions)
      DEFINITIONS_DIR="${2:?missing definitions dir}"
      shift 2
      ;;
    --reboot)
      REBOOT_AFTER=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "sysupdate-local-update.sh must run as root"
if ! ab_hostdeps_have_all_commands systemd-sysupdate; then
  ab_hostdeps_ensure_packages "sysupdate prerequisites" systemd-container || exit 1
fi
ab_hostdeps_ensure_commands "sysupdate prerequisites" systemd-sysupdate || exit 1

[[ -d "$SOURCE_DIR" ]] || die "source directory not found: $SOURCE_DIR"
[[ -d "$DEFINITIONS_DIR" ]] || die "definitions directory not found: $DEFINITIONS_DIR"

need_cmd systemd-sysupdate

echo "==> Staging update from $SOURCE_DIR"
systemd-sysupdate \
  --definitions="$DEFINITIONS_DIR" \
  --transfer-source="$SOURCE_DIR" \
  update

echo "==> Update staged"

if [[ "$REBOOT_AFTER" == true ]]; then
  echo "==> Rebooting into the new trial version"
  systemctl reboot
fi
