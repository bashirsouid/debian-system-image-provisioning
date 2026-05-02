#!/usr/bin/env bash
#
# Build metadata / layout helpers.
#
# Layout committed by this file:
#
#   mkosi.output/                       # mkosi's live scratch. Kept empty
#                                       # between builds except while a build
#                                       # is in progress; build.sh moves the
#                                       # finished artifacts into builds/
#                                       # once export-sysupdate-artifacts has
#                                       # run, so two builds never share a
#                                       # flat filename namespace.
#     builds/
#       <ts>__<profile>[__<host>]/      # one directory per build, where
#         <image_id>_<ver>.raw          # <ts> is a UTC timestamp recorded at
#         <image_id>_<ver>.initrd       # staging time (NOT the image
#         <image_id>_<ver>.vmlinuz      # version, which can be reused from
#         <image_id>_<ver>_<arch>.root.raw    # .config-version when config
#         <image_id>_<ver>_<arch>.efi         # is unchanged).
#         <image_id>_<ver>_<arch>.conf
#         <image_id>_<ver>_<arch>.artifacts.env
#         SHA256SUMS                    # scoped to this build only.
#         build.env                     # self-contained AB_LAST_BUILD_* env.
#       latest -> <ts>__...             # always newest build of anything.
#       latest-<host> -> <ts>__...      # newest build targeting that host.
#       latest-<profile> -> <ts>__...   # newest build of that profile with
#                                       # no host (QEMU smoke tests).
#
# Downstream tools (ab-install, test-rollback,
# run.sh) never read anything outside a single build folder — once a folder
# is resolved, everything needed to flash / boot / rollback-test that build
# is inside it.

ab_buildmeta_safe_component() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    printf '%s\n' 'none'
    return 0
  fi
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_'
}

ab_buildmeta_timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

ab_buildmeta_builds_dir() {
  local project_root="$1"
  printf '%s\n' "$project_root/mkosi.output/builds"
}

# Compose the per-build folder name. When --host is set, the folder is
# just <ts>__<host>: a host's profile.default can be a dozen profiles
# long, and joining them all into the folder name produced unwieldy
# paths like 20260501T123456Z__macbook_awesomewm_wifi_..._vscode__macbookpro13.
# The build.env inside the folder still records AB_LAST_BUILD_PROFILE
# verbatim, so the picker and downstream tools can show the full
# profile list without it leaking into the path. When no host is set
# (QEMU smoke tests), profile is the only identity available, so the
# folder falls back to <ts>__<profile>.
ab_buildmeta_folder_name() {
  local timestamp="$1"
  local profile="${2:-}"
  local host="${3:-}"
  local safe
  if [[ -n "$host" ]]; then
    safe="$(ab_buildmeta_safe_component "$host")"
  else
    safe="$(ab_buildmeta_safe_component "$profile")"
  fi
  printf '%s__%s\n' "$timestamp" "$safe"
}

ab_buildmeta_stage_dir() {
  local project_root="$1"
  local timestamp="$2"
  local profile="${3:-}"
  local host="${4:-}"
  local name
  name="$(ab_buildmeta_folder_name "$timestamp" "$profile" "$host")"
  printf '%s/%s\n' "$(ab_buildmeta_builds_dir "$project_root")" "$name"
}

