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
# The mount is exposed with FUSE --fuse-allow-other so that root can browse it
# (`sudo ls /mnt/kopia/<name>`, `sudo cp -a ...`) — a plain FUSE mount is
# visible ONLY to the mounting user (kopia, which is nologin), so without this
# nobody could actually read the files. This is the looser, interactive
# "browse to find a file I can't name" path; for routine, locked-down recovery
# prefer kopia.backup.restore.bash, which never exposes a mount.
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

Browse the mounted tree as root, e.g.:
  sudo ls -R ${MOUNT_ROOT}/<name>
  sudo cp -a ${MOUNT_ROOT}/<name>/<snapshot>/path/to/file /your/dir/
EOF
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
  local T_TYPE T_NAME T_MOUNT T_ENDPOINT T_PATH KOPIA_TARGET_CONFIG KOPIA_TARGET_DESC

  load_password
  connect_target_readonly "${want}"

  # Each target gets its own subdir so concurrent mounts never collide. The
  # directory mode is moot for browsing: access goes through root (`sudo`),
  # which bypasses directory DAC, and --fuse-allow-other admits root to the
  # mounted contents.
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

  log_info "Mounting ${T_NAME} (${KOPIA_TARGET_DESC}) at ${mountpoint_dir}."
  log_info "Browse it as root, e.g.: sudo ls ${mountpoint_dir}. Press Ctrl-C to unmount."
  # --fuse-allow-other requires 'user_allow_other' in /etc/fuse.conf, shipped by
  # this profile, since kopia runs unprivileged here.
  kopia mount all "${mountpoint_dir}" --config-file="${KOPIA_TARGET_CONFIG}" --fuse-allow-other
}

main "$@"
