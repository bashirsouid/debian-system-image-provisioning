#!/usr/bin/env bash
#
# kopia.backup.s3.bash — encrypted Kopia snapshots to one or more S3-compatible
# cloud endpoints.
#
# Targets come from /etc/kopia/targets.json (.cloud[]), rendered from the host
# descriptor's `kopia_cloud_targets` list (each entry is <name>:<endpoint>).
# For each target <name>:
#   * the endpoint is non-secret (from the descriptor);
#   * the credentials come from /etc/credstore/kopia-s3-creds-<name>.json
#     = {"accessKeyId","secretAccessKey","bucket"};
#   * all targets share the kopia-password passphrase.
#
# Run by kopia-cloud-backup.service as User=kopia.

set -euo pipefail

# shellcheck source=/dev/null
source /usr/lib/kopia/kopia-common.bash

export KOPIA_SERVICE_NAME="kopia-cloud-backup"
export KOPIA_HEALTHCHECK_NAME="kopia-cloud-healthcheck-url"

backup_one() {
  local name="$1" endpoint="$2"
  local creds="${KOPIA_CREDSTORE}/kopia-s3-creds-${name}.json"

  [[ -f "${creds}" ]] || { log_error "Target [${name}]: missing ${creds}; skipping."; return 1; }

  local bucket access secret
  bucket="$(jq -r '.bucket // empty' "${creds}")"
  access="$(jq -r '.accessKeyId // empty' "${creds}")"
  secret="$(jq -r '.secretAccessKey // empty' "${creds}")"
  if [[ -z "${bucket}" || -z "${access}" || -z "${secret}" ]]; then
    log_error "Target [${name}]: ${creds} is missing bucket/accessKeyId/secretAccessKey; skipping."
    return 1
  fi
  [[ -n "${endpoint}" ]] || { log_error "Target [${name}]: no endpoint in targets.json; skipping."; return 1; }

  local config="/var/lib/kopia/repository.cloud.${name}.config"
  local cache="/var/cache/kopia/cloud-${name}"
  mkdir -p "$(dirname "${config}")" "${cache}"

  local -a sources=()
  mapfile -t sources < <(read_sources)

  log_info "Target [${name}]: backing up to s3://${bucket} (${endpoint})"
  connect_or_create_s3 "${config}" "${cache}" "${endpoint}" "${bucket}" "${access}" "${secret}" &&
  apply_cache_limits "${config}" &&
  apply_policies "${config}" &&
  run_snapshot "${config}" "${sources[@]}"
}

main() {
  assert_kopia_user
  require_cmds kopia jq
  load_password

  local overall_rc=0 any=0
  local name mount endpoint path
  while IFS="${KOPIA_FS}" read -r name mount endpoint path; do
    [[ -n "${name}" ]] || continue
    any=1
    local rc=0
    backup_one "${name}" "${endpoint}" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
      alert_status success "${name}"
    else
      alert_status failure "${name}" "${rc}"
      overall_rc=1
    fi
  done < <(read_targets cloud)

  if [[ ${any} -eq 0 ]]; then
    log_info "No cloud targets defined in ${KOPIA_TARGETS_FILE}. Nothing to do."
  fi
  return ${overall_rc}
}

main "$@"
