#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"

TARGET=""
SOURCE_DIR="$PROJECT_ROOT/mkosi.output"
DEFINITIONS_DIR="$PROJECT_ROOT/mkosi.sysupdate"
ASSUME_YES=false
MODE=""
ESP_SIZE="${AB_INSTALL_ESP_SIZE:-512M}"
ROOT_SIZE="${AB_INSTALL_ROOT_SIZE:-8G}"
HOME_SIZE_TOKEN="${AB_INSTALL_HOME_SIZE:-rest}"
DATA_SIZE_TOKEN="${AB_INSTALL_DATA_SIZE:-none}"

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/live-usb-install.sh [options]

Interactive installer intended for a booted hardware-test USB. By default it
asks for a target disk, offers a destructive fresh A/B bootstrap, and can also
stage the bundled version onto an existing systemd-sysupdate layout.

Options:
  --target PATH        whole target disk (for example /dev/nvme0n1)
  --mode MODE          fresh (default) or update
  --source-dir DIR     sysupdate source artifact directory
                       (default: ../mkosi.output relative to this script)
  --definitions DIR    sysupdate transfer definition directory
                       (default: ../mkosi.sysupdate relative to this script)
  --esp-size SIZE      ESP size for fresh bootstrap (default: 512M)
  --root-size SIZE     per-slot root size for fresh bootstrap (default: 8G)
  --home-size TOKEN    /home partition size: none, rest, or explicit size
                       (default: rest)
  --data-size TOKEN    /mnt/data partition size: none, rest, or explicit size
                       (default: none)
  --yes                skip confirmation prompts after values are chosen
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s\n' "$value"
}

lower() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_size_token() {
  local value default_value lowered
  value="$(trim "${1:-}")"
  default_value="$2"

  if [[ -z "$value" ]]; then
    value="$default_value"
  fi

  lowered="$(lower "$value")"
  case "$lowered" in
    none|no|off)
      printf 'none\n'
      return 0
      ;;
    rest|remaining|all)
      printf 'rest\n'
      return 0
      ;;
  esac

  if [[ "$value" =~ ^[0-9]+([KMGTP]i?B?|[kmgpt])?$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  die "invalid size token '$value' (use none, rest, or a size like 100G)"
}

count_rest_tokens() {
  local count=0 token
  for token in "$@"; do
    [[ "$token" == "rest" ]] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

validate_layout_tokens() {
  local rest_count
  rest_count="$(count_rest_tokens "$HOME_SIZE_TOKEN" "$DATA_SIZE_TOKEN")"
  if (( rest_count > 1 )); then
    die "only one of /home or /mnt/data may use 'rest'"
  fi
}

live_root_disk() {
  local root_source pkname
  root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
  [[ -n "$root_source" ]] || return 0
  root_source="$(readlink -f "$root_source")"
  if [[ -b "$root_source" ]]; then
    pkname="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
    if [[ -n "$pkname" ]]; then
      printf '/dev/%s\n' "$pkname"
      return 0
    fi
  fi
  printf '%s\n' "$root_source"
}

device_or_children_mounted() {
  local device="$1"
  if findmnt -rn -S "$device" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -b "$device" ]]; then
    while read -r child; do
      [[ -n "$child" ]] || continue
      if findmnt -rn -S "$child" >/dev/null 2>&1; then
        return 0
      fi
    done < <(lsblk -nrpo NAME "$device" | tail -n +2)
  fi

  return 1
}

assert_safe_target() {
  local target_real root_disk
  target_real="$(readlink -f "$TARGET")"
  root_disk="$(live_root_disk)"

  [[ -b "$target_real" ]] || die "target must be a whole block device: $TARGET"

  if [[ -n "$root_disk" && "$target_real" == "$root_disk" ]]; then
    die "refusing to operate on the currently booted USB/root disk: $target_real"
  fi

  if device_or_children_mounted "$target_real"; then
    die "refusing to use a mounted disk or a disk with mounted partitions: $target_real"
  fi
}

list_candidate_disks() {
  local root_disk
  root_disk="$(live_root_disk)"
  echo "Available disks:" >&2
  lsblk -dnpo NAME,SIZE,MODEL,TRAN,RM | while read -r name size model tran rm; do
    local tag=""
    if [[ -n "$root_disk" && "$name" == "$root_disk" ]]; then
      tag=" [current boot disk]"
    fi
    printf '  %s  %s  %s  %s  rm=%s%s\n' "$name" "$size" "${model:--}" "${tran:--}" "$rm" "$tag" >&2
  done
}

