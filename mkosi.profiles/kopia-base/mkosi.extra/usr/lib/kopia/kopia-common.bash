#!/usr/bin/env bash
#
# Shared helpers for the Kopia backup scripts. This file is SOURCED by:
#   - kopia.backup.filesystem.bash
#   - kopia.backup.s3.bash
#   - kopia.backup.mount.bash
# It is not meant to be executed directly.
#
# Conventions:
#   * Non-secret backup config lives in /etc/kopia/targets.json (rendered from
#     the host descriptor: kopia_filesystem_targets / kopia_cloud_targets).
#   * Secrets live in /etc/credstore (root:kopia 0640), readable by the kopia
#     user via its group membership:
#       - kopia-password                  shared repository passphrase
#       - kopia-s3-creds-<name>.json      {accessKeyId,secretAccessKey,bucket}
#   * Per-repo cache is capped so a restore/verify can never fill the disk.

KOPIA_TARGETS_FILE="${KOPIA_TARGETS_FILE:-/etc/kopia/targets.json}"
KOPIA_CREDSTORE="${KOPIA_CREDSTORE:-${CREDENTIALS_DIRECTORY:-/etc/credstore}}"
KOPIA_EXCLUDES_FILE="${KOPIA_EXCLUDES_FILE:-/etc/kopia/excludes.conf}"
KOPIA_EXCLUDES_LOCAL_FILE="${KOPIA_EXCLUDES_LOCAL_FILE:-/etc/kopia/excludes.local.conf}"
KOPIA_SOURCES_FILE="${KOPIA_SOURCES_FILE:-/etc/kopia/sources.conf}"
KOPIA_CONFIG_DIR="${KOPIA_CONFIG_DIR:-/var/lib/kopia}"
KOPIA_CACHE_DIR="${KOPIA_CACHE_DIR:-/var/cache/kopia}"

KOPIA_UPLOAD_LIMIT_MB="${KOPIA_UPLOAD_LIMIT_MB_DEFAULT:-50000}"
KOPIA_PARALLEL="${KOPIA_PARALLEL_DEFAULT:-16}"
KOPIA_CONTENT_CACHE_MB="${KOPIA_CONTENT_CACHE_MB:-1000}"
KOPIA_METADATA_CACHE_MB="${KOPIA_METADATA_CACHE_MB:-500}"

readonly _KOPIA_LOG_TS_FMT="%Y-%m-%dT%H:%M:%S%z"

log_info()  { printf '[%s] [INFO] %s\n'  "$(date +"${_KOPIA_LOG_TS_FMT}")" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$(date +"${_KOPIA_LOG_TS_FMT}")" "$*" >&2; }
fail()      { log_error "$*"; exit 1; }

# Hard requirement: every backup runs as the dedicated kopia user. Fail loudly
# (not silently as root) if the user was never provisioned.
assert_kopia_user() {
  id kopia >/dev/null 2>&1 || fail "kopia user is not present; refusing to run. (systemd-sysusers should have created UID 5000 from the kopia profile.)"
}

require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "required command '${c}' not found in PATH"
  done
}

# Read the shared repository passphrase into KOPIA_PASSWORD. The whole point of
# this stack is encrypted backups, so a missing/empty passphrase is fatal.
load_password() {
  local f="${KOPIA_CREDSTORE}/kopia-password"
  [[ -f "$f" ]] || fail "no repository passphrase at ${f}. Add 'kopia-password' to the age vault (bin/mkosi-vault-edit.sh) and rebuild."
  KOPIA_PASSWORD="$(tr -d '\n' < "$f")"
  [[ -n "${KOPIA_PASSWORD}" ]] || fail "repository passphrase ${f} is empty."
  export KOPIA_PASSWORD
}

