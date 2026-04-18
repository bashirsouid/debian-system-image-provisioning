#!/bin/bash
# /usr/local/libexec/ab-user-provision.sh
#
# Runs once on first boot. Reads /etc/ab-users.json (which is placed
# there by mkosi from .users.json) and creates/updates local accounts.
#
# Security properties:
#
#   * Prefers "password_hash" (yescrypt / sha512crypt). Never writes
#     plaintext passwords to disk.
#   * If "password" (plaintext) is present, treats it as a convenience
#     affordance for development images only. On any image whose
#     /etc/os-release has VARIANT_ID=prod (set by the build path), the
#     script refuses to apply a plaintext password and exits 1.
#   * Optionally marks the account as password-expired on first login,
#     forcing a change via chage -d 0.
#   * After a successful run, writes /var/lib/ab-user-provision/done and
#     removes /etc/ab-users.json so the file is not retained on disk.
#   * Idempotent: if /var/lib/ab-user-provision/done exists, exits 0.

set -euo pipefail

log()  { printf '[ab-user-provision] %s\n'       "$*" >&2; }
fail() { printf '[ab-user-provision] ERROR: %s\n' "$*" >&2; exit 1; }

STATE_DIR=/var/lib/ab-user-provision
USERS_JSON=/etc/ab-users.json
DONE="${STATE_DIR}/done"

mkdir -p "${STATE_DIR}"
chmod 0700 "${STATE_DIR}"

if [[ -f "${DONE}" ]]; then
    log "already provisioned; nothing to do."
    exit 0
fi

if [[ ! -f "${USERS_JSON}" ]]; then
    log "no ${USERS_JSON}; nothing to provision."
    touch "${DONE}"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required but not installed."
fi

# Detect image variant. Build sets VARIANT_ID=prod on production images
# (the default if not specified). Dev/QEMU images should set VARIANT_ID=dev
# to unlock the plaintext-password convenience affordance.
VARIANT_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${VARIANT_ID:-prod}")"
log "image VARIANT_ID=${VARIANT_ID}"

# Permissions on the users file: never world-readable.
chmod 0600 "${USERS_JSON}"

user_count="$(jq 'length' "${USERS_JSON}")"
log "provisioning ${user_count} user entries"

for idx in $(seq 0 $((user_count - 1))); do
    entry="$(jq -c ".[${idx}]" "${USERS_JSON}")"

    username="$(jq -r '.username // empty' <<<"${entry}")"
    [[ -n "${username}" ]] || fail "entry ${idx} missing username"

    can_login="$(jq -r '.can_login // false' <<<"${entry}")"
    uid="$(jq -r '.uid // empty' <<<"${entry}")"
    gid="$(jq -r '.gid // empty' <<<"${entry}")"
    primary_group="$(jq -r '.primary_group // .username' <<<"${entry}")"
    shell="$(jq -r '.shell // "/bin/bash"' <<<"${entry}")"
    comment="$(jq -r '.comment // ""' <<<"${entry}")"
    force_change="$(jq -r '.force_password_change_on_first_login // false' <<<"${entry}")"
    password_hash="$(jq -r '.password_hash // empty' <<<"${entry}")"
    password_plain="$(jq -r '.password // empty' <<<"${entry}")"

    # Groups list
    mapfile -t groups < <(jq -r '.groups[]? // empty' <<<"${entry}")

    # Create primary group if needed
    if ! getent group "${primary_group}" >/dev/null; then
        if [[ -n "${gid}" ]]; then
            groupadd -g "${gid}" "${primary_group}"
        else
            groupadd "${primary_group}"
        fi
    fi

    # Create user if missing
    if ! id -u "${username}" >/dev/null 2>&1; then
        useradd_args=(
            --gid "${primary_group}"
            --shell "${shell}"
            --create-home
            --comment "${comment}"
        )
        [[ -n "${uid}" ]] && useradd_args+=(--uid "${uid}")

        if [[ "${can_login}" != "true" ]]; then
            useradd_args+=(--disabled-login)
        fi

        useradd "${useradd_args[@]}" "${username}"
    fi

    # Supplementary groups
    if (( ${#groups[@]} )); then
        # Only add groups that exist on the system (avoid errors on
        # optional groups like plugdev on minimal images).
        existing=()
        for g in "${groups[@]}"; do
            if getent group "$g" >/dev/null; then
                existing+=("$g")
            else
                log "group '${g}' does not exist; skipping for ${username}"
            fi
        done
        if (( ${#existing[@]} )); then
            usermod -aG "$(IFS=,; echo "${existing[*]}")" "${username}"
        fi
    fi

    # Password handling
    if [[ "${can_login}" == "true" ]]; then
        if [[ -n "${password_hash}" && "${password_hash}" != "!" ]]; then
            # Preferred path: a pre-computed hash.
            log "setting password_hash for ${username}"
            usermod -p "${password_hash}" "${username}"
        elif [[ -n "${password_plain}" ]]; then
            if [[ "${VARIANT_ID}" == "prod" ]]; then
                fail "refusing to apply plaintext password for ${username} on a prod image. Use password_hash. See scripts/hash-password.sh."
            fi
            log "WARN: applying plaintext password for ${username} (VARIANT_ID=${VARIANT_ID}; dev-only path)"
            # chpasswd with -c yescrypt asks libcrypt to hash it correctly.
            printf '%s:%s\n' "${username}" "${password_plain}" | chpasswd -c YESCRYPT
        else
            # No password at all: lock the account to password auth.
            # Keeps pubkey auth working.
            log "no password configured for ${username}; locking password auth (pubkey still works)"
            passwd -l "${username}" >/dev/null
        fi

        if [[ "${force_change}" == "true" ]]; then
            log "forcing password change on first login for ${username}"
            chage -d 0 "${username}"
        fi
    else
        # Account exists but cannot log in: make sure it is fully locked.
        usermod -L "${username}" 2>/dev/null || true
        usermod -s /usr/sbin/nologin "${username}" 2>/dev/null || true
    fi

    # Home directory sanity
    homedir="$(getent passwd "${username}" | cut -d: -f6)"
    if [[ -d "${homedir}" ]]; then
        chmod 0700 "${homedir}"
        chown "${username}:${primary_group}" "${homedir}"
    fi

    unset password_hash password_plain entry
done

# Do not retain the users.json on disk. If anyone needs to re-provision,
# they can drop a fresh copy in /etc/ab-users.json and `rm ${DONE}`.
shred -u "${USERS_JSON}" 2>/dev/null || rm -f "${USERS_JSON}"

touch "${DONE}"
chmod 0600 "${DONE}"
log "provisioning complete."
