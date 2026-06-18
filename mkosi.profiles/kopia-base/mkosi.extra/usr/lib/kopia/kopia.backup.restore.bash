#!/usr/bin/env bash
#
# kopia.backup.restore.bash — browse and restore from a backup repository
# WITHOUT a FUSE mount. Everything either prints to stdout or is written to a
# directory, so recovery never needs cross-user mount access (see the FUSE
# caveat in kopia.backup.mount.bash) or a kopia login shell. This is the
# locked-down, day-to-day recovery path.
#
# Commands:
#   list                       list configured targets
#   snapshots <name>           list all snapshots for a target (id, time, source)
#   ls <name> <obj> [obj...]   list a snapshot/dir object (kopia ls -l)
#   show <name> <obj>          stream a single file object to stdout
#   get  <name> <obj> [dest]   restore an object (file or dir tree) into <dest>
#                              (default: /var/lib/kopia/restore/<name>)
#
# <obj> is a kopia object/path discovered via `snapshots` then `ls`, e.g. a
# snapshot id 'kabcd1234...' or 'kabcd1234.../Documents/notes.txt'.
#
# Recovering one file you CAN name by id:
#   sudo -u kopia /usr/lib/kopia/kopia.backup.restore.bash show drive <obj> > out
# Recovering a tree (lands kopia-owned under /var/lib/kopia/restore; pull it out
# with sudo, which can read kopia's files since they are not behind FUSE):
#   sudo -u kopia /usr/lib/kopia/kopia.backup.restore.bash get drive <obj>
#   sudo cp -a /var/lib/kopia/restore/drive/. /your/dir/ && sudo chown -R "$USER": /your/dir/
#
# For visually browsing to FIND a file whose name you cannot guess, use
# kopia.backup.mount.bash instead.
#
# Must run as the kopia user, e.g.:
#   sudo -u kopia /usr/lib/kopia/kopia.backup.restore.bash snapshots mydrive

set -euo pipefail

# shellcheck source=/dev/null
source /usr/lib/kopia/kopia-common.bash

RESTORE_ROOT="${KOPIA_RESTORE_ROOT:-/var/lib/kopia/restore}"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <command> [args]

  list                       list configured targets
  snapshots <name>           list all snapshots for a target (id, time, source)
  ls <name> <obj> [obj...]   list a snapshot/dir object (kopia ls -l)
  show <name> <obj>          stream a single file object to stdout
  get  <name> <obj> [dest]   restore an object into <dest>
                             (default: ${RESTORE_ROOT}/<name>)

Discover <obj> with 'snapshots' then 'ls'. Examples:
  sudo -u kopia $0 snapshots mydrive
  sudo -u kopia $0 ls mydrive <snapshot-id>/Documents
  sudo -u kopia $0 show mydrive <obj> > recovered-file
  sudo -u kopia $0 get mydrive <obj>

To browse visually for a file you cannot name, use kopia.backup.mount.bash.
EOF
}

main() {
  assert_kopia_user
  require_cmds kopia jq mountpoint

  local cmd="${1:-list}"
  [[ $# -gt 0 ]] && shift

  case "${cmd}" in
    -h|--help)
      usage; return 0 ;;
    list)
      list_targets; return 0 ;;
  esac

  # Everything below operates on a connected target.
  local T_TYPE T_NAME T_MOUNT T_ENDPOINT T_PATH KOPIA_TARGET_CONFIG KOPIA_TARGET_DESC

  case "${cmd}" in
    snapshots)
      local name="${1:-}"
      [[ -n "${name}" ]] || fail "usage: $(basename "$0") snapshots <name>"
      load_password
      connect_target_readonly "${name}"
      kopia snapshot list --config-file="${KOPIA_TARGET_CONFIG}" --all
      ;;
    ls)
      local name="${1:-}"
      [[ -n "${name}" ]] && shift
      [[ -n "${name}" && $# -ge 1 ]] || fail "usage: $(basename "$0") ls <name> <object> [object...]"
      load_password
      connect_target_readonly "${name}"
      local obj
      for obj in "$@"; do
        printf '== %s ==\n' "${obj}"
        kopia ls -l --config-file="${KOPIA_TARGET_CONFIG}" "${obj}"
      done
      ;;
    show)
      local name="${1:-}" obj="${2:-}"
      [[ -n "${name}" && -n "${obj}" ]] || fail "usage: $(basename "$0") show <name> <object>"
      load_password
      connect_target_readonly "${name}"
      # Stream to stdout; the caller redirects to a file they own.
      kopia show --config-file="${KOPIA_TARGET_CONFIG}" "${obj}"
      ;;
    get|restore)
      local name="${1:-}" obj="${2:-}" dest="${3:-}"
      [[ -n "${name}" && -n "${obj}" ]] || fail "usage: $(basename "$0") get <name> <object> [dest]"
      load_password
      connect_target_readonly "${name}"
      [[ -n "${dest}" ]] || dest="${RESTORE_ROOT}/${T_NAME}"
      mkdir -p "${dest}" \
        || fail "cannot create ${dest} as the kopia user. Pass a kopia-writable <dest> (e.g. under ${RESTORE_ROOT})."
      log_info "Restoring ${obj} from ${T_NAME} (${KOPIA_TARGET_DESC}) into ${dest} ..."
      kopia restore --config-file="${KOPIA_TARGET_CONFIG}" "${obj}" "${dest}"
      log_info "Done. Files are in ${dest} (owned by the kopia user)."
      log_info "Pull them out with: sudo cp -a '${dest}/.' /your/dir/ && sudo chown -R \"\$USER\": /your/dir/"
      ;;
    *)
      usage; fail "unknown command: ${cmd}" ;;
  esac
}

main "$@"
