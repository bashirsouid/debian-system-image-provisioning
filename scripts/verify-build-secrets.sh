#!/usr/bin/env bash
# scripts/verify-build-secrets.sh
#
# Validates what is present in .mkosi-secrets/ on the build host.
#
# Only ONE secret is required for a usable image:
#   * ssh-authorized-keys   (otherwise you cannot log in)
#
# Everything else is optional. When present, it is validated. When
# absent, we emit a WARN line and set the feature to "skipped" for
# this build. At the end we print a summary.
#
# Exits non-zero only when:
#   * ssh-authorized-keys is missing or malformed
#   * an OPTIONAL secret is PRESENT but MALFORMED
#   * host-required tools are missing
#
# Pass --strict to additionally require sk-* hardware-backed SSH keys.

set -euo pipefail

STRICT="no"
PROFILE=""
HOST=""

while (($#)); do
    case "$1" in
        --strict)          STRICT="yes"; shift ;;
        --profile)         PROFILE="$2"; shift 2 ;;
        --host)            HOST="$2"; shift 2 ;;
        --non-interactive) shift ;;
        -h|--help)         sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.mkosi-secrets"

# Load the profile/role resolver so we can read each profile's
# profile.manifest and discover which secrets it declares via
# uses_secrets=. When build.sh passes --profile "<expanded list>"
# we use that set to scope the "is this secret relevant to this
# build?" decision; otherwise we fall back to checking every known
# secret (pre-profile-manifest behavior).
export AB_PROJECT_ROOT="${REPO_ROOT}"
# shellcheck source=lib/profile-resolver.sh
source "${REPO_ROOT}/scripts/lib/profile-resolver.sh"

# Every known secret category. Order matters for the summary table.
# ssh is special: always required (no bootable image is useful without
# it). The rest are optional unless a selected profile declares them.
ALL_FEATURES=(ssh tailscale cloudflared sendgrid pagerduty healthchecks)

declare -A STATUS
declare -A DETAIL
for k in "${ALL_FEATURES[@]}"; do
    STATUS[$k]="missing"
    DETAIL[$k]=""
done

# Features this build actually needs, based on the selected profiles'
# manifests. ssh is always included. If --profile is empty (e.g.
# --all or an older caller that doesn't pass --profile), we degrade
# gracefully to "check every known feature" so nothing goes unchecked
# by accident.
declare -A NEEDED
NEEDED[ssh]=1
if [[ -n "${PROFILE}" ]]; then
    required_secrets="$(ab_collect_required_secrets "${PROFILE}")"
    for s in ${required_secrets}; do
        NEEDED[$s]=1
    done
else
    for k in "${ALL_FEATURES[@]}"; do
        NEEDED[$k]=1
    done
fi

c_red()    { printf '\033[31m%s\033[0m' "$*"; }
c_green()  { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }

section() { printf '\n[verify-build-secrets] %s\n' "$*" >&2; }
info()    { printf '[verify-build-secrets] %s\n'        "$*" >&2; }
warn()    { printf '[verify-build-secrets] %s %s\n' "$(c_yellow WARN:)" "$*" >&2; }

fail_soft() {
    local feature="$1" msg="$2"
    STATUS[$feature]="malformed"
    DETAIL[$feature]="$msg"
    printf '[verify-build-secrets] %s %s: %s\n' "$(c_red ERROR:)" "$feature" "$msg" >&2
}
fail_hard() {
    printf '[verify-build-secrets] %s %s\n' "$(c_red FATAL:)" "$*" >&2
    exit 1
}
ok() {
    local feature="$1" msg="${2:-}"
    STATUS[$feature]="present"
    DETAIL[$feature]="$msg"
    printf '[verify-build-secrets] %s %s%s\n' "$(c_green OK:)" "$feature" "${msg:+ — $msg}" >&2
}

# --- preconditions ------------------------------------------------------

if [[ ! -d "${SECRETS_DIR}" ]]; then
    info "${SECRETS_DIR} does not exist yet — creating with 0700 perms"
    install -d -m 0700 "${SECRETS_DIR}"
fi

mode="$(stat -c '%a' "${SECRETS_DIR}")"
case "${mode}" in
    700|750|500) : ;;
    *)
        info "fixing ${SECRETS_DIR} perms (${mode} -> 700)"
        chmod 700 "${SECRETS_DIR}"
        ;;
