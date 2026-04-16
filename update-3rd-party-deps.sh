#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"

if ! ab_hostdeps_have_all_commands git; then
  ab_hostdeps_ensure_packages "third-party source update prerequisites" git || exit 1
fi
ab_hostdeps_ensure_commands "third-party source update prerequisites" git || exit 1

update_git_repo() {
    local name="$1"
    local url="$2"

    echo "==> Checking ${name} source..."
    if [ -d "$name/.git" ]; then
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

echo "==> Third-party dependencies are up to date."
