#!/usr/bin/env bash
# scripts/lint.sh
#
# Runs shellcheck on the shell scripts this overlay owns. Deliberately
# scoped so CI is not held hostage by findings in pre-existing scripts.
#
# Usage:
#   ./scripts/lint.sh           # overlay-owned files only (default, used by build.sh + CI)
#   ./scripts/lint.sh --all     # every *.sh in the repo (strict; informational)

set -euo pipefail

log()  { printf '[lint] %s\n'        "$*" >&2; }
fail() { printf '[lint] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${REPO_ROOT}"

command -v shellcheck >/dev/null 2>&1 \
    || fail "shellcheck is not installed. Run: sudo apt-get install --no-install-recommends shellcheck"

mode="overlay"
if [[ "${1:-}" == "--all" ]]; then
    mode="all"
fi

# Files this overlay introduced. If you add a new script under scripts/
# that is part of the overlay, add its basename here.
OVERLAY_SCRIPTS_WE_OWN=(
    scripts/lint.sh
    scripts/verify-build-secrets.sh
    scripts/package-credentials.sh
    scripts/package-alert-credentials.sh
    scripts/hash-password.sh
    scripts/usb-write-and-verify.sh
    scripts/verify-image-raw.sh
    scripts/fetch-third-party-keys.sh
)

declare -a targets=()

case "${mode}" in
    overlay)
        for f in "${OVERLAY_SCRIPTS_WE_OWN[@]}"; do
            [[ -f "$f" ]] && targets+=("$f")
        done

        # Everything under mkosi.extra/usr/local with a bash/sh shebang.
        # That is all overlay-owned by construction.
        if [[ -d mkosi.extra/usr/local ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                first="$(head -c 25 "$f" 2>/dev/null || true)"
                case "$first" in
                    '#!/bin/bash'*|'#!/bin/sh'*|'#!/usr/bin/env bash'*|'#!/usr/bin/env sh'*)
                        targets+=("$f")
                        ;;
                esac
            done < <(find mkosi.extra/usr/local -type f -not -name '*.bak*' 2>/dev/null | sort)
        fi
        ;;
    all)
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            first="$(head -c 25 "$f" 2>/dev/null || true)"
            case "$first" in
                '#!/bin/bash'*|'#!/bin/sh'*|'#!/usr/bin/env bash'*|'#!/usr/bin/env sh'*)
                    targets+=("$f")
                    ;;
            esac
        done < <(find . -type f \( -name '*.sh' -o -name 'mkosi.build' -o -name 'mkosi.prepare' -o -name 'mkosi.finalize' \) \
                        -not -path './.git/*' \
                        -not -path './mkosi.cache/*' \
                        -not -path './mkosi.builddir/*' \
                        -not -path './mkosi.output/*' \
                        -not -path './third-party/*' \
                        -not -path './.mkosi-thirdparty/*' \
                        -not -path './.mkosi-secrets/*' \
                        -not -name '*.bak.*' \
                        | sort)
        ;;
esac

if (( ${#targets[@]} == 0 )); then
    log "no shell files to lint (mode=${mode})"
    exit 0
fi

log "linting ${#targets[@]} files (mode=${mode})"

# --severity=warning so info/style findings do not gate CI.
# -x so sourced files are followed when shellcheck can resolve them.
if shellcheck --severity=warning -x --shell=bash "${targets[@]}"; then
    log "no findings."
    exit 0
else
    fail "shellcheck reported findings above."
fi