esac

if git -C "${REPO_ROOT}" ls-files --error-unmatch .mkosi-secrets >/dev/null 2>&1; then
    fail_hard ".mkosi-secrets/ is tracked by git. Unstage it and add to .gitignore"
fi

for bin in systemd-creds jq; do
    command -v "${bin}" >/dev/null 2>&1 \
        || fail_hard "host tool missing: ${bin} (apt-get install --no-install-recommends systemd-container jq)"
done

resolve_secret() {
    local name="$1"
    if [[ -n "${HOST}" && -f "${SECRETS_DIR}/hosts/${HOST}/${name}" ]]; then
        printf '%s' "${SECRETS_DIR}/hosts/${HOST}/${name}"; return 0
    fi
    [[ -f "${SECRETS_DIR}/${name}" ]] && { printf '%s' "${SECRETS_DIR}/${name}"; return 0; }
    return 1
}

check_file_perms() {
    local path="$1" m
    m="$(stat -c '%a' "${path}")"
    case "${m}" in
        400|440|600|640) return 0 ;;
        *)
            info "fixing ${path} perms (${m} -> 0600)"
            chmod 0600 "${path}"
            return 0
            ;;
    esac
}

section "scanning ${SECRETS_DIR}"

# --- REQUIRED: ssh-authorized-keys --------------------------------------

if ! ak_path="$(resolve_secret ssh-authorized-keys)"; then
    fail_hard "ssh-authorized-keys is REQUIRED. Append your SSH public key to:
    ${SECRETS_DIR}/ssh-authorized-keys (mode 0600)
Recommended: hardware-backed key via
    ssh-keygen -t ed25519-sk -O resident -O verify-required"
fi

check_file_perms "${ak_path}" || fail_hard "fix the permissions above"

have_sk="no"
key_count=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line// }" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key_count=$((key_count+1))
    case "${line}" in
        *sk-ed25519@openssh.com*|*sk-ecdsa-sha2-nistp256@openssh.com*)
            have_sk="yes" ;;
    esac
done <"${ak_path}"

[[ "${key_count}" -gt 0 ]] || fail_hard "${ak_path} has no key lines"

if [[ "${STRICT}" == "yes" && "${have_sk}" != "yes" ]]; then
    fail_hard "--strict mode requires at least one sk-* key; got ${key_count} non-hardware keys"
fi

if [[ "${have_sk}" == "yes" ]]; then
    ok ssh "${key_count} key(s), at least one hardware-backed"
else
    ok ssh "${key_count} key(s), no hardware-backed"
fi

# --- OPTIONAL: tailscale-authkey ----------------------------------------

if [[ -n "${NEEDED[tailscale]+x}" ]]; then
    if ts_path="$(resolve_secret tailscale-authkey)" && check_file_perms "${ts_path}"; then
        ts="$(<"${ts_path}")"; ts="${ts%$'\n'}"
        if [[ "${ts}" != tskey-auth-* && "${ts}" != tskey-* ]]; then
            fail_soft tailscale "content does not start with tskey-auth-"
        elif [[ "${#ts}" -lt 40 ]]; then
            fail_soft tailscale "key looks truncated (${#ts} chars)"
        else
            ok tailscale "${#ts}-char key"
        fi
        unset ts
    else
        warn "tailscale-authkey absent — tailscale profile selected but image will build WITHOUT auto-auth"
    fi
fi

# --- OPTIONAL: cloudflared-token ----------------------------------------

