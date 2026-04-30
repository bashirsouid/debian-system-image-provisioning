#!/usr/bin/env bash
set -euo pipefail

# Thin on-target wrapper around bin/write-live-test-usb.sh.
#
# The booted live USB needs a separate entry point because:
#   1. It defaults --allow-fixed-disk=yes (the script exists to write
#      to an internal disk; the underlying installer defaults to
#      refusing fixed disks for the same reasons run.sh does).
#   2. It picks the bundle layout shipped under /root/ab-installer
#      (flat mkosi.output, no builds/ symlink) instead of the build
#      tree's mkosi.output/builds/<host>.
#   3. It prompts interactively for /home and /mnt/data sizing when
#      the operator did not supply them on the CLI, since on a fresh
#      internal disk those are real choices and not "the default just
#      happens to be right" the way they are for a removable USB.
#
# All actual partitioning, seeding, bootloader, and bundle work lives
# in bin/write-live-test-usb.sh — this file only collects answers and
# forwards them. Keeping one implementation means testing the script
# against a USB target (cheap, non-destructive to the host) also
# covers the internal-disk path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"

TARGET=""
SOURCE_DIR="$PROJECT_ROOT/mkosi.output"
DEFINITIONS_DIR="$PROJECT_ROOT/mkosi.sysupdate"
ASSUME_YES=false
MODE=""
ESP_SIZE="${AB_INSTALL_ESP_SIZE:-1G}"
ROOT_SIZE="${AB_INSTALL_ROOT_SIZE:-8G}"
HOME_SIZE_TOKEN="${AB_INSTALL_HOME_SIZE:-none}"
# /mnt/data defaults to "rest" because it is the persistent slot
# shared across retained-version A/B swaps; on both internal disks
# and removable test USBs the natural meaning of "remaining space"
# is "whatever survives an OS update."
DATA_SIZE_TOKEN="${AB_INSTALL_DATA_SIZE:-rest}"
ALLOW_FIXED_DISK="${AB_INSTALL_ALLOW_FIXED_DISK:-yes}"
DIAGNOSTIC_MODE=false

usage() {
  cat <<'USAGE'
Usage: sudo ./installer/live-usb-install.sh [options]

Interactive on-target installer that runs after the user has booted from a
hardware-test USB. Lays out an A/B install on the chosen target disk
(typically the internal one) by forwarding to bin/write-live-test-usb.sh.

Options:
  --target PATH        whole target disk (for example /dev/nvme0n1)
  --mode MODE          fresh (default) or update
  --source-dir DIR     sysupdate source artifact directory
                       (default: ../mkosi.output relative to this script)
  --definitions DIR    sysupdate transfer definition directory
                       (default: ../mkosi.sysupdate relative to this script)
  --esp-size SIZE      ESP size for fresh bootstrap (default: 1G)
  --root-size SIZE     per-slot root size for fresh bootstrap (default: 8G)
  --home-size TOKEN    /home partition size: none, rest, or explicit size
                       (default: none — /home lives inside the root slot
                       unless you opt into a separate partition)
  --data-size TOKEN    /mnt/data partition size: none, rest, or explicit size
                       (default: rest — persistent across A/B swaps)
  --allow-fixed-disk[=yes|no]
                       permit / refuse writing to a non-removable (internal)
                       disk. Defaults to yes for this installer (its whole
                       reason for existing is to write to internal disks);
                       pass --allow-fixed-disk=no to re-enable the safety
                       refusal when re-targeting a removable disk.
  --diagnostic-mode    forward --diagnostic-mode to write-live-test-usb.sh
                       so the loader entry gets initrd debug params
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

# Local copy of the token grammar parser so we can validate operator
# input at the prompt and abort with a clear error before exec'ing
# write-live-test-usb.sh. write-live-test-usb.sh runs the same
# validation defensively, but the on-target UX is cleaner if we catch
# typos here.
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
    die "only one of /home or /mnt/data may use 'rest' (got $rest_count)"
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
    1|fresh|Fresh) MODE="fresh" ;;
    2|update|Update) MODE="update" ;;
    *) die "invalid mode selection: $answer" ;;
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
  DATA_SIZE_TOKEN="$(normalize_size_token "$(prompt_with_default "/mnt/data partition size (none, rest, or size)" "$DATA_SIZE_TOKEN")" "$DATA_SIZE_TOKEN")"
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

