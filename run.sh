#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="devbox"
HOST=""
RUNTIME_HOME=false
EPHEMERAL=true
QEMU_HOME_SEED=true
RUNTIME_TREES=()

usage() {
  cat <<'USAGE'
Usage: ./run.sh [options]

Options:
  --profile NAME          boot profile (default: devbox)
  --host NAME             include runtime config from hosts/NAME/mkosi.conf.d/
  --runtime-home          ask mkosi to mount the invoking host home at /root
                          inside the VM for disposable compatibility testing
  --runtime-tree SPEC     mount a host directory into the VM using mkosi's
                          RuntimeTrees= support; SPEC is hostpath[:guestpath]
  --ephemeral             boot from a temporary snapshot of the image
                          (default)
  --persistent            boot the image with persistent writes
  --no-qemu-home-seed     do not mount the repo sample home seed into the VM

Examples:
  ./run.sh --profile devbox
  ./run.sh --runtime-home
  ./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"

Notes:
  - run.sh defaults to an ephemeral VM so QEMU smoke tests do not mutate
    the built image you may later flash.
  - For testing host data, prefer mkosi's native runtime mount features over
    raw QEMU arguments so we stay on the supported path.
  - RuntimeHome mounts the current host home at /root in the guest on current
    Debian-trixie mkosi.
  - For full-home sharing, use disposable runs (--ephemeral) and keep in mind
    that the guest will be touching live host data.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing profile name}"
      shift 2
      ;;
    --host)
      HOST="${2:?missing host name}"
      shift 2
      ;;
    --runtime-home)
      RUNTIME_HOME=true
      shift
      ;;
    --runtime-tree)
      RUNTIME_TREES+=("${2:?missing runtime tree spec}")
      shift 2
      ;;
    --ephemeral)
      EPHEMERAL=true
      shift
      ;;
    --persistent)
      EPHEMERAL=false
      shift
      ;;
    --no-qemu-home-seed)
      QEMU_HOME_SEED=false
      shift
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

args=("--profile=$PROFILE")


if [[ "$QEMU_HOME_SEED" == true && "$PROFILE" == "devbox" ]]; then
  SAMPLE_HOME_SEED="$PROJECT_ROOT/runtime-seeds/qemu-home"
  if [[ -d "$SAMPLE_HOME_SEED" ]]; then
    RUNTIME_TREES+=("$SAMPLE_HOME_SEED:/run/qemu-home-seed")
  fi
fi

if [[ -n "$HOST" ]]; then
  HOST_DIR="hosts/$HOST"
  if [[ ! -d "$HOST_DIR" ]]; then
    echo "ERROR: host directory $HOST_DIR not found" >&2
    exit 1
  fi
  [[ -d "$HOST_DIR/mkosi.conf.d" ]] && args+=("--include=$HOST_DIR/mkosi.conf.d")
fi

$RUNTIME_HOME && args+=("--runtime-home=yes")
$EPHEMERAL && args+=("--ephemeral=yes")

for spec in "${RUNTIME_TREES[@]}"; do
  args+=("--runtime-tree=$spec")
done

echo "==> Booting the image in QEMU GUI (profile: $PROFILE)..."
if [[ "$RUNTIME_HOME" == true ]]; then
  echo "==> mkosi RuntimeHome enabled for this VM run"
fi
if [[ "$EPHEMERAL" == true ]]; then
  echo "==> Ephemeral VM snapshot enabled"
fi
if [[ "$QEMU_HOME_SEED" == true && "$PROFILE" == "devbox" ]]; then
  echo "==> QEMU sample home seed enabled"
fi
for spec in "${RUNTIME_TREES[@]}"; do
  echo "==> Runtime tree: $spec"
done

exec mkosi "${args[@]}" vm
