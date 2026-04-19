#!/usr/bin/env bash
set -euo pipefail


PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$PROJECT_ROOT/.mkosi-secrets"
THIRD_PARTY_DIR="$PROJECT_ROOT/.mkosi-thirdparty"
USERS_FILE="$PROJECT_ROOT/.users.json"
USERS_SAMPLE="$PROJECT_ROOT/.users.json.sample"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=scripts/lib/build-meta.sh
source "$PROJECT_ROOT/scripts/lib/build-meta.sh"

PROFILE="devbox"
HOST=""
PROFILE_SET=false
HOST_SET=false
BUILD_ALL=false
FORCE_REBUILD=false
MKOSI_FORCE=""
SYNC_HOST_IDS=true
BASE_IMAGE_ID="${AB_IMAGE_ID:-debian-provisioning}"
IMAGE_VERSION=""
TARGET_ARCH=""
HOST_KERNEL_ARGS=""
CURRENT_CHECKSUM=""
NON_INTERACTIVE=false

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
  --force-rebuild          clean all generated state, refresh managed third-party
                           checkouts from clean clones, then rebuild
  --all                    build the standard target matrix in one invocation:
                             devbox
                             devbox --host evox2
                             server --host cloudbox
                             macbook --host macbookpro13-2019-t2
  --sync-host-ids=yes|no   when username matches the invoking host user,
                           copy that user's uid/gid/group into the image
  --non-interactive        disable all interactive prompts (default to No)
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
  TARGET_ARCH=""

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

# Read hosts/<name>/profile.default for a host and echo the profile name.
# Prints nothing if the host has no default or the file is empty/malformed.
# Exits non-zero only if the host dir itself is missing (caller decides).
read_host_default_profile() {
  local host_name="$1"
  local path="$PROJECT_ROOT/hosts/$host_name/profile.default"
  local value
  [[ -f "$path" ]] || return 0
  # Strip comments, leading/trailing whitespace, take first non-empty line.
  value="$(sed -e 's/[[:space:]]*#.*$//' "$path" | awk 'NF{print;exit}' | tr -d '[:space:]')"
  # Validate: only simple profile names (matches what mkosi accepts).
  case "$value" in
    ""|*[!A-Za-z0-9._-]*) return 0 ;;
    *) printf '%s\n' "$value" ;;
  esac
}