# Emit one line per target of the given type ("filesystem" or "cloud").
# Columns are joined with the ASCII unit separator (\037, KOPIA_FS) rather than
# a tab: tab is an IFS *whitespace* character, so `read` would collapse the
# consecutive delimiters around an empty column (e.g. a cloud target with no
# mount) and shift the remaining fields. \037 is non-whitespace, so empty
# columns are preserved. Read these lines with: IFS="${KOPIA_FS}" read -r ...
# Columns: name <US> mount <US> endpoint <US> path
KOPIA_FS=$'\037'
read_targets() {
  local type="$1"
  [[ -f "${KOPIA_TARGETS_FILE}" ]] || return 0
  jq -r --arg t "$type" '
    (.[$t] // [])[]
    | [ (.name // ""), (.mount // ""), (.endpoint // ""), (.path // "") ]
    | join("\u001f")
  ' "${KOPIA_TARGETS_FILE}"
}

# Human-readable list of configured targets and their current status. Shared by
# the interactive mount/restore helpers (printed to stdout).
list_targets() {
  local name mount endpoint path status any
  printf 'Filesystem targets:\n'
  any=0
  while IFS="${KOPIA_FS}" read -r name mount endpoint path; do
    [[ -n "${name}" ]] || continue
    any=1
    if mountpoint -q "${mount}" 2>/dev/null; then status="attached"; else status="not mounted"; fi
    printf '  %-20s %s  (%s)\n' "${name}" "${mount}" "${status}"
  done < <(read_targets filesystem)
  [[ ${any} -eq 1 ]] || printf '  (none)\n'

  printf 'Cloud targets:\n'
  any=0
  while IFS="${KOPIA_FS}" read -r name mount endpoint path; do
    [[ -n "${name}" ]] || continue
    any=1
    printf '  %-20s %s\n' "${name}" "${endpoint}"
  done < <(read_targets cloud)
  [[ ${any} -eq 1 ]] || printf '  (none)\n'
}

# Look up a single target by name across both lists. On success sets globals:
#   T_TYPE T_NAME T_MOUNT T_ENDPOINT T_PATH
find_target() {
  local want="$1" type name mount endpoint path
  for type in filesystem cloud; do
    while IFS="${KOPIA_FS}" read -r name mount endpoint path; do
      if [[ "${name}" == "${want}" ]]; then
        T_TYPE="${type}"; T_NAME="${name}"; T_MOUNT="${mount}"
        T_ENDPOINT="${endpoint}"; T_PATH="${path}"
        return 0
      fi
    done < <(read_targets "${type}")
  done
  return 1
}

# Connect READ-ONLY (never create) to the named target for browsing/restore.
# On success sets two globals for the caller:
#   KOPIA_TARGET_CONFIG  path to the kopia --config-file to use
#   KOPIA_TARGET_DESC    human-readable repo description (for log lines)
# Requires load_password to have run first. This is for the INTERACTIVE mount
# and restore helpers only; the scheduled backup services manage their own
# connect/create lifecycle (connect_or_create_*).
connect_target_readonly() {
  local want="$1"
  find_target "${want}" || fail "no backup target named '${want}'. Run 'list' to see configured targets."

  if [[ "${T_TYPE}" == "filesystem" ]]; then
    [[ -n "${T_MOUNT}" ]] || fail "filesystem target '${T_NAME}' has no mountpoint."
    mountpoint -q "${T_MOUNT}" || fail "drive for '${T_NAME}' is not mounted at ${T_MOUNT}."
    local repo_path="${T_PATH}"
    [[ -n "${repo_path}" ]] || repo_path="${T_MOUNT%/}/backup.kopia"
    KOPIA_TARGET_CONFIG="${KOPIA_CONFIG_DIR}/repository.${T_NAME}.config"
    local cache="${KOPIA_CACHE_DIR}/${T_NAME}"
    mkdir -p "$(dirname "${KOPIA_TARGET_CONFIG}")" "${cache}"
    kopia repository connect filesystem \
      --config-file="${KOPIA_TARGET_CONFIG}" --cache-directory="${cache}" --path="${repo_path}" \
      || fail "could not connect to repository at ${repo_path}."
    KOPIA_TARGET_DESC="${repo_path}"
  else
    local creds="${KOPIA_CREDSTORE}/kopia-s3-creds-${T_NAME}.json"
    [[ -f "${creds}" ]] || fail "missing ${creds}."
    local bucket access secret
    bucket="$(jq -r '.bucket // empty' "${creds}")"
    access="$(jq -r '.accessKeyId // empty' "${creds}")"
    secret="$(jq -r '.secretAccessKey // empty' "${creds}")"
    [[ -n "${bucket}" && -n "${access}" && -n "${secret}" ]] || fail "${creds} missing bucket/accessKeyId/secretAccessKey."
    [[ -n "${T_ENDPOINT}" ]] || fail "cloud target '${T_NAME}' has no endpoint."
    KOPIA_TARGET_CONFIG="${KOPIA_CONFIG_DIR}/repository.cloud.${T_NAME}.config"
    local cache="${KOPIA_CACHE_DIR}/cloud-${T_NAME}"
    mkdir -p "$(dirname "${KOPIA_TARGET_CONFIG}")" "${cache}"
    if ! kopia repository status --config-file="${KOPIA_TARGET_CONFIG}" >/dev/null 2>&1; then
      kopia repository connect s3 \
        --config-file="${KOPIA_TARGET_CONFIG}" --cache-directory="${cache}" \
        --bucket="${bucket}" --endpoint="${T_ENDPOINT}" \
        --access-key="${access}" --secret-access-key="${secret}" \
        || fail "could not connect to s3://${bucket}."
    fi
    KOPIA_TARGET_DESC="s3://${bucket}"
  fi
  apply_cache_limits "${KOPIA_TARGET_CONFIG}"
}

# Print the source paths to snapshot, one per line, from /etc/kopia/sources.conf
# (rendered from the host descriptor's kopia_sources key). Defaults to /home if
# the file is absent or empty.
read_sources() {
  local line had=0
  if [[ -f "${KOPIA_SOURCES_FILE}" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n "$line" ]] || continue
      printf '%s\n' "$line"
      had=1
    done < "${KOPIA_SOURCES_FILE}"
  fi
  [[ ${had} -eq 1 ]] || printf '/home\n'
}

# Cap the cache for the connected repository (config-file). Bounded growth so a
# large restore/verify cannot blow up the host disk.
apply_cache_limits() {
  local config="$1"
  kopia cache set \
    --config-file="${config}" \
    --content-cache-size-mb="${KOPIA_CONTENT_CACHE_MB}" \
    --metadata-cache-size-mb="${KOPIA_METADATA_CACHE_MB}" \
    >/dev/null 2>&1 \
    || log_error "Failed to apply cache limits for ${config} (continuing)."
}

# Apply global compression/retention and the exclude patterns sourced from
# /etc/kopia/excludes.conf (+ optional per-host excludes.local.conf).
apply_policies() {
  local config="$1"
  kopia policy set --global --config-file="${config}" --compression=zstd >/dev/null 2>&1 || true
  kopia policy set --global --config-file="${config}" \
    --keep-hourly=0 --keep-daily=90 --keep-weekly=0 --keep-monthly=0 --keep-annual=0 \
    >/dev/null 2>&1 || true
  kopia policy set --global --config-file="${config}" --add-dot-ignore=nobackup >/dev/null 2>&1 || true

  local -a cmd=("kopia" "policy" "set" "--global" "--config-file=${config}")
  local had=0 line f
  for f in "${KOPIA_EXCLUDES_FILE}" "${KOPIA_EXCLUDES_LOCAL_FILE}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"   # ltrim
      line="${line%"${line##*[![:space:]]}"}"   # rtrim
      [[ -n "$line" ]] || continue
      cmd+=("--add-ignore" "$line")
      had=1
    done < "$f"
  done
  if [[ ${had} -eq 1 ]]; then
    "${cmd[@]}" >/dev/null 2>&1 || log_error "Failed to apply some ignore patterns for ${config}."
  fi
}

# Filesystem repositories self-initialize on first use. A hidden `.initialized`
# marker inside the repo directory is the single source of truth that *our*
# infra created it (mirrors the old Ansible behaviour). It also guards the
# create step: if the marker is present but `connect` fails (e.g. wrong
# passphrase, I/O error), we refuse to create — never lay a fresh empty repo
# over a drive that already holds backups.
connect_or_create_filesystem() {
  local config="$1" cache="$2" path="$3"
  local marker="${path%/}/.initialized"

  if kopia repository status --config-file="${config}" >/dev/null 2>&1; then
    return 0
  fi
  if kopia repository connect filesystem \
       --config-file="${config}" --cache-directory="${cache}" --path="${path}" \
       >/dev/null 2>&1; then
    [[ -f "${marker}" ]] || : > "${marker}"   # adopt a pre-existing repo
    return 0
  fi
  if [[ -f "${marker}" ]]; then
    fail "repository at ${path} is marked initialized but cannot be opened (wrong passphrase or damaged?). Refusing to create a new one over it."
  fi
  log_info "No existing repository at ${path}; initializing a new one."
  kopia repository create filesystem \
    --config-file="${config}" --cache-directory="${cache}" --path="${path}"
  : > "${marker}"
}

# Kopia's S3 backend does NOT read AWS_* environment variables; the keys must
# be passed as flags. They are only needed on the first connect/create — once
# the config file exists, `repository status` short-circuits and the keys stay
# out of the process table on subsequent runs.
connect_or_create_s3() {
  local config="$1" cache="$2" endpoint="$3" bucket="$4" access="$5" secret="$6"
  if kopia repository status --config-file="${config}" >/dev/null 2>&1; then
    return 0
  fi
  if kopia repository connect s3 \
       --config-file="${config}" --cache-directory="${cache}" \
       --bucket="${bucket}" --endpoint="${endpoint}" \
       --access-key="${access}" --secret-access-key="${secret}" \
       >/dev/null 2>&1; then
    return 0
  fi
  log_info "No existing S3 repository in bucket ${bucket}; initializing a new one."
  kopia repository create s3 \
    --config-file="${config}" --cache-directory="${cache}" \
    --bucket="${bucket}" --endpoint="${endpoint}" \
    --access-key="${access}" --secret-access-key="${secret}"
}

# Success/failure notification: clear/raise an ab-monitor alert and ping
# Healthchecks.io. The healthcheck URL file is named per service via
# KOPIA_HEALTHCHECK_NAME.
alert_status() {
  local status="$1" name="$2" rc="${3:-0}"
  local service_name="${KOPIA_SERVICE_NAME:-${SYSTEMD_UNIT:-kopia-backup}}"
  local hc_file="${KOPIA_CREDSTORE}/${KOPIA_HEALTHCHECK_NAME:-}"
  local key="kopia_backup_${service_name}_${name}"

  if [[ "${status}" == "success" ]]; then
    log_info "Backup target [${name}] completed successfully."
    if [[ -x /usr/local/libexec/ab-monitor/notify.sh ]]; then
      /usr/local/libexec/ab-monitor/notify.sh \
        --event resolve --key "${key}" --severity error \
        --summary "Kopia backup target [${name}] for ${service_name} succeeded" || true
    fi
    if [[ -n "${KOPIA_HEALTHCHECK_NAME:-}" && -f "${hc_file}" ]]; then
      local url; url="$(tr -d '\n' < "${hc_file}")"
      [[ -n "${url}" ]] && curl -fsS --max-time 10 --retry 3 --retry-delay 5 \
        --retry-connrefused -o /dev/null "${url}" || true
    fi
  else
    log_error "Backup target [${name}] failed with code ${rc}."
    if [[ -x /usr/local/libexec/ab-monitor/ad-hoc-alert.sh ]]; then
      /usr/local/libexec/ab-monitor/ad-hoc-alert.sh \
        "${key}" "error" \
        "Kopia backup target [${name}] for ${service_name} failed" \
        "{\"exit_code\": ${rc}}" || true
    fi
    if [[ -n "${KOPIA_HEALTHCHECK_NAME:-}" && -f "${hc_file}" ]]; then
      local url; url="$(tr -d '\n' < "${hc_file}")"
      [[ -n "${url}" ]] && curl -fsS --max-time 10 --retry 3 --retry-delay 5 \
        --retry-connrefused -o /dev/null "${url}/fail" || true
    fi
  fi
}

# Run a snapshot of one or more sources for a connected repository. Aggregated
# exit status is the caller's responsibility.
run_snapshot() {
  local config="$1"; shift
  local -a cmd=("kopia" "snapshot" "create"
    "--config-file=${config}"
    "--upload-limit-mb=${KOPIA_UPLOAD_LIMIT_MB}"
    "--parallel=${KOPIA_PARALLEL}")
  if [[ $# -eq 0 ]]; then
    cmd+=("--all")
  else
    cmd+=("$@")
  fi
  "${cmd[@]}"
}
