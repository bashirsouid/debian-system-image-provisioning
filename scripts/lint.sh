#!/bin/bash
# scripts/lint.sh
#
# Runs shellcheck on every shell script in the repo. Fails on any
# finding. Intended to be called from CI and from pre-commit.
#
# Usage:
#   ./scripts/lint.sh            # lint everything
#   ./scripts/lint.sh --changed  # only files changed vs origin/main

set -euo pipefail

log()  { printf '[lint] %s\n'       "$*" >&2; }
fail() { printf '[lint] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${REPO_ROOT}"

if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck is not installed. Run: sudo apt-get install --no-install-recommends shellcheck"
fi

mode="all"
if [[ "${1:-}" == "--changed" ]]; then
    mode="changed"
fi

targets=()

collect_all() {
    # Every *.sh file, plus top-level build.sh / run.sh / clean.sh etc.
    while IFS= read -r f; do
        targets+=("$f")
    done < <(find . -type f \( -name '*.sh' -o -name 'mkosi.build' -o -name 'mkosi.prepare' -o -name 'mkosi.finalize' \) \
                    -not -path './.git/*' \
                    -not -path './mkosi.cache/*' \
                    -not -path './mkosi.builddir/*' \
                    -not -path './mkosi.output/*' \
                    -not -path './.shellcheck-cache/*' \
                    | sort)
}

collect_changed() {
    local base
    base="$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse HEAD~1)"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *.sh|mkosi.build|mkosi.prepare|mkosi.finalize) targets+=("$f") ;;
        esac
    done < <(git diff --name-only "${base}" -- .)
}

case "${mode}" in
    all)     collect_all ;;
    changed) collect_changed ;;
esac

if (( ${#targets[@]} == 0 )); then
    log "no shell files to lint."
    exit 0
fi

log "linting ${#targets[@]} files (mode=${mode})"

# -S style so we also catch style issues, not just errors.
# -x so shellcheck follows sourced files.
# --shell=bash because the scripts use bash-isms intentionally.
# --rcfile picks up repo-level .shellcheckrc which silences scoped issues.
if shellcheck -S style -x --shell=bash --color=auto "${targets[@]}"; then
    log "no findings."
    exit 0
else
    fail "shellcheck reported findings above."
fi
