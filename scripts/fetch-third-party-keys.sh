#!/bin/bash
# scripts/fetch-third-party-keys.sh
#
# Fetches and pins the public signing keys for third-party apt repos
# used by the mkosi build. Each profile that needs a third-party repo
# declares its keys in mkosi.profiles/<name>/apt-keys.conf (one block
# per key, indexed KEY_1_*, KEY_2_*, ...).
#
# This script:
#   1. Iterates every apt-keys.conf under mkosi.profiles/.
#   2. For each declared key, downloads it, verifies its fingerprint
#      against the value pinned in the conf, and installs the
#      dearmored key under
#        mkosi.profiles/<profile>/mkosi.extra/etc/apt/keyrings/<KEY_n_OUT>
#      so the key only gets baked into the image when its profile is
#      selected at build time.
#
# Optional --profile "<list>" limits fetching to a specific subset of
# profiles (build.sh passes the resolved profile union when called as
# part of a normal build). With no --profile flag, every profile that
# has an apt-keys.conf is fetched — that's the right default for
# update-3rd-party-deps.sh which doesn't know which builds will
# eventually use the keys.
#
# Fingerprint mismatches FAIL CLOSED. To rotate a key, edit
# apt-keys.conf with a freshly verified fingerprint and commit.

set -euo pipefail