# Write <folder>/build.env with alternating key/value pairs. Uses %q so the
# file is safe to `source`.
ab_buildmeta_write_env() {
  local folder="$1"
  shift
  local tmp
  install -d -m 0755 "$folder"
  tmp="$(mktemp "$folder/.build.env.XXXXXX")"
  : > "$tmp"
  while [[ $# -gt 0 ]]; do
    printf '%s=%q\n' "$1" "${2-}" >> "$tmp"
    shift 2
  done
  chmod 0644 "$tmp"
  mv "$tmp" "$folder/build.env"
}

# Source <folder>/build.env into the caller's environment. Also sets
# AB_BUILD_DIR to the folder so downstream code has a single handle.
ab_buildmeta_load_env() {
  local folder="$1"
  [[ -n "$folder" ]] || return 1
  [[ -r "$folder/build.env" ]] || return 1
  # shellcheck disable=SC1091
  . "$folder/build.env"
  AB_BUILD_DIR="$folder"
  export AB_BUILD_DIR
}

# Repoint latest-* symlinks at the newest build folder. Symlinks are
# relative so the builds/ tree can be moved or copied without breaking.
# Called exactly once per successful build, after build.env has been
# written into the folder.
ab_buildmeta_update_latest_symlinks() {
  local project_root="$1"
  local folder="$2"
  local profile="${3:-}"
  local host="${4:-}"
  local builds_dir base_name
  builds_dir="$(ab_buildmeta_builds_dir "$project_root")"
  base_name="$(basename "$folder")"

  install -d -m 0755 "$builds_dir"
  ln -sfn "$base_name" "$builds_dir/latest"
  if [[ -n "$host" ]]; then
    ln -sfn "$base_name" "$builds_dir/latest-$(ab_buildmeta_safe_component "$host")"
  elif [[ -n "$profile" ]]; then
    ln -sfn "$base_name" "$builds_dir/latest-$(ab_buildmeta_safe_component "$profile")"
  fi
}

# Read hosts/<host>/profile.default. Prints the profile name on stdout, or
# nothing if the file is absent, empty, or malformed. Never exits non-zero
# on "file absent" — callers use the empty output as the signal to fall
# back to their own default.
ab_buildmeta_host_default_profile() {
  local project_root="$1"
  local host="$2"
  local path value
  [[ -n "$host" ]] || return 0
  path="$project_root/hosts/$host/profile.default"
  [[ -f "$path" ]] || return 0
  # Read all non-comment tokens from the file.
  sed -e 's/[[:space:]]*#.*$//' "$path" | xargs echo -n
}

# Resolve the build folder that matches the caller's intent.
#   profile='' host='X' -> builds/latest-X
#   profile='Y' host='' -> builds/latest-Y
#   profile='Y' host='X' -> builds/latest-X (host wins; it's the more
#                            specific identity, and in practice a given
#                            host has one built profile at a time)
#   profile='' host=''  -> builds/latest
#
# Returns the resolved (symlink-dereferenced) absolute folder path on
# stdout and 0 on success; returns 1 with no output if no symlink matches
# or the symlink target does not exist. Callers then emit their own
# "run ./build.sh first" error.
ab_buildmeta_resolve_build_dir() {
  local project_root="$1"
  local profile="${2:-}"
  local host="${3:-}"
  local builds_dir link target
  builds_dir="$(ab_buildmeta_builds_dir "$project_root")"
  [[ -d "$builds_dir" ]] || return 1

  if [[ -n "$host" ]]; then
    link="$builds_dir/latest-$(ab_buildmeta_safe_component "$host")"
  elif [[ -n "$profile" ]]; then
    link="$builds_dir/latest-$(ab_buildmeta_safe_component "$profile")"
  else
    link="$builds_dir/latest"
  fi

  [[ -L "$link" || -d "$link" ]] || return 1
  target="$(readlink -f "$link" 2>/dev/null || true)"
  [[ -n "$target" && -d "$target" ]] || return 1
  printf '%s\n' "$target"
}

# Print the absolute paths of every build folder under builds/, newest
# first. Symlinks (latest, latest-*) are skipped because they're not
# builds in their own right. Empty output (and exit 0) when no builds
# exist; callers fall back to "run ./build.sh first" themselves.
ab_buildmeta_enumerate_builds() {
  local project_root="$1"
  local builds_dir entry
  builds_dir="$(ab_buildmeta_builds_dir "$project_root")"
  [[ -d "$builds_dir" ]] || return 0

  # The folder name starts with a UTC timestamp (YYYYMMDDTHHMMSSZ) so
  # lex-sorting newest-first === sorting by build time newest-first,
  # without having to stat() each entry. Using a glob keeps this
  # bash-3.2-portable (no `mapfile`, no `find -printf`).
  local matches=()
  shopt -s nullglob
  matches=("$builds_dir"/*/)
  shopt -u nullglob

  # Sort folder names descending. `printf '%s\n'` + `sort -r` is portable;
  # bash's `sort` doesn't have a portable in-place mode.
  local sorted
  sorted="$(printf '%s\n' "${matches[@]}" | sed 's:/$::' | sort -r)"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    # Skip the latest* convenience symlinks; they point at a real build
    # folder which already appears in the list.
    [[ -L "$entry" ]] && continue
    [[ -f "$entry/build.env" ]] || continue
    printf '%s\n' "$entry"
  done <<<"$sorted"
}

# Print one human-readable line per build (index + metadata), suitable
# for showing in a picker. Reads build.env in a subshell so caller env
# is not polluted by AB_LAST_BUILD_* values from arbitrary builds.
ab_buildmeta_format_builds_table() {
  local project_root="$1"
  local idx=0 build label
  while IFS= read -r build; do
    idx=$((idx + 1))
    label="$(
      AB_LAST_BUILD_PROFILE=""
      AB_LAST_BUILD_HOST=""
      AB_LAST_BUILD_IMAGE_VERSION=""
      # shellcheck disable=SC1091
      . "$build/build.env" 2>/dev/null || true
      printf '%-20s  host=%-22s  ver=%s' \
        "${AB_LAST_BUILD_PROFILE:-?}" \
        "${AB_LAST_BUILD_HOST:-none}" \
        "${AB_LAST_BUILD_IMAGE_VERSION:-?}"
    )"
    printf '  [%d] %s\n      %s\n' "$idx" "$label" "$(basename "$build")"
  done < <(ab_buildmeta_enumerate_builds "$project_root")
}

# Interactive picker. Lists every build, prompts on stderr, prints the
# selected absolute folder path on stdout. Default on bare-Enter is the
# newest build (matches existing `latest` symlink behavior). Returns
# non-zero when stdin is not a TTY, when there are no builds, or when
# the user types something un-parseable.
#
# Caller is expected to short-circuit this when the user already passed
# --build-dir / --host / --profile; the picker is *only* the no-flag
# path.
ab_buildmeta_pick_build_interactive() {
  local project_root="$1"
  local builds=() build choice idx
  while IFS= read -r build; do
    [[ -n "$build" ]] && builds+=("$build")
  done < <(ab_buildmeta_enumerate_builds "$project_root")

  (( ${#builds[@]} > 0 )) || return 1
  [[ -t 0 && -t 2 ]] || return 1

  echo "Available builds (newest first):" >&2
  ab_buildmeta_format_builds_table "$project_root" >&2
  echo >&2
  printf 'Pick a build [1-%d, Enter = 1 (latest), q = abort]: ' "${#builds[@]}" >&2
  if ! IFS= read -r choice; then
    return 1
  fi

  case "$choice" in
    ""|"1") printf '%s\n' "${builds[0]}"; return 0 ;;
    q|Q) return 1 ;;
  esac
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    idx=$((choice - 1))
    if (( idx >= 0 && idx < ${#builds[@]} )); then
      printf '%s\n' "${builds[$idx]}"
      return 0
    fi
  fi
  echo "ERROR: invalid choice: $choice" >&2
  return 1
}
