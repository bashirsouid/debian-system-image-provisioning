#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"

FRESH=false

usage() {
  cat <<'USAGE'
Usage: ./update-3rd-party-deps.sh [--fresh]

  --fresh  remove managed third-party checkouts and clone them again
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh)
      FRESH=true
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

if ! ab_hostdeps_have_all_commands git; then
  ab_hostdeps_ensure_packages "third-party source update prerequisites" git || exit 1
fi
ab_hostdeps_ensure_commands "third-party source update prerequisites" git || exit 1

repo_is_dirty() {
  local path="$1"
  [[ -d "$path/.git" ]] || return 1
  [[ -n "$(git -C "$path" status --porcelain --untracked-files=all 2>/dev/null || true)" ]]
}

update_git_repo() {
  local name="$1"
  local url="$2"

  echo "==> Checking ${name} source..."

  if [[ "$FRESH" == true && -d "$name" ]]; then
    echo "==> Removing existing ${name} checkout for a clean refresh..."
    rm -rf "$name"
  fi

  if [[ -d "$name/.git" ]]; then
    if repo_is_dirty "$name"; then
      echo "ERROR: third-party/$name has local changes or untracked files." >&2
      echo "Top-level 'git status' can still look clean because third-party/ is ignored." >&2
      echo "Run './update-3rd-party-deps.sh --fresh' to reset the managed checkout." >&2
      exit 1
    fi

    echo "==> Updating existing ${name} repository..."
    git -C "$name" pull --ff-only
  else
    echo "==> Cloning ${name} repository..."
    git clone --depth 1 "$url" "$name"
  fi
}

cd "$PROJECT_ROOT"
mkdir -p third-party
cd third-party

update_git_repo awesome https://github.com/awesomewm/awesome.git
update_git_repo snd_hda_macbookpro https://github.com/davidjo/snd_hda_macbookpro.git

echo "==> Fetching third-party GPG keys..."
"$PROJECT_ROOT/scripts/fetch-third-party-keys.sh"

echo "==> Third-party dependencies are up to date."
