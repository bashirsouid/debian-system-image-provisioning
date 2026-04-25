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
# Downstream tools (write-live-test-usb, test-rollback, bootstrap-ab-disk,
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

# Compose the per-build folder name. Profile is always included so that two
# builds of the same host with different profiles never collide. Host is
# omitted when empty (QEMU smoke tests).
ab_buildmeta_folder_name() {
  local timestamp="$1"
  local profile safe_profile safe_host host
  profile="${2:-}"
  host="${3:-}"
  safe_profile="$(ab_buildmeta_safe_component "$profile")"
  if [[ -n "$host" ]]; then
    safe_host="$(ab_buildmeta_safe_component "$host")"
    printf '%s__%s__%s\n' "$timestamp" "$safe_profile" "$safe_host"
  else
    printf '%s__%s\n' "$timestamp" "$safe_profile"
  fi
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
