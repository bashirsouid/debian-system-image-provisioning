#!/bin/bash
# scripts/package-alert-credentials.sh
#
# Encrypts the three alerting-stack secrets into
# mkosi.extra/etc/credstore.encrypted/ using the same per-image key
# as scripts/package-credentials.sh. Call AFTER that script so the
# per-image credential.secret is already in place.
#
# Expected inputs under .mkosi-secrets/:
#   sendgrid-api-key       (starts with SG. )
#   pagerduty-routing-key  (32-char integration key from a PD service)
#   healthchecks-ping-url  (https://hc-ping.com/<uuid> or your private HC instance)
#
# If any are missing we WARN and skip, but do not fail the build.
# That way a host can opt out of an individual channel without
# blocking everything else. To make a channel required for a given
# host, set AB_REQUIRE_SENDGRID=yes / AB_REQUIRE_PAGERDUTY=yes /
# AB_REQUIRE_HEALTHCHECKS=yes in the environment.

set -euo pipefail

log()  { printf '[package-alerts] %s\n'       "$*" >&2; }
warn() { printf '[package-alerts] WARN: %s\n' "$*" >&2; }
fail() { printf '[package-alerts] ERROR: %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.mkosi-secrets"
EXTRA_DIR="${REPO_ROOT}/mkosi.extra"
HOST="${1:-}"
[[ "${HOST}" == "--host" ]] && { HOST="$2"; shift 2; } || HOST=""
# Resolved profile list. healthchecks-ping-url is gated on the
# healthchecksio profile; sendgrid + pagerduty stay always-optional
# because the always-on ab-monitor-alert@.service template loads them
# regardless of which profiles are selected.
PROFILES=""
while (($#)); do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --profile) PROFILES="$2"; shift 2 ;;
        --out) EXTRA_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

profile_selected() {
    local target="$1"
    [[ -z "${PROFILES}" ]] && return 0
    local p
    for p in ${PROFILES}; do
        [[ "${p}" == "${target}" ]] && return 0
    done
    return 1
}

CREDSTORE="${EXTRA_DIR}/etc/credstore"

[[ -d "${SECRETS_DIR}" ]] || fail "${SECRETS_DIR} missing"

mkdir -p "${CREDSTORE}"

resolve_secret() {
    local name="$1"
    if [[ -n "${HOST}" && -f "${SECRETS_DIR}/hosts/${HOST}/${name}" ]]; then
        printf '%s' "${SECRETS_DIR}/hosts/${HOST}/${name}"; return 0
    fi
    [[ -f "${SECRETS_DIR}/${name}" ]] && { printf '%s' "${SECRETS_DIR}/${name}"; return 0; }
    return 1
}

encrypt_one() {
    local name="$1" required_var="$2" validator="$3"

    local path
    if ! path="$(resolve_secret "${name}")"; then
        if [[ "${!required_var:-no}" == "yes" ]]; then
            fail "${name} missing and ${required_var}=yes"
        fi
        warn "${name} not found under ${SECRETS_DIR}; skipping (channel disabled for this image)"
        return 0
    fi

    # Permission check
    local mode
    mode="$(stat -c '%a' "${path}")"
    case "${mode}" in
        400|440|600|640) : ;;
        *) fail "${path} has permissions ${mode}; expected 0400/0440/0600/0640" ;;
    esac

    # Run the format validator. The validator MUST exit 0 for valid
    # input, non-zero otherwise. We pipe the file in so we never
    # echo it.
    if ! ${validator} <"${path}"; then
        fail "${path} failed format validation for ${name}"
    fi

    log "packaging plaintext credential ${name} -> ${CREDSTORE}/${name}"
    install -m 0600 "${path}" "${CREDSTORE}/${name}"
}

# Validators: read from stdin, exit 0 on OK, non-zero otherwise.
# They MUST NOT echo the input.
validate_sendgrid() {
    local content; content="$(cat)"
    # SendGrid API keys start with "SG." and are ~69 characters.
    [[ "${content}" == SG.* ]] || { echo "  sendgrid key does not start with SG." >&2; return 1; }
    (( ${#content} >= 40 )) || { echo "  sendgrid key too short" >&2; return 1; }
    return 0
}

validate_pagerduty() {
    local content; content="$(cat)"
    content="${content%$'\n'}"
    # PagerDuty integration keys are 32 hex chars.
    if [[ ! "${content}" =~ ^[A-Za-z0-9]{32}$ ]]; then
        echo "  pagerduty integration key expected to be 32 alphanumeric chars" >&2
        return 1
    fi
    return 0
}

validate_healthchecks() {
    local content; content="$(cat)"
    content="${content%$'\n'}"
    case "${content}" in
        https://hc-ping.com/*|https://*/ping/*) return 0 ;;
        *)
            echo "  healthchecks URL should look like https://hc-ping.com/<uuid>" >&2
            return 1
            ;;
    esac
}

encrypt_one sendgrid-api-key       AB_REQUIRE_SENDGRID     validate_sendgrid
encrypt_one pagerduty-routing-key  AB_REQUIRE_PAGERDUTY    validate_pagerduty
if profile_selected healthchecksio; then
    encrypt_one healthchecks-ping-url  AB_REQUIRE_HEALTHCHECKS validate_healthchecks
else
    log "healthchecksio profile not selected; skipping healthchecks-ping-url packaging"
fi

log "alert credentials packaged."
