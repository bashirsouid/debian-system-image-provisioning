#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$PROJECT_ROOT/.mkosi-secrets"
USERS_FILE="$PROJECT_ROOT/.users.json"
USERS_SAMPLE="$PROJECT_ROOT/.users.json.sample"
PROFILE="devbox"
HOST=""
MKOSI_FORCE=""

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
    --force)
      MKOSI_FORCE="-f"
      shift
      ;;
    --clean)
      MKOSI_FORCE="-ff"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

cd "$PROJECT_ROOT"
mkdir -p mkosi.output

if [[ ! -f "$USERS_FILE" ]]; then
  echo "WARNING: $USERS_FILE missing. Creating from sample..."
  cp "$USERS_SAMPLE" "$USERS_FILE"
  echo "IMPORTANT: edit $USERS_FILE and set your passwords before building."
  exit 1
fi

if ! command -v mkosi >/dev/null 2>&1; then
  echo "ERROR: mkosi is not installed or not on PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required on the build host" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: need openssl or python3 on the build host for password hashing" >&2
  exit 1
fi

if [[ "$PROFILE" == "devbox" && ! -f "$PROJECT_ROOT/third-party/awesome/CMakeLists.txt" ]]; then
  echo "ERROR: devbox profile requires third-party/awesome" >&2
  echo "Run ./update-3rd-party-deps.sh first." >&2
  exit 1
fi

echo "==> Preparing secrets..."
rm -rf "$SECRETS_DIR"
install -d -m 0755 "$SECRETS_DIR/usr/local/etc"
cp "$USERS_FILE" "$SECRETS_DIR/usr/local/etc/users.json"
chmod 0600 "$SECRETS_DIR/usr/local/etc/users.json"

EXTRA_ARGS=()
if [[ -n "$HOST" ]]; then
  HOST_DIR="hosts/$HOST"
  if [[ ! -d "$HOST_DIR" ]]; then
    echo "ERROR: host directory $HOST_DIR not found" >&2
    exit 1
  fi
  echo "==> Including host-specific config for: $HOST"
  [[ -d "$HOST_DIR/mkosi.conf.d" ]] && EXTRA_ARGS+=("--include=$HOST_DIR/mkosi.conf.d")
  [[ -d "$HOST_DIR/mkosi.extra" ]] && EXTRA_ARGS+=("--extra-tree=$HOST_DIR/mkosi.extra:/")
fi

CHECKSUM_FILE=".config-checksum"
CHECKSUM_INPUTS=(
  mkosi.conf
  mkosi.conf.d
  mkosi.profiles
  mkosi.build
  mkosi.finalize
  mkosi.prepare
  mkosi.extra
  hosts
  third-party
  .users.json
  build.sh
  run.sh
  clean.sh
  README.md
)

existing_inputs=()
for path in "${CHECKSUM_INPUTS[@]}"; do
  [[ -e "$path" ]] && existing_inputs+=("$path")
done

CURRENT_CHECKSUM="$({
  for path in "${existing_inputs[@]}"; do
    find "$path" -type f -print0
  done
} | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

if [[ -f "$CHECKSUM_FILE" ]]; then
  OLD_CHECKSUM="$(cat "$CHECKSUM_FILE")"
  if [[ "$CURRENT_CHECKSUM" != "$OLD_CHECKSUM" && -z "$MKOSI_FORCE" ]]; then
    echo "==> Configuration changed. Automatically setting --force..."
    MKOSI_FORCE="-f"
  fi
fi

echo "==> Starting mkosi build (profile: $PROFILE, force: ${MKOSI_FORCE:-none})..."
mkosi --profile="$PROFILE" ${MKOSI_FORCE} "${EXTRA_ARGS[@]}" build

echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
echo "==> Build complete. Artifacts are in mkosi.output/"
