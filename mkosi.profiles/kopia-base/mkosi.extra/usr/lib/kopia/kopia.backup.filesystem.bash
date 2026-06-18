#!/usr/bin/env bash
#
# kopia.backup.filesystem.bash — encrypted Kopia snapshots to one or more local
# filesystem destinations (rotating local/USB drives).
#
# Targets come from /etc/kopia/targets.json (.filesystem[]), rendered from the
# host descriptor's `kopia_filesystem_targets` list. For each target:
#   * the drive's mountpoint is checked; if it is not currently mounted the
#     target is silently skipped (so rotating spare disks just works);
#   * the repository lives at <mount>/backup.kopia (override with .path);
#   * all targets share the kopia-password passphrase.
#
# Run by kopia-filesystem-backup.service as User=kopia.

set -euo pipefail

# shellcheck source=/dev/null
source /usr/lib/kopia/kopia-common.bash

export KOPIA_SERVICE_NAME="kopia-filesystem-backup"
export KOPIA_HEALTHCHECK_NAME="kopia-filesystem-healthcheck-url"

main() {
  assert_kopia_user
  require_cmds kopia jq mountpoint
  load_password

  local -a sources=()
  mapfile -t sources < <(read_sources)

  local overall_rc=0 any=0
  local name mount endpoint path
  while IFS="${KOPIA_FS}" read -r name mount endpoint path; do
    [[ -n "${name}" ]] || continue
    any=1

    if [[ -z "${mount}" ]]; then
      log_error "Filesystem target [${name}] has no mountpoint; skipping."
      overall_rc=1
      continue
    fi

    if ! mountpoint -q "${mount}"; then
      log_info "Target [${name}]: ${mount} is not mounted; skipping."
      continue
    fi

    local repo_path="${path}"
    [[ -n "${repo_path}" ]] || repo_path="${mount%/}/backup.kopia"
    local config="/var/lib/kopia/repository.${name}.config"
    local cache="/var/cache/kopia/${name}"

    mkdir -p "$(dirname "${config}")" "${cache}" "${repo_path}"

    log_info "Target [${name}]: backing up to ${repo_path}"
    local rc=0
    {
      connect_or_create_filesystem "${config}" "${cache}" "${repo_path}" &&
      apply_cache_limits "${config}" &&
      apply_policies "${config}" &&
      run_snapshot "${config}" "${sources[@]}"
    } || rc=$?

    if [[ ${rc} -eq 0 ]]; then
      alert_status success "${name}"
    else
      alert_status failure "${name}" "${rc}"
      overall_rc=1
    fi
  done < <(read_targets filesystem)

  if [[ ${any} -eq 0 ]]; then
    log_info "No filesystem targets defined in ${KOPIA_TARGETS_FILE}. Nothing to do."
  fi
  return ${overall_rc}
}

main "$@"