if [[ -n "${NEEDED[cloudflared]+x}" ]]; then
    if cf_path="$(resolve_secret cloudflared-token)" && check_file_perms "${cf_path}"; then
        cf="$(<"${cf_path}")"; cf="${cf%$'\n'}"
        if [[ "${#cf}" -lt 80 ]]; then
            fail_soft cloudflared "token looks truncated (${#cf} chars)"
        elif [[ ! "${cf}" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
            fail_soft cloudflared "token contains non-base64 characters"
        else
            ok cloudflared "${#cf}-char token"
        fi
        unset cf
    else
        warn "cloudflared-token absent — cloudflare-tunnel profile selected but image will build WITHOUT backup SSH"
    fi
fi

# --- OPTIONAL: sendgrid-api-key -----------------------------------------
# sendgrid/pagerduty are consumed by the always-on ab-monitor-alert@
# template regardless of profile, so they are checked whenever a
# secret file is present. "Missing" only warns when NEEDED[sendgrid]
# is set (no profile declares it today; passed-through on --no-profile
# invocations that fall back to "check everything").

if sg_path="$(resolve_secret sendgrid-api-key)" && check_file_perms "${sg_path}"; then
    sg="$(<"${sg_path}")"; sg="${sg%$'\n'}"
    if [[ "${sg}" != SG.* ]]; then
        fail_soft sendgrid "key does not start with 'SG.'"
    elif [[ "${#sg}" -lt 40 ]]; then
        fail_soft sendgrid "key looks truncated"
    else
        ok sendgrid "${#sg}-char key"
    fi
    unset sg
elif [[ -n "${NEEDED[sendgrid]+x}" ]]; then
    warn "sendgrid-api-key absent — alerts will NOT send email"
fi

# --- OPTIONAL: pagerduty-routing-key ------------------------------------

if pd_path="$(resolve_secret pagerduty-routing-key)" && check_file_perms "${pd_path}"; then
    pd="$(<"${pd_path}")"; pd="${pd%$'\n'}"
    if [[ ! "${pd}" =~ ^[A-Za-z0-9]{32}$ ]]; then
        fail_soft pagerduty "key is not 32 alphanumeric chars (got ${#pd})"
    else
        ok pagerduty "32-char routing key"
    fi
    unset pd
elif [[ -n "${NEEDED[pagerduty]+x}" ]]; then
    warn "pagerduty-routing-key absent — alerts will NOT page PagerDuty"
fi

# --- OPTIONAL: healthchecks-ping-url ------------------------------------

if [[ -n "${NEEDED[healthchecks]+x}" ]]; then
    if hc_path="$(resolve_secret healthchecks-ping-url)" && check_file_perms "${hc_path}"; then
        hc="$(<"${hc_path}")"; hc="${hc%$'\n'}"
        case "${hc}" in
            https://hc-ping.com/*|https://*/ping/*) ok healthchecks "configured" ;;
            *) fail_soft healthchecks "URL should look like https://hc-ping.com/<uuid>" ;;
        esac
        unset hc
    else
        warn "healthchecks-ping-url absent — healthchecksio profile selected but dead-man's-switch disabled"
    fi
fi

# --- summary -------------------------------------------------------------

section "build-time secret summary"
printf '  %-16s  %-14s  %s\n' FEATURE STATUS DETAIL >&2
printf '  %-16s  %-14s  %s\n' '----------------' '--------------' '----------------------------' >&2
for k in "${ALL_FEATURES[@]}"; do
    # Hide rows the selected profiles don't need AND that have no file
    # on disk — they are genuinely not relevant to this build. Keep the
    # row if a file is present (so the user notices orphaned secrets)
    # or if a profile declared it (so it gets a visible ok/miss line).
    if [[ -z "${NEEDED[$k]+x}" && "${STATUS[$k]}" == "missing" ]]; then
        continue
    fi
    case "${STATUS[$k]}" in
        present)   c="$(c_green '[configured]  ')" ;;
        missing)   c="$(c_yellow '[skipped]     ')" ;;
        malformed) c="$(c_red    '[MALFORMED]   ')" ;;
        *)         c="${STATUS[$k]}               " ;;
    esac
    printf '  %-16s  %s  %s\n' "$k" "$c" "${DETAIL[$k]}" >&2
done

errors=0
for k in "${!STATUS[@]}"; do
    [[ "${STATUS[$k]}" == "malformed" ]] && errors=$((errors+1))
done

if (( errors > 0 )); then
    section "$(c_red "${errors} feature(s) malformed — refusing to build. Fix the [MALFORMED] rows above.")"
    exit 1
fi

# Persist status for package-*-credentials.sh and the runtime validator.
out="${SECRETS_DIR}/.verify-status.env"
{
    echo "# auto-generated by verify-build-secrets.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for k in "${!STATUS[@]}"; do
        upper="$(tr '[:lower:]' '[:upper:]' <<<"$k")"
        printf 'AB_FEATURE_%s=%s\n' "$upper" "${STATUS[$k]}"
    done
} >"${out}"
chmod 0600 "${out}"

info "build can proceed (wrote ${out})"
exit 0