log()  { printf '[fetch-keys] %s\n'       "$*" >&2; }
fail() { printf '[fetch-keys] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
PROFILES_ROOT="${REPO_ROOT}/mkosi.profiles"

PROFILE_FILTER=""
while (($#)); do
    case "$1" in
        --profile) PROFILE_FILTER="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) fail "unknown arg: $1" ;;
    esac
done

for bin in curl gpg awk; do
    command -v "${bin}" >/dev/null || fail "missing tool: ${bin}"
done

# Profile name validity regex (matches profile-resolver.sh's tighter
# check). Apt-key OUT paths are also checked: must stay under the
# profile's mkosi.extra/ tree, and must not contain '..' segments.
NAME_RE='^[A-Za-z0-9._-]+$'
OUT_RE='^[A-Za-z0-9._/-]+$'

fetch_and_verify() {
    local label="$1" url="$2" expected_fp="$3" out_path="$4"

    local tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" RETURN

    log "fetching ${label} from ${url}"
    curl --fail --silent --show-error --location --max-time 30 \
        --output "${tmp}/raw" "${url}"

    GNUPGHOME="${tmp}/gnupg" install -d -m 700 "${tmp}/gnupg"
    if ! GNUPGHOME="${tmp}/gnupg" gpg --quiet --import "${tmp}/raw" 2>/dev/null; then
        fail "${label}: gpg could not import fetched data"
    fi

    mapfile -t got_fps < <(
        GNUPGHOME="${tmp}/gnupg" gpg --with-colons --fingerprint \
          | awk -F: '$1=="fpr" {print $10}'
    )

    local expected_norm
    expected_norm="$(tr -d '[:space:]' <<<"${expected_fp}" | tr '[:lower:]' '[:upper:]')"

    local matched="no"
    for fp in "${got_fps[@]}"; do
        if [[ "${fp}" == "${expected_norm}" ]]; then
            matched="yes"
            break
        fi
    done

    if [[ "${matched}" != "yes" ]]; then
        printf '[fetch-keys] ERROR: %s fingerprint mismatch.\n' "${label}" >&2
        printf '  expected: %s\n' "${expected_norm}" >&2
        printf '  got:\n' >&2
        printf '    %s\n' "${got_fps[@]}" >&2
        return 1
    fi

    install -d -m 0755 "$(dirname "${out_path}")"
    GNUPGHOME="${tmp}/gnupg" gpg --batch --yes --export "${expected_norm}" >"${out_path}"
    chmod 0644 "${out_path}"
    log "${label}: verified fingerprint ${expected_norm}, installed -> ${out_path}"
}

# Helper: tells whether $1 (a profile name) is in $PROFILE_FILTER.
# When PROFILE_FILTER is empty, every profile passes (the default
# update-3rd-party-deps.sh path).
profile_in_filter() {
    local p="$1"
    [[ -z "${PROFILE_FILTER}" ]] && return 0
    local f
    for f in ${PROFILE_FILTER}; do
        [[ "${f}" == "${p}" ]] && return 0
    done
    return 1
}

# Process one apt-keys.conf file in a subshell so its KEY_n_*
# variables don't leak into our environment between profiles.
process_apt_keys_conf() {
    local profile="$1" conf="$2"
    (
        set -e
        # shellcheck disable=SC1090
        source "${conf}"

        local profile_extra="${PROFILES_ROOT}/${profile}/mkosi.extra"
        install -d -m 0755 "${profile_extra}"

        local i=1
        local errors=0
        while :; do
            local name_var="KEY_${i}_NAME"
            local url_var="KEY_${i}_URL"
            local fp_var="KEY_${i}_FINGERPRINT"
            local out_var="KEY_${i}_OUT"

            if [[ -z "${!name_var:-}" && -z "${!url_var:-}" \
               && -z "${!fp_var:-}" && -z "${!out_var:-}" ]]; then
                break
            fi

            for v in "${name_var}" "${url_var}" "${fp_var}" "${out_var}"; do
                [[ -n "${!v:-}" ]] || fail "${conf}: ${v} is empty (key block ${i} is incomplete)"
            done

            # Profile authors can ship a stub apt-keys.conf with a
            # placeholder fingerprint (REPLACE_ME, REPLACE_TODO, etc.)
            # to mark "this profile WILL need a pinned key, but the
            # author hasn't independently verified one yet." Stubs are
            # logged + skipped here so update-3rd-party-deps.sh stays
            # green; the build only fails when a profile is actually
            # selected and apt-update needs the missing key.
            if [[ "${!fp_var}" == REPLACE_* ]]; then
                log "SKIP ${profile}/${!name_var}: fingerprint is a placeholder (${!fp_var}). Pin a verified fingerprint before enabling this profile."
                unset "${name_var}" "${url_var}" "${fp_var}" "${out_var}"
                i=$((i+1))
                continue
            fi

            local out_path="${!out_var}"
            if [[ ! "${out_path}" =~ ${OUT_RE} ]] || [[ "${out_path}" == /* ]] \
               || [[ "${out_path}" == *..* ]]; then
                fail "${conf}: invalid KEY_${i}_OUT='${out_path}' (must be a relative path under mkosi.extra/, no ..)"
            fi

            local full_out="${profile_extra}/${out_path}"
            fetch_and_verify "${profile}/${!name_var}" "${!url_var}" "${!fp_var}" "${full_out}" \
                || errors=$((errors+1))

            unset "${name_var}" "${url_var}" "${fp_var}" "${out_var}"
            i=$((i+1))
        done

        if (( errors > 0 )); then
            exit 1
        fi
        if (( i == 1 )); then
            log "${conf}: no KEY_1_* block found (file present but empty?)"
        fi
    )
}

processed=0
errors=0
shopt -s nullglob
for conf in "${PROFILES_ROOT}"/*/apt-keys.conf; do
    profile="$(basename "$(dirname "${conf}")")"
    if [[ ! "${profile}" =~ ${NAME_RE} ]]; then
        log "skipping ${conf}: profile name '${profile}' fails name regex"
        continue
    fi
    if ! profile_in_filter "${profile}"; then
        continue
    fi
    log "processing ${profile} (${conf})"
    if ! process_apt_keys_conf "${profile}" "${conf}"; then
        errors=$((errors+1))
    fi
    processed=$((processed+1))
done
shopt -u nullglob

if (( errors > 0 )); then
    fail "${errors} profile(s) failed key fetch."
fi

if [[ -n "${PROFILE_FILTER}" && "${processed}" == 0 ]]; then
    log "no apt-keys.conf matched --profile filter; nothing to fetch."
fi

log "done (${processed} profile(s) processed)."
