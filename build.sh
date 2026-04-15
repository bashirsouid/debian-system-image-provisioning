#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$PROJECT_ROOT/.mkosi-secrets"
THIRD_PARTY_DIR="$PROJECT_ROOT/.mkosi-thirdparty"
USERS_FILE="$PROJECT_ROOT/.users.json"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=scripts/lib/build-meta.sh
source "$PROJECT_ROOT/scripts/lib/build-meta.sh"
USERS_SAMPLE="$PROJECT_ROOT/.users.json.sample"
PROFILE="devbox"
HOST=""
MKOSI_FORCE=""
SYNC_HOST_IDS=true
IMAGE_ID="${AB_IMAGE_ID:-debian-provisioning}"
IMAGE_VERSION=""
TARGET_ARCH=""
HOST_KERNEL_ARGS=""

HOST_USER_NAME="$(id -un)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HOST_PRIMARY_GROUP="$(id -gn)"

usage() {
  cat <<'USAGE'
Usage: ./build.sh [options]

Options:
  --profile NAME           build profile (default: devbox)
  --host NAME              include host-specific overlay from hosts/NAME/
  --force                  pass mkosi -f
  --clean                  pass mkosi -f -f
  --sync-host-ids=yes|no   when username matches the invoking host user,
                           copy that user's uid/gid/group into the image
USAGE
}

hash_password() {
  local password="$1"

  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$password" | openssl passwd -6 -stdin
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    PASSWORD="$password" python3 - <<'PY'
import crypt
import os
print(crypt.crypt(os.environ['PASSWORD'], crypt.mksalt(crypt.METHOD_SHA512)))
PY
    return
  fi

  echo "ERROR: need openssl or python3 on the build host to hash user passwords" >&2
  exit 1
}

normalize_optional_id() {
  local raw="$1"
  local fallback="${2-}"

  case "$raw" in
    "")
      printf '%s\n' ""
      ;;
    host)
      printf '%s\n' "$fallback"
      ;;
    *[!0-9]*)
      echo "ERROR: invalid numeric id value: $raw" >&2
      exit 1
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
}