prompt_with_default() {
  local prompt="$1"
  local default_value="$2"
  local answer
  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$prompt" "$default_value" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r answer
  answer="$(trim "$answer")"
  if [[ -z "$answer" ]]; then
    answer="$default_value"
  fi
  printf '%s\n' "$answer"
}

choose_mode_interactive() {
  local answer
  echo "Select operation:" >&2
  echo "  1) Fresh install: wipe target and create ESP + retained root versions" >&2
  echo "  2) Update existing retained-version layout without repartitioning" >&2
  answer="$(prompt_with_default "Choice" "1")"
  case "$answer" in
    1|fresh|Fresh)
      MODE="fresh"
      ;;
    2|update|Update)
      MODE="update"
      ;;
    *)
      die "invalid mode selection: $answer"
      ;;
  esac
}

choose_target_interactive() {
  local guess
  list_candidate_disks
  guess="$(lsblk -dnpo NAME | while read -r name; do
    if [[ "$name" != "$(live_root_disk)" ]]; then
      printf '%s\n' "$name"
      break
    fi
  done)"
  TARGET="$(prompt_with_default "Target disk" "$guess")"
}

prompt_layout_interactive() {
  ESP_SIZE="$(prompt_with_default "ESP size" "$ESP_SIZE")"
  ROOT_SIZE="$(prompt_with_default "Per-slot root size" "$ROOT_SIZE")"
  HOME_SIZE_TOKEN="$(normalize_size_token "$(prompt_with_default "Separate /home partition size (none, rest, or size)" "$HOME_SIZE_TOKEN")" "$HOME_SIZE_TOKEN")"
  DATA_SIZE_TOKEN="$(normalize_size_token "$(prompt_with_default "Optional /mnt/data partition size (none, rest, or size)" "$DATA_SIZE_TOKEN")" "$DATA_SIZE_TOKEN")"
  validate_layout_tokens
}

confirm_or_abort() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local answer
  echo >&2
  echo "Target:        $TARGET" >&2
  echo "Mode:          $MODE" >&2
  if [[ "$MODE" == "fresh" ]]; then
    echo "ESP size:      $ESP_SIZE" >&2
    echo "Root size:     $ROOT_SIZE (for each retained root slot)" >&2
    echo "Home size:     $HOME_SIZE_TOKEN" >&2
    echo "Data size:     $DATA_SIZE_TOKEN" >&2
    printf 'This will DESTROY existing partition data on %s. Continue? [y/N] ' "$TARGET" >&2
  else
    printf 'Stage the bundled version onto %s without repartitioning? [y/N] ' "$TARGET" >&2
  fi
  read -r answer
  case "${answer,,}" in
    y|yes) return 0 ;;
    *) echo 'Aborted.' >&2; exit 1 ;;
  esac
}

write_fixed_partition_conf() {
  local path="$1"
  local type="$2"
  local label="$3"
  local size="$4"
  local format="${5:-}"
  {
    echo '[Partition]'
    printf 'Type=%s\n' "$type"
    printf 'Label=%s\n' "$label"
    printf 'SizeMinBytes=%s\n' "$size"
    printf 'SizeMaxBytes=%s\n' "$size"
    if [[ -n "$format" ]]; then
      printf 'Format=%s\n' "$format"
    fi
  } > "$path"
}

write_flexible_partition_conf() {
  local path="$1"
  local type="$2"
  local label="$3"
  local min_size="$4"
  local format="$5"
  {
    echo '[Partition]'
    printf 'Type=%s\n' "$type"
    printf 'Label=%s\n' "$label"
    printf 'SizeMinBytes=%s\n' "$min_size"
    printf 'Format=%s\n' "$format"
  } > "$path"
}

generate_repart_dir() {
  local outdir="$1"
  mkdir -p "$outdir"
  write_fixed_partition_conf "$outdir/00-esp.conf" esp ESP "$ESP_SIZE" vfat
  write_fixed_partition_conf "$outdir/10-root-a.conf" root _empty "$ROOT_SIZE"
  write_fixed_partition_conf "$outdir/11-root-b.conf" root _empty "$ROOT_SIZE"

  case "$HOME_SIZE_TOKEN" in
    none)
      ;;
    rest)
      write_flexible_partition_conf "$outdir/20-home.conf" home HOME 2G ext4
      ;;
    *)
      write_fixed_partition_conf "$outdir/20-home.conf" home HOME "$HOME_SIZE_TOKEN" ext4
      ;;
  esac

  case "$DATA_SIZE_TOKEN" in
    none)
      ;;
    rest)
      write_flexible_partition_conf "$outdir/30-data.conf" linux-generic DATA 2G ext4
      ;;
    *)
      write_fixed_partition_conf "$outdir/30-data.conf" linux-generic DATA "$DATA_SIZE_TOKEN" ext4
      ;;
  esac
}

