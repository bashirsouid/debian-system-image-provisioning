#!/usr/bin/env bash
# Shared library for mkosi finalize scripts.
# Sourced by scripts in mkosi.finalize.d/ and profile-specific finalize scripts.

# The BUILDROOT environment variable is provided by mkosi
ROOT="${BUILDROOT:?BUILDROOT is required}"
BUILD_INFO="$ROOT/usr/local/share/ab-image-meta/build-info.env"
OS_RELEASE="$ROOT/usr/lib/os-release"

# Quote a value for os-release(5). Plain tokens stay unquoted; anything
# else gets the four shell-special characters escaped per the spec and is
# wrapped in double quotes. The previous version used printf '%q' which
# produces shell quoting (e.g. "foo\ bar"), NOT os-release quoting, and
# breaks spec-compliant parsers on any value containing whitespace or
# shell metacharacters.
os_release_quote() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z0-9._:/+-]*$ ]]; then
    printf '%s' "$value"
    return
  fi
  local escaped="$value"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  escaped="${escaped//\$/\\\$}"
  escaped="${escaped//\`/\\\`}"
  printf '"%s"' "$escaped"
}

enable_target_unit() {
  local target_name="$1"
  local unit_name="$2"
  local target_dir="$ROOT/etc/systemd/system/$target_name.wants"
  local unit_source="$ROOT/usr/lib/systemd/system/$unit_name"
  local unit_target="/usr/lib/systemd/system/$unit_name"
  local unit_link="$target_dir/$unit_name"

  # Refuse to create a dangling symlink. If the expected unit is missing
  # from the image, the finalize step should fail the build rather than
  # silently ship an image where first-boot provisioning never runs.
  if [[ ! -f "$unit_source" ]]; then
    echo "ERROR: [FINALIZE] cannot enable $unit_name in $target_name: $unit_source is missing from the image" >&2
    exit 1
  fi

  mkdir -p "$target_dir"
  ln -snf "$unit_target" "$unit_link"
}

append_or_replace_os_release_key() {
  local key="$1"
  local value="$2"
  local tmp quoted
  [[ -f "$OS_RELEASE" ]] || return 0
  quoted="$(os_release_quote "$value")"
  tmp="$(mktemp)"
  awk -F= -v key="$key" '$1 != key { print }' "$OS_RELEASE" > "$tmp"
  printf '%s=%s\n' "$key" "$quoted" >> "$tmp"
  mv "$tmp" "$OS_RELEASE"
}

load_build_info() {
  [[ -f "$BUILD_INFO" ]] || return 0
  # shellcheck disable=SC1090
  source "$BUILD_INFO"
}
