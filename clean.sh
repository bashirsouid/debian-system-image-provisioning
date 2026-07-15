#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"

ALL=false
DRY_RUN=false
YES=false
KEEP_LATEST=false

usage() {
  cat <<'USAGE'
Usage: ./clean.sh [OPTIONS]

Remove built images from mkosi.output/ to reclaim disk space.

Options:
  (none)          remove all built images from mkosi.output/
  --keep-latest   remove old builds but keep the latest build per host
  --all           full nuke: images, caches, build dirs, generated secrets,
                  third-party deps — everything for a pristine rebuild
  --dry-run       show what would be removed without deleting anything
  -y, --yes       skip confirmation prompt
  -h, --help      show this help

The script will automatically use sudo when needed to remove
root-owned build artifacts.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all|-a|all)
      ALL=true
      shift
      ;;
    --keep-latest|-k)
      KEEP_LATEST=true
      shift
      ;;
    --dry-run|-n)
      DRY_RUN=true
      shift
      ;;
    -y|--yes)
      YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "Unexpected positional arguments: $*" >&2
  usage >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run rm, escalating to sudo if the first attempt fails (root-owned files).
safe_rm() {
  if rm -rf "$@" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo rm -rf "$@"
  else
    echo "ERROR: permission denied removing: $*" >&2
    echo "       Try running with sudo or as root." >&2
    return 1
  fi
}

# Format bytes into a human-readable size string.
human_size() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1073741824)      printf "%.1fG", b/1073741824
    else if (b >= 1048576)    printf "%.1fM", b/1048576
    else if (b >= 1024)       printf "%.0fK", b/1024
    else                      printf "%dB", b
  }'
}