run_fresh_bootstrap() {
  local tmp_repart
  tmp_repart="$(mktemp -d /tmp/ab-live-repart.XXXXXX)"
  trap 'rm -rf "$tmp_repart"' RETURN
  generate_repart_dir "$tmp_repart"

  "$PROJECT_ROOT/scripts/bootstrap-ab-disk.sh" \
    --target "$TARGET" \
    --source-dir "$SOURCE_DIR" \
    --definitions "$DEFINITIONS_DIR" \
    --repart-dir "$tmp_repart" \
    $( [[ "$ASSUME_YES" == true ]] && printf -- '--yes' )

  rm -rf "$tmp_repart"
  trap - RETURN
}

run_existing_layout_update() {
  echo "==> Staging bundled version onto $TARGET"
  systemd-sysupdate \
    --definitions="$DEFINITIONS_DIR" \
    --transfer-source="$SOURCE_DIR" \
    --image="$TARGET" \
    update
}

show_post_install_notes() {
  echo >&2
  echo "==> Install complete." >&2
  echo "Next steps:" >&2
  echo "  1. Reboot the machine and choose the internal disk in firmware/startup manager." >&2
  echo "  2. After the first successful boot, run: sudo ab-status" >&2
  echo "  3. If the new version looks good, let the boot-complete path bless it or run your usual checks." >&2
  if [[ "$MODE" == "fresh" ]]; then
    echo "" >&2
    echo "Layout reminder:" >&2
    echo "  - /home will auto-mount if you created a GPT home partition." >&2
    echo "  - /mnt/data will mount if you created a partition labeled DATA." >&2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:?missing target path}"
      shift 2
      ;;
    --mode)
      MODE="$(lower "${2:?missing mode}")"
      shift 2
      ;;
    --source-dir)
      SOURCE_DIR="${2:?missing source dir}"
      shift 2
      ;;
    --definitions)
      DEFINITIONS_DIR="${2:?missing definitions dir}"
      shift 2
      ;;
    --esp-size)
      ESP_SIZE="${2:?missing esp size}"
      shift 2
      ;;
    --root-size)
      ROOT_SIZE="${2:?missing root size}"
      shift 2
      ;;
    --home-size)
      HOME_SIZE_TOKEN="$(normalize_size_token "${2:?missing home size token}" "$HOME_SIZE_TOKEN")"
      shift 2
      ;;
    --data-size)
      DATA_SIZE_TOKEN="$(normalize_size_token "${2:?missing data size token}" "$DATA_SIZE_TOKEN")"
      shift 2
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die "live-usb-install.sh must run as root"
if ! ab_hostdeps_have_all_commands systemd-sysupdate systemd-repart bootctl lsblk findmnt; then
  ab_hostdeps_ensure_packages "live USB install prerequisites" systemd-container systemd-repart systemd-boot-tools systemd-boot-efi dosfstools fdisk util-linux || exit 1
fi
ab_hostdeps_ensure_commands "live USB install prerequisites" systemd-sysupdate systemd-repart bootctl lsblk findmnt || {
  echo "==> The live USB installer requires systemd-sysupdate on the running USB system." >&2
  echo "==> If you are seeing this on the build host, you are running the wrong script: use write-live-test-usb.sh on the host and live-usb-install.sh only after booting from that USB." >&2
  exit 1
}

need_cmd systemd-sysupdate
need_cmd lsblk
need_cmd findmnt

[[ -d "$SOURCE_DIR" ]] || die "source directory not found: $SOURCE_DIR"
[[ -d "$DEFINITIONS_DIR" ]] || die "definitions directory not found: $DEFINITIONS_DIR"

if [[ -z "$MODE" ]]; then
  choose_mode_interactive
fi
case "$MODE" in
  fresh|update) ;;
  *) die "unknown mode '$MODE' (use fresh or update)" ;;
esac

if [[ -z "$TARGET" ]]; then
  choose_target_interactive
fi

assert_safe_target

if [[ "$MODE" == "fresh" ]]; then
  validate_layout_tokens
  if [[ "$ASSUME_YES" != true ]]; then
    prompt_layout_interactive
  fi
  validate_layout_tokens
fi

confirm_or_abort

if [[ "$MODE" == "fresh" ]]; then
  run_fresh_bootstrap
else
  run_existing_layout_update
fi

show_post_install_notes
