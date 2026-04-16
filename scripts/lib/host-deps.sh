#!/usr/bin/env bash

ab_hostdeps_normalize_path() {
  local dir
  for dir in /usr/local/sbin /usr/sbin /sbin /usr/lib/systemd /lib/systemd; do
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) PATH="$PATH:$dir" ;;
    esac
  done
  export PATH
}

ab_hostdeps_normalize_path

ab_hostdeps_log() {
  echo "==> $*" >&2
}

ab_hostdeps_die() {
  echo "ERROR: $*" >&2
  return 1
}

ab_hostdeps_truthy() {
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

ab_hostdeps_auto_install_enabled() {
  case "${AB_AUTO_INSTALL_DEPS:-yes}" in
    0|no|false|off) return 1 ;;
    *) return 0 ;;
  esac
}

ab_hostdeps_resolve_command() {

  local cmd="$1"
  local candidate

  if command -v "$cmd" >/dev/null 2>&1; then
    command -v "$cmd"
    return 0
  fi

  for candidate in \
    "/usr/bin/$cmd" \
    "/usr/sbin/$cmd" \
    "/usr/lib/systemd/$cmd" \
    "/lib/systemd/$cmd"
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ab_hostdeps_have_package_installed() {

  local pkg="$1"
  local status

  if ! ab_hostdeps_is_debian_like || ! command -v dpkg-query >/dev/null 2>&1; then
    return 1
  fi

  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  [[ "$status" == "install ok installed" ]]
}

ab_hostdeps_have_all_commands() {
  local cmd
  for cmd in "$@"; do
    ab_hostdeps_resolve_command "$cmd" >/dev/null 2>&1 || return 1
  done
  return 0
}

ab_hostdeps_is_debian_like() {
  local id="" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    like=" ${ID_LIKE:-} "
  fi

  [[ "$id" == "debian" || "$id" == "ubuntu" || "$like" == *" debian "* ]]
}

ab_hostdeps_manual_install_hint() {
  local packages=("$@")
  if ab_hostdeps_is_debian_like && command -v apt-get >/dev/null 2>&1; then
    printf 'sudo apt-get install -y --no-install-recommends'
    local pkg
    for pkg in "${packages[@]}"; do
      printf ' %q' "$pkg"
    done
    printf '\n'
    return 0
  fi

  printf 'install the required host packages:'
  local pkg
  for pkg in "${packages[@]}"; do
    printf ' %q' "$pkg"
  done
  printf '\n'
}

ab_hostdeps_dedup_packages() {
  local pkg
  declare -A seen=()
  for pkg in "$@"; do
    [[ -n "$pkg" ]] || continue
    if [[ -z "${seen[$pkg]:-}" ]]; then
      seen[$pkg]=1
      printf '%s\n' "$pkg"
    fi
  done
}

ab_hostdeps_install_packages() {
  local context="$1"
  shift

  local packages=()
  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && packages+=("$pkg")
  done < <(ab_hostdeps_dedup_packages "$@")

  [[ ${#packages[@]} -gt 0 ]] || return 0

  if ! ab_hostdeps_auto_install_enabled; then
    ab_hostdeps_log "$context: automatic host dependency installation is disabled (AB_AUTO_INSTALL_DEPS=no)"
    ab_hostdeps_manual_install_hint "${packages[@]}" >&2
    return 1
  fi

  if ! ab_hostdeps_is_debian_like || ! command -v apt-get >/dev/null 2>&1; then
    ab_hostdeps_log "$context: automatic host dependency installation is only implemented for Debian/Ubuntu apt-based hosts"
    ab_hostdeps_manual_install_hint "${packages[@]}" >&2
    return 1
  fi

  local runner=()
  if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then
      runner=(sudo)
    else
      ab_hostdeps_log "$context: sudo is required to auto-install host packages when not running as root"
      ab_hostdeps_manual_install_hint "${packages[@]}" >&2
      return 1
    fi
  fi

  ab_hostdeps_log "$context: installing missing host packages: ${packages[*]}"
  if [[ -z "${AB_HOST_DEPS_APT_UPDATED:-}" ]]; then
    "${runner[@]}" apt-get update
    AB_HOST_DEPS_APT_UPDATED=1
  fi
  "${runner[@]}" apt-get install -y --no-install-recommends "${packages[@]}"
}

ab_hostdeps_ensure_packages() {
  local context="$1"
  shift

  local requested=()
  local missing=()
  local pkg status
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && requested+=("$pkg")
  done < <(ab_hostdeps_dedup_packages "$@")

  [[ ${#requested[@]} -gt 0 ]] || return 0

  if ab_hostdeps_is_debian_like && command -v dpkg-query >/dev/null 2>&1; then
    for pkg in "${requested[@]}"; do
      status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
      [[ "$status" == "install ok installed" ]] || missing+=("$pkg")
    done
  else
    missing=("${requested[@]}")
  fi

  [[ ${#missing[@]} -gt 0 ]] || return 0
  ab_hostdeps_install_packages "$context" "${missing[@]}"
}

ab_hostdeps_ensure_commands() {
  local context="$1"
  shift

  local missing=()
  local cmd
  for cmd in "$@"; do
    ab_hostdeps_resolve_command "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    ab_hostdeps_log "$context: missing required commands: ${missing[*]}"

    if [[ " ${missing[*]} " == *" systemd-sysupdate "* ]] && ab_hostdeps_have_package_installed systemd-container; then
      ab_hostdeps_log "$context: systemd-container is installed but systemd-sysupdate is still unavailable."
      ab_hostdeps_log "$context: this usually means the host systemd stack is older than the native sysupdate workflow expects, or the binary lives outside the default PATH."
    fi

    return 1
  fi

  return 0
}
