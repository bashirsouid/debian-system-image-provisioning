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
# PROFILE is accepted for future per-profile validation but is currently
# unused. The existence of the flag matches the interface expected by
# build.sh so we swallow it silently.
# shellcheck disable=SC2034
: "${PROFILE}"

while (($#)); do
    case "$1" in
        --strict)  STRICT="yes"; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --host)    HOST="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/.mkosi-secrets"

declare -A STATUS
declare -A DETAIL
for k in ssh tailscale cloudflared sendgrid pagerduty healthchecks; do
    STATUS[$k]="missing"
    DETAIL[$k]=""
done

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
    *) fail_hard "${SECRETS_DIR} has permissions ${mode}. Run: chmod 700 ${SECRETS_DIR}" ;;
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
        *) echo "file perms ${m} (expected 0400/0440/0600/0640) on ${path}" >&2; return 1 ;;
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
    warn "tailscale-authkey absent — image will be built WITHOUT Tailscale auto-auth"
fi

# --- OPTIONAL: cloudflared-token ----------------------------------------

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
    warn "cloudflared-token absent — image will be built WITHOUT Cloudflare Tunnel backup SSH"
fi

# --- OPTIONAL: sendgrid-api-key -----------------------------------------

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
else
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
else
    warn "pagerduty-routing-key absent — alerts will NOT page PagerDuty"
fi

# --- OPTIONAL: healthchecks-ping-url ------------------------------------

if hc_path="$(resolve_secret healthchecks-ping-url)" && check_file_perms "${hc_path}"; then
    hc="$(<"${hc_path}")"; hc="${hc%$'\n'}"
    case "${hc}" in
        https://hc-ping.com/*|https://*/ping/*) ok healthchecks "configured" ;;
        *) fail_soft healthchecks "URL should look like https://hc-ping.com/<uuid>" ;;
    esac
    unset hc
else
    warn "healthchecks-ping-url absent — NO dead-man's-switch (box going dark will not alert you)"
fi

# --- summary -------------------------------------------------------------

section "build-time secret summary"
printf '  %-16s  %-14s  %s\n' FEATURE STATUS DETAIL >&2
printf '  %-16s  %-14s  %s\n' '----------------' '--------------' '----------------------------' >&2
for k in ssh tailscale cloudflared sendgrid pagerduty healthchecks; do
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
