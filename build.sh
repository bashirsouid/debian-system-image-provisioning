#!/usr/bin/env bash
set -euo pipefail

# build.sh — Smart mkosi build wrapper
#
# Usage: ./build.sh [--profile <role>] [--host <name>] [--force] [--clean]
# Roles: devbox (default), server

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$PROJECT_ROOT/.mkosi-secrets"
USERS_FILE="$PROJECT_ROOT/.users.json"
USERS_SAMPLE="$PROJECT_ROOT/.users.json.sample"

PROFILE="devbox"
HOST=""
FORCE_FLAG=""
MKOSI_FORCE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --host)
      HOST="$2"
      shift 2
      ;;
    --force)
      MKOSI_FORCE="-f"
      shift
      ;;
    --clean)
      MKOSI_FORCE="-ff"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

cd "$PROJECT_ROOT"

# 1. Ensure .users.json exists
if [[ ! -f "$USERS_FILE" ]]; then
  echo "WARNING: $USERS_FILE missing. Creating from sample..."
  cp "$USERS_SAMPLE" "$USERS_FILE"
  echo "IMPORTANT: Please edit $USERS_FILE and set your passwords before building!"
  exit 1
fi

# 2. Prepare secrets tree
echo "==> Preparing secrets..."
rm -rf "$SECRETS_DIR"
install -d -m 0755 "$SECRETS_DIR/usr/local/etc"
cp "$USERS_FILE" "$SECRETS_DIR/usr/local/etc/users.json"
chmod 0600 "$SECRETS_DIR/usr/local/etc/users.json"

# 3. Handle host-specific overrides
EXTRA_ARGS=()
if [[ -n "$HOST" ]]; then
  HOST_DIR="hosts/$HOST"
  if [[ ! -d "$HOST_DIR" ]]; then
    echo "ERROR: Host directory $HOST_DIR not found."
    exit 1
  fi
  echo "==> Including host-specific config for: $HOST"
  # Include host-specific conf.d
  if [[ -d "$HOST_DIR/mkosi.conf.d" ]]; then
    EXTRA_ARGS+=("--include=$HOST_DIR/mkosi.conf.d")
  fi
  # Include host-specific extra tree
  if [[ -d "$HOST_DIR/mkosi.extra" ]]; then
    EXTRA_ARGS+=("--extra-tree=$HOST_DIR/mkosi.extra:/")
  fi
fi

# 4. Smart Staleness Check (Config Checksum)
# We checksum all relevant parts to decide if we need to force a rebuild.
CHECKSUM_FILE=".config-checksum"
CURRENT_CHECKSUM=$(find mkosi.conf mkosi.conf.d mkosi.profiles mkosi.build mkosi.finalize mkosi.extra hosts .users.json -type f -print0 | xargs -0 sha256sum | sha256sum | awk '{print $1}')

if [[ -f "$CHECKSUM_FILE" ]]; then
  OLD_CHECKSUM=$(cat "$CHECKSUM_FILE")
  if [[ "$CURRENT_CHECKSUM" != "$OLD_CHECKSUM" && -z "$MKOSI_FORCE" ]]; then
    echo "==> Configuration changed. Automatically setting --force..."
    MKOSI_FORCE="-f"
  fi
fi

# 5. Ensure third-party deps are present
if [[ "$PROFILE" == "devbox" ]]; then
  if [[ ! -d "third-party/awesome/.git" ]]; then
    echo "==> AwesomeWM source missing. Running update-3rd-party-deps.sh..."
    ./update-3rd-party-deps.sh
  fi
fi

# 6. Run mkosi build
echo "==> Starting mkosi build (profile: $PROFILE, force: ${MKOSI_FORCE:-none})..."
mkosi --profile="$PROFILE" ${MKOSI_FORCE} "${EXTRA_ARGS[@]}" build

echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
echo "==> Build complete!"
