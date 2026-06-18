#!/usr/bin/env bash
#
# kopia.backup.mount.bash [<name>] — mount a backup repository's full snapshot
# tree read-only at /mnt/kopia/<name> for browsing/restore.
#
# With no argument it lists the configured targets (and, for filesystem
# targets, whether the drive is currently attached). With a target name it
# connects to that repository, mounts ALL snapshots under /mnt/kopia/<name>,
# and BLOCKS so you can browse and copy files out. Press Ctrl-C to unmount
# and exit (the mount is also cleaned up automatically on exit).
#
# Browsing the whole repository tree (rather than guessing a single snapshot)
# makes it easy to find the exact snapshot that still has the file you want.
#
# Must run as the kopia user, e.g.:
#   sudo -u kopia /usr/lib/kopia/kopia.backup.mount.bash mydrive

set -euo pipefail

# shellcheck source=/dev/null
source /usr/lib/kopia/kopia-common.bash

MOUNT_ROOT="${KOPIA_MOUNT_ROOT:-/mnt/kopia}"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [<target-name>]

  (no argument)   list configured backup targets and their status
  <target-name>   mount that target's snapshot tree at ${MOUNT_ROOT}/<name>
                  (read-only; Ctrl-C to unmount and exit)
EOF
}

list_targets() {
  local name mount endpoint path status
  printf 'Filesystem targets:\n'
  local any=0
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

# Look up a single target by name across both lists. Sets globals:
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

main() {
  assert_kopia_user
  require_cmds kopia jq mountpoint

  if [[ $# -eq 0 ]]; then
    list_targets
    return 0
  fi
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage; return 0
  fi

  local want="$1"
  local T_TYPE T_NAME T_MOUNT T_ENDPOINT T_PATH
  find_target "${want}" || fail "no backup target named '${want}'. Run with no argument to list targets."

  load_password

  # Each target gets its own subdir so concurrent mounts never collide; 0700
  # keeps a mounted backup readable only by the kopia user.
  local mountpoint_dir="${MOUNT_ROOT}/${T_NAME}"
  mkdir -p "${MOUNT_ROOT}"
  install -d -m 0700 "${mountpoint_dir}"

  # Always tear the mount down on exit, however we leave. fuse3 ships
  # fusermount3; fall back to fusermount/umount if that is what is present.
  cleanup() {
    if mountpoint -q "${mountpoint_dir}" 2>/dev/null; then
      if command -v fusermount3 >/dev/null 2>&1; then
        fusermount3 -u "${mountpoint_dir}" 2>/dev/null || true
      elif command -v fusermount >/dev/null 2>&1; then
        fusermount -u "${mountpoint_dir}" 2>/dev/null || true
      else
        umount "${mountpoint_dir}" 2>/dev/null || true
      fi
    fi
    rmdir "${mountpoint_dir}" 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM

  if [[ "${T_TYPE}" == "filesystem" ]]; then
    [[ -n "${T_MOUNT}" ]] || fail "filesystem target '${T_NAME}' has no mountpoint."
    mountpoint -q "${T_MOUNT}" || fail "drive for '${T_NAME}' is not mounted at ${T_MOUNT}."
    local repo_path="${T_PATH}"
    [[ -n "${repo_path}" ]] || repo_path="${T_MOUNT%/}/backup.kopia"
    local config="/var/lib/kopia/repository.${T_NAME}.config"
    local cache="/var/cache/kopia/${T_NAME}"
    mkdir -p "$(dirname "${config}")" "${cache}"
    kopia repository connect filesystem \
      --config-file="${config}" --cache-directory="${cache}" --path="${repo_path}" \
      || fail "could not connect to repository at ${repo_path}."
    apply_cache_limits "${config}"
    log_info "Mounting ${T_NAME} (${repo_path}) at ${mountpoint_dir}. Press Ctrl-C to unmount."
    kopia mount all "${mountpoint_dir}" --config-file="${config}"
  else
    local creds="${KOPIA_CREDSTORE}/kopia-s3-creds-${T_NAME}.json"
    [[ -f "${creds}" ]] || fail "missing ${creds}."
    local bucket access secret
    bucket="$(jq -r '.bucket // empty' "${creds}")"
    access="$(jq -r '.accessKeyId // empty' "${creds}")"
    secret="$(jq -r '.secretAccessKey // empty' "${creds}")"
    [[ -n "${bucket}" && -n "${access}" && -n "${secret}" ]] || fail "${creds} missing bucket/accessKeyId/secretAccessKey."
    [[ -n "${T_ENDPOINT}" ]] || fail "cloud target '${T_NAME}' has no endpoint."
    local config="/var/lib/kopia/repository.cloud.${T_NAME}.config"
    local cache="/var/cache/kopia/cloud-${T_NAME}"
    mkdir -p "$(dirname "${config}")" "${cache}"
    if ! kopia repository status --config-file="${config}" >/dev/null 2>&1; then
      kopia repository connect s3 \
        --config-file="${config}" --cache-directory="${cache}" \
        --bucket="${bucket}" --endpoint="${T_ENDPOINT}" \
        --access-key="${access}" --secret-access-key="${secret}" \
        || fail "could not connect to s3://${bucket}."
    fi
    apply_cache_limits "${config}"
    log_info "Mounting ${T_NAME} (s3://${bucket}) at ${mountpoint_dir}. Press Ctrl-C to unmount."
    kopia mount all "${mountpoint_dir}" --config-file="${config}"
  fi
}

main "$@"