run_fresh_bootstrap() {
  # Forward all the layout choices to write-live-test-usb.sh, which
  # owns the partitioning + bootloader + manual-seed flow. Originally
  # this script generated its own systemd-repart definitions and called
  # bootstrap-ab-disk.sh directly, but that path tried to seed the
  # first version with `systemd-sysupdate --image=$DISK update` and
  # systemd-dissect was unreliable on freshly-repartitioned disks
  # ("Failed to mount image: file system type not supported or not
  # known."). write-live-test-usb.sh already worked around this for
  # the hardware-test USB workflow; we now share that proven flow.
  local bundle_root build_dir installer_script
  bundle_root="$PROJECT_ROOT"
  build_dir="$bundle_root/mkosi.output"
  installer_script="$bundle_root/bin/write-live-test-usb.sh"

  [[ -d "$build_dir" ]] \
    || die "expected bundled build dir not found: $build_dir (the live USB bundle should ship one under /root/ab-installer/mkosi.output)"
  [[ -x "$installer_script" ]] \
    || die "expected installer script not found or not executable: $installer_script"
  [[ -f "$build_dir/build.env" ]] \
    || die "bundled build dir is missing build.env: $build_dir/build.env"

  local args=(
    --target "$TARGET"
    --build-dir "$build_dir"
    # Force the destructive bootstrap path. write-live-test-usb.sh's
    # auto-mode would otherwise look at the existing partition table
    # and may pick --reflash on a previously-installed disk; the
    # operator picked "fresh" deliberately above.
    --reimage
    --esp-size "$ESP_SIZE"
    --root-size "$ROOT_SIZE"
    --home-size "$HOME_SIZE_TOKEN"
    --data-size "$DATA_SIZE_TOKEN"
  )
  [[ "$ALLOW_FIXED_DISK" == "yes" ]] && args+=(--allow-fixed-disk)
  [[ "$ASSUME_YES" == true ]] && args+=(--yes)
  [[ "$DIAGNOSTIC_MODE" == true ]] && args+=(--diagnostic-mode)

  echo "==> Delegating partition + seed + bootloader install to:"
  echo "    $installer_script"
  "$installer_script" "${args[@]}"
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
    --allow-fixed-disk)
      ALLOW_FIXED_DISK=yes
      shift
      ;;
    --allow-fixed-disk=*)
      ALLOW_FIXED_DISK="$(lower "${1#--allow-fixed-disk=}")"
      case "$ALLOW_FIXED_DISK" in
        yes|no) ;;
        *) die "--allow-fixed-disk expects yes or no, got '$ALLOW_FIXED_DISK'" ;;
      esac
      shift
      ;;
    --diagnostic-mode)
      DIAGNOSTIC_MODE=true
      shift
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
if ! ab_hostdeps_have_all_commands systemd-sysupdate systemd-repart bootctl lsblk findmnt mkfs.ext4 e2fsck resize2fs objcopy; then
  # e2fsprogs is required to format and grow the ext4 root/home/data
  # partitions during the manual-seed install path; binutils provides
  # objcopy, used to extract the UKI's .linux/.initrd PE sections so a
  # Type 1 BLS loader entry can boot the freshly-seeded slot. mkosi-built
  # minimal Debian images do not ship either by default — without these
  # the install reaches systemd-repart, formats the ESP, and then dies at
  # the seed step.
  ab_hostdeps_ensure_packages "live USB install prerequisites" systemd-container systemd-repart systemd-boot-tools systemd-boot-efi dosfstools e2fsprogs fdisk util-linux binutils || exit 1
fi
ab_hostdeps_ensure_commands "live USB install prerequisites" systemd-sysupdate systemd-repart bootctl lsblk findmnt mkfs.ext4 e2fsck resize2fs objcopy || {
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