# Compute the total size of the given paths (best-effort, works even if
# some paths are permission-denied).
total_size() {
  # du may fail on root-owned dirs; try sudo fallback and swallow errors.
  local result
  result="$(du -sb "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}')" || true
  if [[ "$result" == "0" ]] && (( $# > 0 )); then
    # Retry with sudo if available
    if command -v sudo >/dev/null 2>&1; then
      result="$(sudo du -sb "$@" 2>/dev/null | awk '{s+=$1} END{print s+0}')" || true
    fi
  fi
  echo "${result:-0}"
}

# Remove a list of paths, using sudo if needed.
remove_paths() {
  local label="$1"
  shift
  local paths=("$@")

  [[ ${#paths[@]} -gt 0 ]] || return 0

  for p in "${paths[@]}"; do
    [[ -e "$p" || -L "$p" ]] || continue
    if $DRY_RUN; then
      echo "  [dry-run] would remove: $p"
    else
      echo "  removing: $p"
      safe_rm "$p"
    fi
  done
}

# ---------------------------------------------------------------------------
# Default mode: clean built images from mkosi.output/
# ---------------------------------------------------------------------------

clean_images() {
  local output_dir="$PROJECT_ROOT/mkosi.output"

  if [[ ! -d "$output_dir" ]]; then
    echo "==> Nothing to clean: mkosi.output/ does not exist."
    return 0
  fi

  local builds_dir="$output_dir/builds"

  # Collect what to remove
  local to_remove=()
  local to_keep=()

  if [[ -d "$builds_dir" ]]; then
    if $KEEP_LATEST; then
      # Find all "latest-*" symlink targets and keep those dirs
      local -A keep_dirs=()
      shopt -s nullglob
      for link in "$builds_dir"/latest*; do
        if [[ -L "$link" ]]; then
          local target
          target="$(readlink -f "$link")"
          if [[ -d "$target" ]]; then
            keep_dirs["$target"]=1
          fi
        fi
      done

      for d in "$builds_dir"/*/; do
        d="${d%/}"
        [[ -d "$d" ]] || continue
        local real_d
        real_d="$(readlink -f "$d")"
        if [[ -n "${keep_dirs[$real_d]:-}" ]]; then
          to_keep+=("$(basename "$d")")
        else
          to_remove+=("$d")
        fi
      done
      shopt -u nullglob
    else
      # Remove everything: all build dirs and symlinks
      shopt -s nullglob
      for d in "$builds_dir"/*/; do
        d="${d%/}"
        [[ -d "$d" ]] || continue
        to_remove+=("$d")
      done
      for link in "$builds_dir"/latest*; do
        [[ -L "$link" ]] && to_remove+=("$link")
      done
      shopt -u nullglob
    fi
  fi

  # Also catch any stray files in mkosi.output/ (outside builds/)
shopt -s nullglob
for f in "$output_dir"/*.raw "$output_dir"/*.efi "$output_dir"/*.conf "$output_dir"/image.* "$output_dir"/*.gpg; do
  [[ -e "$f" ]] && to_remove+=("$f")
done
shopt -u nullglob

  if [[ ${#to_remove[@]} -eq 0 ]]; then
    echo "==> Nothing to clean in mkosi.output/."
    if [[ ${#to_keep[@]} -gt 0 ]]; then
      echo "    Keeping latest builds: ${to_keep[*]}"
    fi
    return 0
  fi

  # Show summary
  local reclaimable
  reclaimable="$(total_size "${to_remove[@]}")"
  local count="${#to_remove[@]}"
  echo "==> Found $count item(s) to remove (~$(human_size "$reclaimable") reclaimable)"

  if [[ ${#to_keep[@]} -gt 0 ]]; then
    echo "    Keeping latest builds: ${to_keep[*]}"
  fi

  for item in "${to_remove[@]}"; do
    local rel_path
    rel_path="${item#"$PROJECT_ROOT"/}"
    if [[ -d "$item" ]]; then
      local sz
      sz="$(total_size "$item")"
      echo "    $(human_size "$sz")  $rel_path/"
    elif [[ -L "$item" ]]; then
      echo "    link  $rel_path"
    else
      echo "          $rel_path"
    fi
  done

  # Confirm
  if ! $YES && ! $DRY_RUN; then
    printf '\nProceed? [y/N] '
    read -r answer
    case "$answer" in
      [yY]|[yY][eE][sS]) ;;
      *)
        echo "Aborted."
        exit 0
        ;;
    esac
  fi

  remove_paths "images" "${to_remove[@]}"

  # Clean up empty builds/ directory
  if [[ -d "$builds_dir" ]] && ! $DRY_RUN; then
    rmdir "$builds_dir" 2>/dev/null || true
  fi

  if $DRY_RUN; then
    echo "==> Dry run complete. No files were removed."
  else
    echo "==> Reclaimed ~$(human_size "$reclaimable") of disk space."
  fi
}

# ---------------------------------------------------------------------------
# --all mode: full nuke for pristine rebuild
# ---------------------------------------------------------------------------

clean_all() {
  echo "==> Full cleanup (--all): removing ALL build state for a pristine rebuild..."

  # Directories to remove
  local dirs_to_remove=(
    mkosi.output
    mkosi.cache
    mkosi.pkgcache
    mkosi.builddir
    mkosi.tmp
    ../.mkosi.workspace
    # .mkosi-secrets
    .mkosi-thirdparty
    .mkosi-metadata
  )
  # Files to remove
  local files_to_remove=(
    .config-checksum
    .config-version
    image
  )
  # Credential paths to remove
  local cred_paths=(
    mkosi.extra/etc/credstore
    mkosi.extra/etc/credstore.encrypted
    mkosi.extra/etc/ssh/authorized_keys.d
    mkosi.extra/var/lib/systemd/credential.secret
  )

  # Collect all existing paths
  local all_paths=()
  for item in "${dirs_to_remove[@]}" "${files_to_remove[@]}" "${cred_paths[@]}"; do
    [[ -e "$PROJECT_ROOT/$item" || -L "$PROJECT_ROOT/$item" ]] && all_paths+=("$item")
  done

  # Expand glob patterns separately (image.* and *.gpg)
  shopt -s nullglob
  for f in "$PROJECT_ROOT"/image.*; do
    all_paths+=("${f#"$PROJECT_ROOT"/}")
  done
  for f in "$PROJECT_ROOT"/mkosi.extra/etc/apt/keyrings/*.gpg; do
    all_paths+=("${f#"$PROJECT_ROOT"/}")
  done
  shopt -u nullglob

  if [[ ${#all_paths[@]} -eq 0 ]]; then
    echo "==> Already clean. Nothing to remove."
    return 0
  fi

  # Compute total reclaimable space
  local abs_paths=()
  for item in "${all_paths[@]}"; do
    abs_paths+=("$PROJECT_ROOT/$item")
  done
  local reclaimable
  reclaimable="$(total_size "${abs_paths[@]}")"

  echo "==> ~$(human_size "$reclaimable") reclaimable across ${#all_paths[@]} item(s):"
  for item in "${all_paths[@]}"; do
    echo "    $item"
  done

  # Confirm
  if ! $YES && ! $DRY_RUN; then
    printf '\nThis will remove ALL build state including caches. Proceed? [y/N] '
    read -r answer
    case "$answer" in
      [yY]|[yY][eE][sS]) ;;
      *)
        echo "Aborted."
        exit 0
        ;;
    esac
  fi

  # Run mkosi clean if available (clears internal mkosi state)
  if command -v mkosi >/dev/null 2>&1; then
    if ! $DRY_RUN; then
      echo "==> Running mkosi clean..."
      safe_rm "unused" 2>/dev/null || true  # dummy to ensure sudo is primed
      mkosi -f -f clean 2>/dev/null || sudo mkosi -f -f clean 2>/dev/null || true
    else
      echo "  [dry-run] would run: mkosi -f -f clean"
    fi
  fi

  remove_paths "build state" "${abs_paths[@]}"

  if $DRY_RUN; then
    echo "==> Dry run complete. No files were removed."
  else
    echo "==> Full cleanup complete. Ready for a pristine rebuild."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if $ALL; then
  clean_all
else
  clean_images
fi