read_release_from_mkosi_conf() {
  awk -F= '
    /^[[:space:]]*Release[[:space:]]*=/ {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$PROJECT_ROOT/mkosi.conf"
}

read_architecture_from_configs() {
  local value=""
  local file
  for file in "$PROJECT_ROOT/mkosi.conf" "$PROJECT_ROOT/hosts/$HOST"/mkosi.conf.d/*.conf; do
    [[ -f "$file" ]] || continue
    value="$(awk -F= '
      /^[[:space:]]*Architecture[[:space:]]*=/ {
        v=$2
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        print v
      }
    ' "$file" | tail -n1)"
    [[ -n "$value" ]] && TARGET_ARCH="$value"
  done

  if [[ -z "$TARGET_ARCH" ]]; then
    TARGET_ARCH="x86-64"
  fi
}

read_host_kernel_args() {
  local path
  path="$PROJECT_ROOT/hosts/$HOST/kernel-cmdline.extra"
  if [[ -n "$HOST" && -f "$path" ]]; then
    HOST_KERNEL_ARGS="$(tr '\n' ' ' < "$path" | xargs echo -n)"
  else
    HOST_KERNEL_ARGS=""
  fi
}

fetch_url() {
  local url="$1"
  local destination="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$destination"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
    return
  fi

  echo "ERROR: need curl or wget on the build host to fetch third-party repo metadata" >&2
  exit 1
}

prepare_liquorix_trees() {
  local suite sandbox_root keyring_path source_path

  suite="$(read_release_from_mkosi_conf)"
  if [[ -z "$suite" ]]; then
    echo "ERROR: unable to determine Debian Release= from mkosi.conf" >&2
    exit 1
  fi

  rm -rf "$THIRD_PARTY_DIR"

  sandbox_root="$THIRD_PARTY_DIR/liquorix-sandbox"
  install -d -m 0755 \
    "$sandbox_root/etc/apt/sources.list.d" \
    "$sandbox_root/usr/share/keyrings"

  keyring_path="$sandbox_root/usr/share/keyrings/liquorix-keyring.gpg"
  fetch_url "https://liquorix.net/liquorix-keyring.gpg" "$keyring_path"

  source_path="$sandbox_root/etc/apt/sources.list.d/liquorix.sources"
  cat > "$source_path" <<SOURCE
Types: deb
URIs: https://liquorix.net/debian
Suites: $suite
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/liquorix-keyring.gpg
SOURCE
}

render_users_conf() {
  local output="$1"
  : > "$output"

  while IFS= read -r entry; do
    local username can_login requested_shell password_hash password_plain groups_csv
    local requested_uid requested_gid requested_primary_group requested_home
    local effective_uid effective_gid effective_primary_group effective_home

    username="$(jq -r '.username // empty' <<<"$entry")"
    can_login="$(jq -r 'if has("can_login") and .can_login != null then .can_login else true end' <<<"$entry")"
    requested_shell="$(jq -r '.shell // "/bin/bash"' <<<"$entry")"
    password_hash="$(jq -r '.password_hash // empty' <<<"$entry")"
    password_plain="$(jq -r '.password // empty' <<<"$entry")"
    groups_csv="$(jq -r '
      if .groups == null then
        ""
      elif (.groups | type) == "array" then
        (.groups | map(tostring) | join(","))
      else
        (.groups | tostring)
      end
    ' <<<"$entry")"
    requested_uid="$(jq -r '.uid // empty' <<<"$entry")"
    requested_gid="$(jq -r '.gid // empty' <<<"$entry")"
    requested_primary_group="$(jq -r '.primary_group // empty' <<<"$entry")"
    requested_home="$(jq -r '.home // empty' <<<"$entry")"

    [[ -n "$username" && "$username" != "root" ]] || continue

    if [[ -z "$password_hash" && -n "$password_plain" ]]; then
      password_hash="$(hash_password "$password_plain")"
    fi

    effective_uid="$(normalize_optional_id "$requested_uid")"
    effective_gid="$(normalize_optional_id "$requested_gid")"
    effective_primary_group="$requested_primary_group"

    if [[ "$requested_primary_group" == "host" ]]; then
      effective_primary_group="$HOST_PRIMARY_GROUP"
    fi

    if [[ "$SYNC_HOST_IDS" == true && "$username" == "$HOST_USER_NAME" ]]; then
      [[ -n "$effective_uid" ]] || effective_uid="$HOST_UID"
      [[ -n "$effective_gid" ]] || effective_gid="$HOST_GID"
      [[ -n "$effective_primary_group" ]] || effective_primary_group="$HOST_PRIMARY_GROUP"
    fi

    if [[ "$can_login" == "true" ]]; then
      effective_home="${requested_home:-/home/$username}"
      [[ -n "$effective_primary_group" ]] || effective_primary_group="$username"
    else
      effective_home="${requested_home:-/nonexistent}"
      [[ -n "$effective_primary_group" ]] || effective_primary_group="$username"
    fi

    printf '%s:%s:%s:%s:%s:%s:%s:%s:%s\n' \
      "$username" \
      "$can_login" \
      "$requested_shell" \
      "$groups_csv" \
      "$password_hash" \
      "$effective_uid" \
      "$effective_gid" \
      "$effective_primary_group" \
      "$effective_home" >> "$output"
  done < <(jq -c '.[]' "$USERS_FILE")
}

git_value() {
  local repo="$1"
  shift
  git -C "$repo" "$@" 2>/dev/null || true
}

git_rev() {
  local repo="$1"
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_value "$repo" rev-parse HEAD | head -n1
  fi
}

git_dirty() {
  local repo="$1"
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  if git -C "$repo" diff --no-ext-diff --quiet --ignore-submodules=dirty && \
     git -C "$repo" diff --no-ext-diff --cached --quiet --ignore-submodules=dirty; then
    printf 'no\n'
  else
    printf 'yes\n'
  fi
}

write_env_kv() {
  local path="$1"
  shift
  local tmp dir
  dir="$(dirname "$path")"
  install -d -m 0755 "$dir"
  tmp="$(mktemp "$dir/.abtmp.XXXXXX")"
  : > "$tmp"
  while [[ $# -gt 0 ]]; do
    printf '%s=%q\n' "$1" "${2-}" >> "$tmp"
    shift 2
  done
  chmod 0644 "$tmp"
  mv "$tmp" "$path"
}

render_build_info() {
  local output="$1"
  local build_time build_user build_host build_git_rev build_git_dirty
  local awesome_git_rev awesome_git_dirty kernel_track mkosi_version host_overlay

  build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  build_user="$HOST_USER_NAME"
  build_host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  build_git_rev="$(git_rev "$PROJECT_ROOT")"
  build_git_dirty="$(git_dirty "$PROJECT_ROOT")"
  awesome_git_rev="$(git_rev "$PROJECT_ROOT/third-party/awesome")"
  awesome_git_dirty="$(git_dirty "$PROJECT_ROOT/third-party/awesome")"
  kernel_track="debian"
  [[ "$PROFILE" == "devbox" ]] && kernel_track="liquorix"
  mkosi_version="$(mkosi --version 2>/dev/null | head -n1 || true)"
  host_overlay="${HOST:-none}"

  write_env_kv "$output" \
    AB_BUILD_TIME_UTC "$build_time" \
    AB_BUILD_PROFILE "$PROFILE" \
    AB_BUILD_HOST_OVERLAY "$host_overlay" \
    AB_BUILD_HOST_USER "$build_user" \
    AB_BUILD_HOSTNAME "$build_host" \
    AB_BUILD_GIT_REV "$build_git_rev" \
    AB_BUILD_GIT_DIRTY "$build_git_dirty" \
    AB_BUILD_AWESOME_GIT_REV "$awesome_git_rev" \
    AB_BUILD_AWESOME_GIT_DIRTY "$awesome_git_dirty" \
    AB_BUILD_KERNEL_TRACK "$kernel_track" \
    AB_BUILD_MKOSI_VERSION "$mkosi_version" \
    AB_IMAGE_ID "$IMAGE_ID" \
    AB_IMAGE_VERSION "$IMAGE_VERSION" \
    AB_IMAGE_ARCH "$TARGET_ARCH" \
    AB_HOST_KERNEL_ARGS "$HOST_KERNEL_ARGS"
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
    --force)
      MKOSI_FORCE="-f"
      shift
      ;;
    --clean)
      MKOSI_FORCE="-f -f"
      shift
      ;;
    --sync-host-ids=yes|--sync-host-ids=true)
      SYNC_HOST_IDS=true
      shift
      ;;
    --sync-host-ids=no|--sync-host-ids=false)
      SYNC_HOST_IDS=false
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

cd "$PROJECT_ROOT"
mkdir -p mkosi.output

if [[ ! -f "$USERS_FILE" ]]; then
  echo "WARNING: $USERS_FILE missing. Creating from sample..."
  cp "$USERS_SAMPLE" "$USERS_FILE"
  echo "IMPORTANT: edit $USERS_FILE and set your passwords before building."
  exit 1
fi

if ! ab_hostdeps_have_all_commands mkosi jq openssl sfdisk; then
  ab_hostdeps_ensure_packages "build host prerequisites" mkosi jq openssl fdisk || exit 1
fi
ab_hostdeps_ensure_commands "build host prerequisites" mkosi jq openssl sfdisk || exit 1


if [[ "$PROFILE" == "devbox" ]]; then
  if ! ab_hostdeps_have_all_commands curl; then
    ab_hostdeps_ensure_packages "build host prerequisites for devbox" curl || exit 1
  fi
  ab_hostdeps_ensure_commands "build host prerequisites for devbox" curl || exit 1
fi

if [[ "$PROFILE" == "devbox" && ! -f "$PROJECT_ROOT/third-party/awesome/CMakeLists.txt" ]]; then
  echo "ERROR: devbox profile requires third-party/awesome" >&2
  echo "Run ./update-3rd-party-deps.sh first." >&2
  exit 1
fi

if [[ -n "$HOST" && ! -d "$PROJECT_ROOT/hosts/$HOST" ]]; then
  echo "ERROR: host directory hosts/$HOST not found" >&2
  exit 1
fi

IMAGE_VERSION="$($PROJECT_ROOT/mkosi.version)"
read_architecture_from_configs
read_host_kernel_args

echo "==> Preparing first-boot provisioning data..."
echo "==> Host UID/GID sync for matching user '$HOST_USER_NAME': $SYNC_HOST_IDS ($HOST_UID:$HOST_GID $HOST_PRIMARY_GROUP)"
echo "==> Image identity: $IMAGE_ID version $IMAGE_VERSION arch $TARGET_ARCH"
rm -rf "$SECRETS_DIR"
install -d -m 0755 \
  "$SECRETS_DIR/usr/local/etc" \
  "$SECRETS_DIR/usr/local/share/ab-image-meta" \
  "$SECRETS_DIR/usr/lib/sysupdate.d"
render_users_conf "$SECRETS_DIR/usr/local/etc/users.conf"
chmod 0600 "$SECRETS_DIR/usr/local/etc/users.conf"
render_build_info "$SECRETS_DIR/usr/local/share/ab-image-meta/build-info.env"
cp -a "$PROJECT_ROOT"/mkosi.sysupdate/*.transfer "$SECRETS_DIR/usr/lib/sysupdate.d/"

EXTRA_ARGS=()
if [[ "$PROFILE" == "devbox" ]]; then
  echo "==> Preparing Liquorix repository metadata for devbox..."
  prepare_liquorix_trees
  EXTRA_ARGS+=("--sandbox-tree=$THIRD_PARTY_DIR/liquorix-sandbox:/")
fi

if [[ -n "$HOST" ]]; then
  HOST_DIR="hosts/$HOST"
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
  mkosi.sysupdate
  deploy.repart
  hosts
  third-party
  docs
  scripts
  ansible
  .users.json
  build.sh
  run.sh
  clean.sh
  mkosi.version
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

find_built_disk_image() {
  local expected="$1"
  local candidate=""
  local matches=()

  if [[ -f "$expected" ]]; then
    printf '%s\n' "$expected"
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    matches+=("$candidate")
  done < <(
    find "$PROJECT_ROOT/mkosi.output" -maxdepth 1 -type f -name '*.raw' \
      ! -name '*.root.raw' ! -name '*.vmlinuz.raw' ! -name '*.initrd.raw' | sort
  )

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    printf '%s\n' "$(ls -1t "${matches[@]}" | head -n1)"
    return 0
  fi

  return 1
}

mkosi_args=("--profile=$PROFILE" "--image-id=$IMAGE_ID" "--image-version=$IMAGE_VERSION")

echo "==> Starting mkosi build (profile: $PROFILE, force: ${MKOSI_FORCE:-none})..."
if [[ -n "$MKOSI_FORCE" ]]; then
  # shellcheck disable=SC2206
  force_args=($MKOSI_FORCE)
  mkosi "${mkosi_args[@]}" "${force_args[@]}" "${EXTRA_ARGS[@]}" build
else
  mkosi "${mkosi_args[@]}" "${EXTRA_ARGS[@]}" build
fi

EXPECTED_IMAGE_PATH="$PROJECT_ROOT/mkosi.output/${IMAGE_ID}_${IMAGE_VERSION}.raw"
BUILT_IMAGE_PATH="$(find_built_disk_image "$EXPECTED_IMAGE_PATH" || true)"
if [[ -z "$BUILT_IMAGE_PATH" ]]; then
  echo "ERROR: unable to locate built disk image in mkosi.output/" >&2
  exit 1
fi

BUILT_IMAGE_BASENAME="$(basename "$BUILT_IMAGE_PATH")"

echo "==> Exporting sysupdate artifacts..."
"$PROJECT_ROOT/scripts/export-sysupdate-artifacts.sh" \
  --image-id "$IMAGE_ID" \
  --version "$IMAGE_VERSION" \
  --arch "$TARGET_ARCH" \
  --image "$BUILT_IMAGE_PATH" \
  --output-dir "$PROJECT_ROOT/mkosi.output" \
  --entry-title "Debian Provisioning" \
  --extra-kernel-args "$HOST_KERNEL_ARGS"

ab_buildmeta_write "$PROJECT_ROOT" \
  AB_LAST_BUILD_IMAGE_ID "$IMAGE_ID" \
  AB_LAST_BUILD_IMAGE_VERSION "$IMAGE_VERSION" \
  AB_LAST_BUILD_PROFILE "$PROFILE" \
  AB_LAST_BUILD_HOST "$HOST" \
  AB_LAST_BUILD_ARCH "$TARGET_ARCH" \
  AB_LAST_BUILD_IMAGE_BASENAME "$BUILT_IMAGE_BASENAME"

ab_buildmeta_write_for "$PROJECT_ROOT" "$PROFILE" "$HOST" \
  AB_LAST_BUILD_IMAGE_ID "$IMAGE_ID" \
  AB_LAST_BUILD_IMAGE_VERSION "$IMAGE_VERSION" \
  AB_LAST_BUILD_PROFILE "$PROFILE" \
  AB_LAST_BUILD_HOST "$HOST" \
  AB_LAST_BUILD_ARCH "$TARGET_ARCH" \
  AB_LAST_BUILD_IMAGE_BASENAME "$BUILT_IMAGE_BASENAME"

echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
echo "==> Build complete. Artifacts are in mkosi.output/"
