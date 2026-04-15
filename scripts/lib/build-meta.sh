#!/usr/bin/env bash

ab_buildmeta_safe_component() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    printf '%s\n' 'none'
    return 0
  fi
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_'
}

ab_buildmeta_file() {
  local project_root="$1"
  printf '%s\n' "$project_root/mkosi.output/.latest-build.env"
}

ab_buildmeta_file_for() {
  local project_root="$1"
  local profile host
  profile="$(ab_buildmeta_safe_component "${2:-}")"
  host="$(ab_buildmeta_safe_component "${3:-}")"
  printf '%s\n' "$project_root/mkosi.output/.latest-build.${profile}.${host}.env"
}

ab_buildmeta_write_path() {
  local path="$1"
  shift
  local dir tmp
  dir="$(dirname "$path")"
  install -d -m 0755 "$dir"
  tmp="$(mktemp "$dir/.latest-build.XXXXXX")"
  : > "$tmp"
  while [[ $# -gt 0 ]]; do
    printf '%s=%q\n' "$1" "${2-}" >> "$tmp"
    shift 2
  done
  chmod 0644 "$tmp"
  mv "$tmp" "$path"
}

ab_buildmeta_write() {
  local project_root="$1"
  shift
  ab_buildmeta_write_path "$(ab_buildmeta_file "$project_root")" "$@"
}

ab_buildmeta_write_for() {
  local project_root="$1"
  local profile="$2"
  local host="$3"
  shift 3
  ab_buildmeta_write_path "$(ab_buildmeta_file_for "$project_root" "$profile" "$host")" "$@"
}

ab_buildmeta_load_path() {
  local path="$1"
  [[ -r "$path" ]] || return 1
  # shellcheck disable=SC1090
  . "$path"
}

ab_buildmeta_load() {
  local project_root="$1"
  ab_buildmeta_load_path "$(ab_buildmeta_file "$project_root")"
}

ab_buildmeta_load_for() {
  local project_root="$1"
  local profile="$2"
  local host="$3"
  ab_buildmeta_load_path "$(ab_buildmeta_file_for "$project_root" "$profile" "$host")"
}
