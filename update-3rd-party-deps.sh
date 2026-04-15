#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"

if ! ab_hostdeps_have_all_commands git; then
  ab_hostdeps_ensure_packages "third-party source update prerequisites" git || exit 1
fi
ab_hostdeps_ensure_commands "third-party source update prerequisites" git || exit 1

cd "$PROJECT_ROOT"
mkdir -p third-party
cd third-party

echo "==> Checking AwesomeWM source..."
if [ -d "awesome/.git" ]; then
    echo "==> Updating existing AwesomeWM repository..."
    cd awesome
    git pull
else
    echo "==> Cloning AwesomeWM repository..."
    git clone --depth 1 https://github.com/awesomewm/awesome.git
fi

echo "==> Third-party dependencies are up to date."