fetch_url() {
  local url="$1"
  local destination="$2"
  local max_attempts=3
  local attempt=1
  local backoff=5

  while [[ $attempt -le $max_attempts ]]; do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL "$url" -o "$destination"; then
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO "$destination" "$url"; then
        return 0
      fi
    else
      echo "ERROR: need curl or wget on the build host to fetch third-party repo metadata" >&2
      exit 1
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      echo "WARNING: fetch attempt $attempt/$max_attempts failed for $url. Retrying in ${backoff}s..." >&2
      sleep "$backoff"
      backoff=$((backoff * 2))
      ((attempt++))
    else
      break
    fi
  done

  echo "ERROR: failed to fetch $url after $max_attempts attempts" >&2
  return 1
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

prepare_t2linux_trees() {
  local suite sandbox_root key_tmp keyring_path t2_list_path firmware_list_path

  suite="$(read_release_from_mkosi_conf)"
  if [[ -z "$suite" ]]; then
    echo "ERROR: unable to determine Debian Release= from mkosi.conf" >&2
    exit 1
  fi

  rm -rf "$THIRD_PARTY_DIR"

  sandbox_root="$THIRD_PARTY_DIR/t2linux-sandbox"
  install -d -m 0755 \
    "$sandbox_root/etc/apt/sources.list.d" \
    "$sandbox_root/etc/apt/trusted.gpg.d"

  key_tmp="$(mktemp)"
  trap 'rm -f "$key_tmp"' RETURN
  fetch_url "https://adityagarg8.github.io/t2-ubuntu-repo/KEY.gpg" "$key_tmp"

  keyring_path="$sandbox_root/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg"
  gpg --dearmor --yes --output "$keyring_path" "$key_tmp"

  t2_list_path="$sandbox_root/etc/apt/sources.list.d/t2.list"
  # Use the stable t2-ubuntu-repo instead of GitHub releases URLs (which have JWT expiration issues)
  cat > "$t2_list_path" <<SOURCE
Types: deb
URIs: https://github.com/AdityaGarg8/t2-ubuntu-repo/releases/download/debian
Suites: ${suite}
Components: main
Architectures: amd64
Signed-By: /etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg
SOURCE

  # Alternative: Apple firmware from GitHub releases - with better resilience
  firmware_list_path="$sandbox_root/etc/apt/sources.list.d/apple-firmware.list"
  cat > "$firmware_list_path" <<SOURCE
Types: deb
URIs: https://github.com/AdityaGarg8/Apple-Firmware/releases/download/debian
Suites: ./
Components: 
Architectures: amd64
Signed-By: /etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg
SOURCE

  rm -f "$key_tmp"
  trap - RETURN
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
  local image_id="$2"
  local image_version="$3"
  local target_arch="$4"
  local host_kernel_args="$5"
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
  [[ "$PROFILE" == "macbook" ]] && kernel_track="t2linux"
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
    AB_IMAGE_ID "$image_id" \
    AB_IMAGE_VERSION "$image_version" \
    AB_IMAGE_ARCH "$target_arch" \
    AB_HOST_KERNEL_ARGS "$host_kernel_args"
}

render_sysupdate_transfers() {
  local output_dir="$1"
  local image_id="$2"
  local src dest image_id_escaped

  install -d -m 0755 "$output_dir"
  image_id_escaped="$(printf '%s' "$image_id" | sed 's/[\/&]/\\&/g')"

  shopt -s nullglob
  local transfers=("$PROJECT_ROOT"/mkosi.sysupdate/*.transfer)
  shopt -u nullglob
  (( ${#transfers[@]} > 0 )) || {
    echo "ERROR: no *.transfer files found in $PROJECT_ROOT/mkosi.sysupdate" >&2
    exit 1
  }

  for src in "${transfers[@]}"; do
    dest="$output_dir/$(basename "$src")"
    sed "s/debian-provisioning/${image_id_escaped}/g" "$src" > "$dest"
  done
}

profile_needs_awesome() {
  [[ "$1" == "devbox" || "$1" == "macbook" ]]
}

profile_needs_macbook_audio() {
  [[ "$1" == "macbook" ]]
}

profile_needs_managed_third_party() {
  profile_needs_awesome "$1" || profile_needs_macbook_audio "$1"
}

sanitize_image_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

image_id_for_target() {
  # Always produce a (profile,host)-specific image id so artifacts in
  # mkosi.output/ from one target never silently clobber another target's
  # artifacts of the same name. Previously this only applied in --all
  # mode; in single-target mode two back-to-back builds with different
  # profiles would overwrite each other's image.raw / .root.raw / .efi /
  # .conf / SHA256SUMS, and the per-host .latest-build.<p>.<h>.env
  # metadata would then point to files containing the other target's
  # bits. BUILD_ALL still exists but no longer changes the scheme.
  local base="$1"
  local profile="$2"
  local host="$3"

  local suffix
  suffix="$(sanitize_image_component "$profile")"
  if [[ -n "$host" ]]; then
    suffix+="-$(sanitize_image_component "$host")"
  fi
  printf '%s-%s\n' "$base" "$suffix"
}

# GPT partition labels are capped at 36 UTF-16 code units. sysupdate's
# MatchPattern on [Target] partitions substitutes @v with the version, so
# the effective label is "<image_id>_<version>". If that exceeds 36 chars
# the label gets silently truncated on write and sysupdate's MatchPattern
# no longer matches on the next update. Warn loudly so the user can pick
# a shorter base via AB_IMAGE_ID=.
warn_if_image_label_too_long() {
  local image_id="$1"
  local image_version="$2"
  local total=$(( ${#image_id} + 1 + ${#image_version} ))
  if (( total > 36 )); then
    echo "WARNING: image id + version is $total chars ('${image_id}_${image_version}')." >&2
    echo "         GPT partition labels truncate at 36 chars, which will break" >&2
    echo "         sysupdate's MatchPattern on the [Target] partition." >&2
    echo "         Set AB_IMAGE_ID= to a shorter base (currently '$BASE_IMAGE_ID')." >&2
  fi
}

compute_config_checksum() {
  local path
  local inputs=(
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
    update-3rd-party-deps.sh
  )
  local existing=()

  for path in "${inputs[@]}"; do
    [[ -e "$path" ]] && existing+=("$path")
  done

  CURRENT_CHECKSUM="$({
    for path in "${existing[@]}"; do
      find "$path" -type f -print0
    done
  } | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
}

ensure_base_hostdeps() {
  if ! ab_hostdeps_have_all_commands mkosi jq openssl sfdisk; then
    ab_hostdeps_ensure_packages "build host prerequisites" mkosi jq openssl fdisk || exit 1
  fi
  ab_hostdeps_ensure_commands "build host prerequisites" mkosi jq openssl sfdisk || exit 1
}

ensure_profile_hostdeps() {
  local profile="$1"

  ensure_base_hostdeps

  if profile_needs_awesome "$profile"; then
    if ! ab_hostdeps_have_all_commands curl; then
      ab_hostdeps_ensure_packages "build host prerequisites for desktop profiles" curl || exit 1
    fi
    ab_hostdeps_ensure_commands "build host prerequisites for desktop profiles" curl || exit 1
  fi

  if profile_needs_macbook_audio "$profile"; then
    if ! ab_hostdeps_have_all_commands gpg; then
      ab_hostdeps_ensure_packages "build host prerequisites for macbook profile" gpg || exit 1
    fi
    ab_hostdeps_ensure_commands "build host prerequisites for macbook profile" gpg || exit 1
  fi
}

ensure_managed_sources_once() {
  local mode="$1"
  local needs_any=false
  local target profile host missing_deps=false missing_keys=false

  for target in "${BUILD_TARGETS[@]}"; do
    profile="${target%%|*}"
    host="${target#*|}"
    if profile_needs_managed_third_party "$profile"; then
      needs_any=true
      break
    fi
  done

  if [[ "$mode" == "fresh" ]]; then
    echo "==> Refreshing third-party GPG keys..."
    "$PROJECT_ROOT/scripts/fetch-third-party-keys.sh"

    if [[ "$needs_any" == true ]]; then
      echo "==> Refreshing managed third-party sources from clean clones..."
      "$PROJECT_ROOT/update-3rd-party-deps.sh" --fresh
    fi
    return 0
  fi

  if [[ ! -f "$PROJECT_ROOT/mkosi.extra/etc/apt/keyrings/cloudflare-main.gpg" || ! -f "$PROJECT_ROOT/mkosi.extra/etc/apt/keyrings/tailscale-archive-keyring.gpg" ]]; then
    missing_keys=true
  fi

  if [[ "$needs_any" == true ]]; then
    for target in "${BUILD_TARGETS[@]}"; do
      profile="${target%%|*}"
      host="${target#*|}"
      if profile_needs_awesome "$profile" && [[ ! -f "$PROJECT_ROOT/third-party/awesome/CMakeLists.txt" ]]; then
        missing_deps=true
      fi
      if profile_needs_macbook_audio "$profile" && [[ ! -f "$PROJECT_ROOT/third-party/snd_hda_macbookpro/install.cirrus.driver.sh" ]]; then
        missing_deps=true
      fi
    done
  fi

  if [[ "$missing_keys" == true ]]; then
    echo "==> Bootstrapping third-party GPG keys..."
    "$PROJECT_ROOT/scripts/fetch-third-party-keys.sh"
  fi

  if [[ "$missing_deps" == true ]]; then
    echo "==> Bootstrapping managed third-party sources..."
    "$PROJECT_ROOT/update-3rd-party-deps.sh"
  fi
}

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

build_target() {
  local target_profile="$1"
  local target_host="$2"
  local target_image_id target_force
  local host_dir checksum_file old_checksum built_image_path built_image_basename expected_image_path
  local extra_args=() mkosi_args=()

  PROFILE="$target_profile"
  HOST="$target_host"
  TARGET_ARCH=""
  HOST_KERNEL_ARGS=""
  target_force="$MKOSI_FORCE"
  target_image_id="$(image_id_for_target "$BASE_IMAGE_ID" "$PROFILE" "$HOST")"
  warn_if_image_label_too_long "$target_image_id" "$IMAGE_VERSION"

  ensure_profile_hostdeps "$PROFILE"

  if [[ -n "$HOST" && ! -d "$PROJECT_ROOT/hosts/$HOST" ]]; then
    echo "ERROR: host directory hosts/$HOST not found" >&2
    exit 1
  fi

  # Secure Boot posture: every --host build must either configure
  # signing (SB drop-in + .secureboot/ key material) or explicitly
  # opt out with hosts/<HOST>/secure-boot.disabled. "Silently build
  # an unsigned image" is not an option, because that's exactly the
  # footgun the drop-in model is meant to prevent.
  # No-host builds (QEMU smoke test) are exempt: they exercise image
  # contents, not the boot-trust chain, and are never flashed.
  if [[ -n "$HOST" ]]; then
    local sb_drop_in="$PROJECT_ROOT/hosts/$HOST/mkosi.conf.d/30-secure-boot.conf"
    local sb_disabled="$PROJECT_ROOT/hosts/$HOST/secure-boot.disabled"
    local sb_key="$PROJECT_ROOT/.secureboot/db.key"
    local sb_cert="$PROJECT_ROOT/.secureboot/db.crt"

    if [[ -f "$sb_disabled" ]]; then
      echo "==> Secure Boot: DISABLED for host $HOST. Recorded reason:" >&2
      sed 's/^/      /' "$sb_disabled" >&2
    elif [[ -f "$sb_drop_in" ]]; then
      if [[ ! -f "$sb_key" || ! -f "$sb_cert" ]]; then
        cat >&2 <<EOF
ERROR: Secure Boot is enabled for host $HOST (see $sb_drop_in)
but the signing key and certificate are missing from .secureboot/.

Run:
  ./scripts/generate-secureboot-keys.sh

Back up .secureboot/db.key offline before rebuilding — losing it
orphans every machine already enrolled with it.
EOF
        exit 1
      fi
      echo "==> Secure Boot: enabled. UKI will be signed with .secureboot/db.key"
    else
      cat >&2 <<EOF
ERROR: host $HOST has neither a Secure Boot configuration nor an
explicit opt-out. Every host-targeted build must do one of:

  * Opt in (recommended): create
      hosts/$HOST/mkosi.conf.d/30-secure-boot.conf
    (see hosts/evox2/mkosi.conf.d/30-secure-boot.conf for a template)
    and run ./scripts/generate-secureboot-keys.sh.

  * Opt out: create hosts/$HOST/secure-boot.disabled with a one-line
    reason. The reason is printed on every build so the exception
    stays visible. See hosts/macbookpro13-2019-t2/secure-boot.disabled
    for an example.

This is the default because images that get flashed to real hardware
must be tamper-evident. QEMU smoke tests (./build.sh with no --host)
are not affected.
EOF
      exit 1
    fi
  fi

  if profile_needs_awesome "$PROFILE" && [[ ! -f "$PROJECT_ROOT/third-party/awesome/CMakeLists.txt" ]]; then
    echo "ERROR: desktop profiles require third-party/awesome" >&2
    echo "Run ./update-3rd-party-deps.sh or ./build.sh --force-rebuild ..." >&2
    exit 1
  fi

  if profile_needs_macbook_audio "$PROFILE" && [[ ! -f "$PROJECT_ROOT/third-party/snd_hda_macbookpro/install.cirrus.driver.sh" ]]; then
    echo "ERROR: macbook profile requires third-party/snd_hda_macbookpro" >&2
    echo "Run ./update-3rd-party-deps.sh or ./build.sh --force-rebuild ..." >&2
    exit 1
  fi

  read_architecture_from_configs
  read_host_kernel_args

  echo "==> Preparing first-boot provisioning data for profile=$PROFILE${HOST:+ host=$HOST}..."
  echo "==> Host UID/GID sync for matching user '$HOST_USER_NAME': $SYNC_HOST_IDS ($HOST_UID:$HOST_GID $HOST_PRIMARY_GROUP)"
  echo "==> Image identity: $target_image_id version $IMAGE_VERSION arch $TARGET_ARCH"
  METADATA_DIR="$PROJECT_ROOT/.mkosi-metadata"
  rm -rf "$METADATA_DIR"
  install -d -m 0755 \
    "$METADATA_DIR/usr/local/etc" \
    "$METADATA_DIR/usr/local/share/ab-image-meta" \
    "$METADATA_DIR/usr/lib/sysupdate.d"

  # Per-host users override: if hosts/<HOST>/users.json exists, it
  # replaces the global .users.json for this build target. This lets a
  # workstation and a server share the same repo while keeping
  # host-specific user sets (or a different password for the shared
  # login user) out of the global file.
  local _original_users_file="$USERS_FILE"
  if [[ -n "$HOST" && -f "$PROJECT_ROOT/hosts/$HOST/users.json" ]]; then
    USERS_FILE="$PROJECT_ROOT/hosts/$HOST/users.json"
    echo "==> Using per-host users file: hosts/$HOST/users.json"
  fi
  render_users_conf "$METADATA_DIR/usr/local/etc/users.conf"
  USERS_FILE="$_original_users_file"
  chmod 0600 "$METADATA_DIR/usr/local/etc/users.conf"
  render_build_info "$METADATA_DIR/usr/local/share/ab-image-meta/build-info.env" "$target_image_id" "$IMAGE_VERSION" "$TARGET_ARCH" "$HOST_KERNEL_ARGS"
  render_sysupdate_transfers "$METADATA_DIR/usr/lib/sysupdate.d" "$target_image_id"

  if [[ "${AB_SKIP_OVERLAY_GATES:-no}" != "yes" ]]; then
      if [[ -d "$PROJECT_ROOT/.mkosi-secrets" && -x "$PROJECT_ROOT/scripts/package-credentials.sh" ]]; then
          echo "==> Packaging remote-access credentials for profile=$PROFILE${HOST:+ host=$HOST}..."
          pkg_args=()
          [[ -n "$HOST" ]] && pkg_args+=(--host "$HOST")
          [[ "$NON_INTERACTIVE" == true ]] && pkg_args+=("--non-interactive")
          [[ "$NON_INTERACTIVE" == true ]] && export AB_NON_INTERACTIVE=1
          pkg_args+=(--out "$METADATA_DIR")
          "$PROJECT_ROOT/scripts/package-credentials.sh" "${pkg_args[@]}"
      fi

      if [[ -d "$PROJECT_ROOT/.mkosi-secrets" && -x "$PROJECT_ROOT/scripts/package-alert-credentials.sh" ]]; then
          echo "==> Packaging alert credentials for profile=$PROFILE${HOST:+ host=$HOST}..."
          pkg_args=()
          [[ -n "$HOST" ]] && pkg_args+=(--host "$HOST")
          [[ "$NON_INTERACTIVE" == true ]] && pkg_args+=("--non-interactive")
          pkg_args+=(--out "$METADATA_DIR")
          "$PROJECT_ROOT/scripts/package-alert-credentials.sh" "${pkg_args[@]}"
      fi
  fi

  extra_args+=("--extra-tree=$METADATA_DIR:/")
  extra_args+=("--sandbox-tree=$PROJECT_ROOT/mkosi.extra:/")

  if [[ "$PROFILE" == "devbox" ]]; then
    echo "==> Preparing Liquorix repository metadata for devbox..."
    prepare_liquorix_trees
    extra_args+=("--sandbox-tree=$THIRD_PARTY_DIR/liquorix-sandbox:/")
  fi

  if [[ "$PROFILE" == "macbook" ]]; then
    echo "==> Preparing t2linux and Apple firmware repository metadata for macbook..."
    prepare_t2linux_trees
    extra_args+=("--sandbox-tree=$THIRD_PARTY_DIR/t2linux-sandbox:/")
    extra_args+=("--extra-tree=$THIRD_PARTY_DIR/t2linux-sandbox:/")
    extra_args+=("--extra-tree=$PROJECT_ROOT/third-party/snd_hda_macbookpro:/usr/local/src/snd_hda_macbookpro")
  fi

  if [[ -n "$HOST" ]]; then
    host_dir="hosts/$HOST"
    echo "==> Including host-specific config for: $HOST"
    [[ -d "$host_dir/mkosi.conf.d" ]] && extra_args+=("--include=$host_dir/mkosi.conf.d")
    [[ -d "$host_dir/mkosi.extra" ]] && extra_args+=("--extra-tree=$host_dir/mkosi.extra:/")
  fi

  checksum_file="$PROJECT_ROOT/.config-checksum"
  if [[ -f "$checksum_file" && -z "$target_force" ]]; then
    old_checksum="$(cat "$checksum_file")"
    if [[ "$CURRENT_CHECKSUM" != "$old_checksum" ]]; then
      echo "==> Configuration changed. Automatically setting --force for this target..."
      target_force="-f"
    fi
  fi

  mkosi_args=("--profile=$PROFILE" "--image-id=$target_image_id" "--image-version=$IMAGE_VERSION")

  echo "==> Starting mkosi build (profile: $PROFILE${HOST:+, host: $HOST}, force: ${target_force:-none})..."
  if [[ -n "$target_force" ]]; then
    # shellcheck disable=SC2206
    local force_args=($target_force)
    mkosi "${mkosi_args[@]}" "${force_args[@]}" "${extra_args[@]}" build
  else
    mkosi "${mkosi_args[@]}" "${extra_args[@]}" build
  fi

  expected_image_path="$PROJECT_ROOT/mkosi.output/${target_image_id}_${IMAGE_VERSION}.raw"
  built_image_path="$(find_built_disk_image "$expected_image_path" || true)"
  if [[ -z "$built_image_path" ]]; then
    echo "ERROR: unable to locate built disk image in mkosi.output/ for $target_image_id" >&2
    exit 1
  fi

  built_image_basename="$(basename "$built_image_path")"

  echo "==> Exporting sysupdate artifacts for $target_image_id..."
  "$PROJECT_ROOT/scripts/export-sysupdate-artifacts.sh" \
    --image-id "$target_image_id" \
    --version "$IMAGE_VERSION" \
    --arch "$TARGET_ARCH" \
    --image "$built_image_path" \
    --output-dir "$PROJECT_ROOT/mkosi.output" \
    --entry-title "Debian Provisioning ($PROFILE${HOST:+/$HOST})" \
    --extra-kernel-args "$HOST_KERNEL_ARGS"

  ab_buildmeta_write "$PROJECT_ROOT" \
    AB_LAST_BUILD_IMAGE_ID "$target_image_id" \
    AB_LAST_BUILD_IMAGE_VERSION "$IMAGE_VERSION" \
    AB_LAST_BUILD_PROFILE "$PROFILE" \
    AB_LAST_BUILD_HOST "$HOST" \
    AB_LAST_BUILD_ARCH "$TARGET_ARCH" \
    AB_LAST_BUILD_IMAGE_BASENAME "$built_image_basename"

  ab_buildmeta_write_for "$PROJECT_ROOT" "$PROFILE" "$HOST" \
    AB_LAST_BUILD_IMAGE_ID "$target_image_id" \
    AB_LAST_BUILD_IMAGE_VERSION "$IMAGE_VERSION" \
    AB_LAST_BUILD_PROFILE "$PROFILE" \
    AB_LAST_BUILD_HOST "$HOST" \
    AB_LAST_BUILD_ARCH "$TARGET_ARCH" \
    AB_LAST_BUILD_IMAGE_BASENAME "$built_image_basename"
}

BUILD_TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing profile name}"
      PROFILE_SET=true
      shift 2
      ;;
    --host)
      HOST="${2:?missing host name}"
      HOST_SET=true
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
    --force-rebuild)
      FORCE_REBUILD=true
      shift
      ;;
    --all)
      BUILD_ALL=true
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
    --non-interactive)
      NON_INTERACTIVE=true
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

if [[ "$BUILD_ALL" == true && ( "$PROFILE_SET" == true || "$HOST_SET" == true ) ]]; then
  echo "ERROR: --all cannot be combined with explicit --profile or --host" >&2
  exit 1
fi

# Per-host default profile resolution.
#
# Precedence:
#   1. --profile on the command line always wins.
#   2. If only --host was given, read hosts/<host>/profile.default.
#   3. Fall back to the hardcoded default ("devbox") set at the top.
#
# This lets `./build.sh --host cloudbox` do the obviously-correct thing
# (build the server profile) without having to remember to also type
# --profile server every time.
if [[ "$BUILD_ALL" == false && "$PROFILE_SET" == false && "$HOST_SET" == true ]]; then
  host_default_profile="$(read_host_default_profile "$HOST")"
  if [[ -n "$host_default_profile" ]]; then
    echo "==> Using default profile from hosts/$HOST/profile.default: $host_default_profile"
    PROFILE="$host_default_profile"
  fi
fi

cd "$PROJECT_ROOT"
mkdir -p mkosi.output

if [[ ! -f "$USERS_FILE" ]]; then
  cat >&2 <<EOF
ERROR: $USERS_FILE is missing.

This file tells build.sh which local users to provision on first boot,
including their passwords. build.sh intentionally does NOT auto-create
it, because silently copying the sample would leave a known default
password ("change-me-now") on any image built without a manual review
step — a serious footgun for CI and for anyone building on autopilot.

To create it:
  cp $USERS_SAMPLE $USERS_FILE
  \$EDITOR $USERS_FILE              # set a real password / password_hash

Prefer password_hash over password. Generate one with:
  ./scripts/hash-password.sh --hash-only
EOF
  exit 1
fi

# Refuse to build if the sample sentinel password is still present.
# Users.json supports both 'password' and 'password_hash'; we guard both.
if jq -e '
  [ .[] |
    select(type == "object") |
    select(
      (.password // "") == "change-me-now"
      or (.password_hash // "") == "change-me-now"
    )
  ] | length > 0
' "$USERS_FILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: $USERS_FILE still contains the sample password "change-me-now".

Edit it and set a real password or password_hash. If you truly want to
build with a weak, known password (throwaway QEMU test only), set
AB_ALLOW_SAMPLE_PASSWORD=yes and re-run. This flag is intentionally
ugly so it shows up in logs.
EOF
  if [[ "${AB_ALLOW_SAMPLE_PASSWORD:-no}" != "yes" ]]; then
    exit 1
  fi
  echo "WARNING: AB_ALLOW_SAMPLE_PASSWORD=yes — building with sample password. DO NOT FLASH THIS IMAGE." >&2
fi

ensure_base_hostdeps

# Overlay integration: lint, validate secrets, package encrypted creds.
# These run once per invocation. Skip with AB_SKIP_OVERLAY_GATES=yes.
if [[ "${AB_SKIP_OVERLAY_GATES:-no}" != "yes" ]]; then

    # Lint all shell scripts. Fast. Fails closed on any warning.
    if [[ -x "$PROJECT_ROOT/scripts/lint.sh" ]]; then
        echo "==> Running shellcheck..."
        "$PROJECT_ROOT/scripts/lint.sh"
    fi

    # Preflight: refuse to build if any per-machine identity file is
    # committed under mkosi.extra/ or hosts/*/mkosi.extra/.
    # See scripts/verify-no-baked-identity.sh for rationale.
    if [[ -x "$PROJECT_ROOT/scripts/verify-no-baked-identity.sh" ]]; then
        echo "==> Auditing mkosi.extra/ for baked-in per-machine identity..."
        "$PROJECT_ROOT/scripts/verify-no-baked-identity.sh"
    fi

    # Validate secrets shape + permissions. Only runs if there is a
    # .mkosi-secrets/ directory; otherwise this is a no-op.
    if [[ -d "$PROJECT_ROOT/.mkosi-secrets" && \
          -x "$PROJECT_ROOT/scripts/verify-build-secrets.sh" ]]; then
        echo "==> Verifying .mkosi-secrets/ ..."
        verify_args=()
        [[ "${STRICT_SECRETS:-no}" == "yes" ]] && verify_args+=(--strict)
        [[ "$PROFILE_SET" == true ]] && verify_args+=(--profile "$PROFILE")
        [[ "$HOST_SET"    == true ]] && verify_args+=(--host "$HOST")
        [[ "$NON_INTERACTIVE" == true ]] && verify_args+=("--non-interactive")
        "$PROJECT_ROOT/scripts/verify-build-secrets.sh" "${verify_args[@]}"
    fi

fi


if [[ "$BUILD_ALL" == true ]]; then
  BUILD_TARGETS=(
    "devbox|"
    "devbox|evox2"
    "server|cloudbox"
    "macbook|macbookpro13-2019-t2"
  )
else
  BUILD_TARGETS=("$PROFILE|$HOST")
fi

if [[ "$FORCE_REBUILD" == true ]]; then
  echo "==> Force rebuild requested. Cleaning generated build state first..."
  "$PROJECT_ROOT/clean.sh" --all
  if [[ -z "$MKOSI_FORCE" ]]; then
    MKOSI_FORCE="-f"
  fi
  ensure_managed_sources_once fresh
else
  ensure_managed_sources_once normal
fi

compute_config_checksum

# IMAGE_VERSION resolution order:
#   1. AB_IMAGE_VERSION env var (explicit override wins).
#   2. If the config checksum is unchanged from the previous successful
#      build, reuse the previous IMAGE_VERSION. This stops mkosi.version
#      from minting a fresh UTC timestamp on every invocation, which
#      would otherwise cause mkosi.output/ to accumulate a new set of
#      .raw/.efi/.conf files per build even when nothing actually
#      changed. The checksum already covers every build input, so
#      "same checksum => same logical build => same version" is safe.
#   3. Otherwise mint a new timestamp via ./mkosi.version.
#
# AB_FORCE_NEW_VERSION=yes opts out of the reuse path, e.g. when you
# want a clean version bump without changing any tracked files.
_last_checksum=""
_last_version=""
[[ -f "$PROJECT_ROOT/.config-checksum" ]] && _last_checksum="$(cat "$PROJECT_ROOT/.config-checksum")"
[[ -f "$PROJECT_ROOT/.config-version"  ]] && _last_version="$(cat "$PROJECT_ROOT/.config-version")"

if [[ -n "${AB_IMAGE_VERSION:-}" ]]; then
  IMAGE_VERSION="$AB_IMAGE_VERSION"
elif [[ "${AB_FORCE_NEW_VERSION:-no}" != "yes" \
        && -n "$_last_checksum" && -n "$_last_version" \
        && "$CURRENT_CHECKSUM" == "$_last_checksum" ]]; then
  IMAGE_VERSION="$_last_version"
  echo "==> Reusing IMAGE_VERSION=$IMAGE_VERSION (config unchanged since last build)"
else
  IMAGE_VERSION="$("$PROJECT_ROOT/mkosi.version")"
fi

for target in "${BUILD_TARGETS[@]}"; do
  build_target "${target%%|*}" "${target#*|}"
done

echo "$CURRENT_CHECKSUM" > "$PROJECT_ROOT/.config-checksum"
echo "$IMAGE_VERSION"   > "$PROJECT_ROOT/.config-version"
echo "==> Build complete. Artifacts are in mkosi.output/"
