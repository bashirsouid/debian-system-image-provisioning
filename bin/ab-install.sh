#!/usr/bin/env bash
set -euo pipefail

# ab-install.sh
#
# Single self-contained install script. Same code, same prompts,
# whether you're:
#
#   - building a hardware-test USB from a host-side mkosi build, or
#   - re-imaging an internal disk from a booted live USB.
#
# The script copies ITSELF, plus the .root.raw / .efi / .conf /
# build.env it just used, into /root/ on the seeded disk. That means a
# successfully-installed system can re-image another disk without
# needing the build host or a bundle subdirectory of helper files —
# everything is one self-contained file plus a few image artifacts.
#
# Layout (on a fresh target)
# --------------------------
#   - GPT with:
#       * ESP         (vfat, label=ESP)
#       * root-a      (ext4, label=_empty initially)
#       * root-b      (ext4, label=_empty initially)
#       * HOME        (optional, ext4, label=HOME)
#       * DATA        (default rest-of-disk, ext4, label=DATA)
#
#   - systemd-boot installed into the ESP
#   - One root slot is "seeded" with the mkosi-produced *.root.raw,
#     and its GPT PARTLABEL is set to:
#
#         ${IMAGE_ID}_${IMAGE_VERSION}
#
#     This matches what the sysupdate transfer definitions expect.
#
# Seeding strategy (A/B behavior)
# -------------------------------
# We do NOT use `systemd-sysupdate --image=/dev/sdX` to seed the first
# version because current systemd releases are unreliable when
# dissecting a just-repartitioned, still-empty disk image in that mode
# (this is what caused "Failed to mount image: No such file or
# directory" / "No transfer definitions found."). Instead:
#
#   - On a freshly-partitioned drive (both roots labeled "_empty"):
#       * Seed the first root slot found with ${prefix}.root.raw
#       * Grow the ext4 filesystem to the full partition size
#       * Rename its GPT PARTLABEL to ${IMAGE_ID}_${IMAGE_VERSION}
#
#   - On reuse of an existing USB:
#       * If any root slot is still labeled "_empty", we seed that
#         slot and relabel it as above.
#       * If both root slots are already in use:
#           - With --yes: overwrite a deterministic slot (see
#             select_root_slot_for_seed()).
#           - Without --yes: show the candidate slots and prompt
#             for which one to overwrite (typed path).
#
# This keeps the on-disk layout compatible with the sysupdate-based
# installer and future A/B updates, while avoiding the fragile
# sysupdate --image flow for the initial seed.
#
# The seeded root's /root/ ends up holding only what's needed to
# rerun the install elsewhere — no subdirectory, no separate scripts:
#   - ab-install.sh                          (this script, copied verbatim)
#   - <image-id>_<version>_<arch>.root.raw   (image to dd into a root slot)
#   - <image-id>_<version>_<arch>.efi        (UKI for systemd-boot)
#   - <image-id>_<version>_<arch>.conf       (BLS entry source)
#   - build.env                              (image identity)
#   - SHA256SUMS                             (integrity check)
#   - INSTALL-TO-INTERNAL-DISK.sh            (muscle-memory alias for ab-install.sh)
#
# See the --help output below for CLI usage and options.

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# PROJECT_ROOT only matters when this script runs from a checkout's bin/.
# When it runs from /root/ on a freshly seeded disk there is no parent
# repo, and that is intentional: the script is fully self-contained
# (every helper it needs is inlined below) so the seeded disk never
# ends up referencing files that aren't there.
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"
[[ -n "$PROJECT_ROOT" ]] || PROJECT_ROOT="$SCRIPT_DIR"

# ──────────────────────────────────────────────────────────────────────
# Inlined helper library
#
# Previously this script sourced three files under scripts/lib/ at
# runtime. That worked on the build host (where the repo is on disk),
# but it broke spectacularly when the same script ran from /root/ on a
# booted live USB and tried to reach files that were never copied
# alongside it. The contract this script promises now is: ONE file,
# ZERO source statements, and you can scp it onto any system together
# with a *.root.raw and it will work.
# ──────────────────────────────────────────────────────────────────────

# --- ab_hostdeps: lifted from scripts/lib/host-deps.sh ---------------------

ab_hostdeps_normalize_path() {
  local dir
  for dir in /usr/local/sbin /usr/sbin /sbin /usr/lib/systemd /lib/systemd /usr/libexec /usr/local/libexec; do
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) PATH="$PATH:$dir" ;;
    esac
  done
  export PATH
}
ab_hostdeps_normalize_path

ab_hostdeps_log() { echo "==> $*" >&2; }

ab_hostdeps_auto_install_enabled() {
  case "${AB_AUTO_INSTALL_DEPS:-yes}" in
    0|no|false|off) return 1 ;;
    *) return 0 ;;
  esac
}

ab_hostdeps_resolve_command() {
  local cmd="$1" candidate
  if command -v "$cmd" >/dev/null 2>&1; then
    command -v "$cmd"
    return 0
  fi
  for candidate in "/usr/bin/$cmd" "/usr/sbin/$cmd" "/usr/lib/systemd/$cmd" \
                   "/lib/systemd/$cmd" "/usr/libexec/$cmd" "/usr/local/libexec/$cmd"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ab_hostdeps_have_all_commands() {
  local cmd
  for cmd in "$@"; do
    ab_hostdeps_resolve_command "$cmd" >/dev/null 2>&1 || return 1
  done
}

ab_hostdeps_is_debian_like() {
  local id="" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    like=" ${ID_LIKE:-} "
  fi
  [[ "$id" == "debian" || "$id" == "ubuntu" || "$like" == *" debian "* ]]
}

ab_hostdeps_have_package_installed() {
  local pkg="$1" status
  if ! ab_hostdeps_is_debian_like || ! command -v dpkg-query >/dev/null 2>&1; then
    return 1
  fi
  status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  [[ "$status" == "install ok installed" ]]
}

ab_hostdeps_manual_install_hint() {
  local packages=("$@") pkg
  if ab_hostdeps_is_debian_like && command -v apt-get >/dev/null 2>&1; then
    printf 'sudo apt-get install -y --no-install-recommends'
    for pkg in "${packages[@]}"; do printf ' %q' "$pkg"; done
    printf '\n'
    return 0
  fi
  printf 'install the required host packages:'
  for pkg in "${packages[@]}"; do printf ' %q' "$pkg"; done
  printf '\n'
}

ab_hostdeps_dedup_packages() {
  local pkg
  declare -A seen=()
  for pkg in "$@"; do
    [[ -n "$pkg" ]] || continue
    if [[ -z "${seen[$pkg]:-}" ]]; then
      seen[$pkg]=1
      printf '%s\n' "$pkg"
    fi
  done
}

ab_hostdeps_install_packages() {
  local context="$1"; shift
  local packages=() pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && packages+=("$pkg")
  done < <(ab_hostdeps_dedup_packages "$@")
  [[ ${#packages[@]} -gt 0 ]] || return 0

  if ! ab_hostdeps_auto_install_enabled; then
    ab_hostdeps_log "$context: automatic host dependency installation is disabled (AB_AUTO_INSTALL_DEPS=no)"
    ab_hostdeps_manual_install_hint "${packages[@]}" >&2
    return 1
  fi
  if ! ab_hostdeps_is_debian_like || ! command -v apt-get >/dev/null 2>&1; then
    ab_hostdeps_log "$context: automatic host dependency installation is only implemented for Debian/Ubuntu apt-based hosts"
    ab_hostdeps_manual_install_hint "${packages[@]}" >&2
    return 1
  fi

  local runner=()
  if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then
      runner=(sudo)
    else
      ab_hostdeps_log "$context: sudo is required to auto-install host packages when not running as root"
      ab_hostdeps_manual_install_hint "${packages[@]}" >&2
      return 1
    fi
  fi

  ab_hostdeps_log "$context: installing missing host packages: ${packages[*]}"
  if [[ -z "${AB_HOST_DEPS_APT_UPDATED:-}" ]]; then
    "${runner[@]}" apt-get update
    AB_HOST_DEPS_APT_UPDATED=1
  fi
  "${runner[@]}" apt-get install -y --no-install-recommends "${packages[@]}"
}

ab_hostdeps_ensure_packages() {
  local context="$1"; shift
  local requested=() missing=() pkg status
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && requested+=("$pkg")
  done < <(ab_hostdeps_dedup_packages "$@")
  [[ ${#requested[@]} -gt 0 ]] || return 0
  if ab_hostdeps_is_debian_like && command -v dpkg-query >/dev/null 2>&1; then
    for pkg in "${requested[@]}"; do
      status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
      [[ "$status" == "install ok installed" ]] || missing+=("$pkg")
    done
  else
    missing=("${requested[@]}")
  fi
  [[ ${#missing[@]} -gt 0 ]] || return 0
  ab_hostdeps_install_packages "$context" "${missing[@]}"
}

ab_hostdeps_ensure_commands() {
  local context="$1"; shift
  local missing=() cmd
  for cmd in "$@"; do
    ab_hostdeps_resolve_command "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    ab_hostdeps_log "$context: missing required commands: ${missing[*]}"
    return 1
  fi
  return 0
}

# --- ab_buildmeta: lifted from scripts/lib/build-meta.sh -------------------

ab_buildmeta_safe_component() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then printf 'none\n'; return 0; fi
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_'
}

ab_buildmeta_builds_dir() {
  printf '%s\n' "$1/mkosi.output/builds"
}

ab_buildmeta_resolve_build_dir() {
  local project_root="$1" profile="${2:-}" host="${3:-}" builds_dir link target
  builds_dir="$(ab_buildmeta_builds_dir "$project_root")"
  [[ -d "$builds_dir" ]] || return 1
  if [[ -n "$host" ]]; then
    link="$builds_dir/latest-$(ab_buildmeta_safe_component "$host")"
  elif [[ -n "$profile" ]]; then
    link="$builds_dir/latest-$(ab_buildmeta_safe_component "$profile")"
  else
    link="$builds_dir/latest"
  fi
  [[ -L "$link" || -d "$link" ]] || return 1
  target="$(readlink -f "$link" 2>/dev/null || true)"
  [[ -n "$target" && -d "$target" ]] || return 1
  printf '%s\n' "$target"
}

ab_buildmeta_load_env() {
  local folder="$1"
  [[ -n "$folder" ]] || return 1
  [[ -r "$folder/build.env" ]] || return 1
  # shellcheck disable=SC1091
  . "$folder/build.env"
  AB_BUILD_DIR="$folder"
  export AB_BUILD_DIR
}

ab_buildmeta_host_default_profile() {
  local project_root="$1" host="$2" path
  [[ -n "$host" ]] || return 0
  path="$project_root/hosts/$host/profile.default"
  [[ -f "$path" ]] || return 0
  sed -e 's/[[:space:]]*#.*$//' "$path" | xargs echo -n
}

# --- ab_confirm: lifted from scripts/lib/confirm-destructive.sh ------------

ab_confirm_removable_flag() {
  local device="$1" real name path
  real="$(readlink -f "$device")"
  [[ -b "$real" ]] || { printf 'unknown\n'; return 0; }
  name="$(basename "$real")"
  path="/sys/block/$name/removable"
  if [[ -r "$path" ]]; then cat "$path"; else printf 'unknown\n'; fi
}

ab_confirm_describe_target() {
  local target="$1" real size model vendor serial tran rotational removable labels part_count
  if [[ -z "$target" || ! -e "$target" ]]; then
    printf '  target:     %s (does not exist)\n' "$target"
    return 0
  fi
  real="$(readlink -f "$target")"
  printf '  target:     %s' "$target"
  [[ "$real" != "$target" ]] && printf ' -> %s' "$real"
  printf '\n'
  if [[ -b "$real" ]]; then
    size="$(lsblk -dno SIZE "$real" 2>/dev/null | awk 'NF{print;exit}')"
    model="$(lsblk -dno MODEL "$real" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF{print;exit}')"
    vendor="$(lsblk -dno VENDOR "$real" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF{print;exit}')"
    serial="$(lsblk -dno SERIAL "$real" 2>/dev/null | awk 'NF{print;exit}')"
    tran="$(lsblk -dno TRAN "$real" 2>/dev/null | awk 'NF{print;exit}')"
    rotational="$(lsblk -dno ROTA "$real" 2>/dev/null | awk 'NF{print;exit}')"
    removable="$(ab_confirm_removable_flag "$real")"
    labels="$(lsblk -rno PARTLABEL "$real" 2>/dev/null | awk 'NF' | paste -sd, - 2>/dev/null)"
    part_count="$(lsblk -rno NAME "$real" 2>/dev/null | wc -l)"
    (( part_count > 0 )) && part_count=$(( part_count - 1 ))
    printf '  size:       %s\n' "${size:-unknown}"
    printf '  model:      %s\n' "${model:-unknown}"
    [[ -n "$vendor" ]] && printf '  vendor:     %s\n' "$vendor"
    [[ -n "$serial" ]] && printf '  serial:     %s\n' "$serial"
    [[ -n "$tran" ]]   && printf '  transport:  %s\n' "$tran"
    case "$rotational" in
      1) printf '  rotational: yes\n' ;;
      0) printf '  rotational: no (SSD/flash)\n' ;;
    esac
    case "$removable" in
      1) printf '  removable:  yes\n' ;;
      0) printf '  removable:  no (treated as a FIXED disk)\n' ;;
      *) printf '  removable:  unknown\n' ;;
    esac
    if (( part_count > 0 )); then
      printf '  partitions: %s existing (labels: %s)\n' "$part_count" "${labels:-none}"
    else
      printf '  partitions: none (blank / unpartitioned)\n'
    fi
  elif [[ -f "$real" ]]; then
    size="$(stat -Lc '%s' "$real" 2>/dev/null || echo unknown)"
    printf '  kind:       raw disk image file\n'
    printf '  size:       %s bytes\n' "$size"
    printf '  removable:  n/a (file, will be loop-attached)\n'
  else
    printf '  kind:       neither a block device nor a regular file\n'
  fi
}

ab_confirm_require_removable() {
  local target="$1" allow_fixed="${2:-no}" removable
  if [[ ! -b "$(readlink -f "$target")" ]]; then
    return 0
  fi
  removable="$(ab_confirm_removable_flag "$target")"
  case "$removable" in
    1) return 0 ;;
    0)
      if [[ "$allow_fixed" == "yes" ]]; then
        echo "==> --allow-fixed-disk set; proceeding despite non-removable target" >&2
        return 0
      fi
      cat >&2 <<EOF
ERROR: refusing to write to $target because it is a FIXED disk
       (/sys/block/$(basename "$(readlink -f "$target")")/removable == 0).
       This default exists specifically to catch the accident of flashing
       the host's own SSD when you meant a USB stick. Re-run with
       --allow-fixed-disk if you genuinely intend to install internally.
EOF
      return 1
      ;;
    *)
      [[ "$allow_fixed" == "yes" ]] && return 0
      cat >&2 <<EOF
ERROR: could not determine whether $target is a removable device. Re-run
       with --allow-fixed-disk if you are sure.
EOF
      return 1
      ;;
  esac
}

ab_confirm_describe_image() {
  local profile="${1:-unknown}" host="${2:-none}" image_id="${3:-unknown}"
  local image_version="${4:-unknown}" image_arch="${5:-unknown}" disk_image="${6:-}"
  local disk_size=""
  if [[ -n "$disk_image" && -f "$disk_image" ]]; then
    disk_size="$(stat -Lc '%s' "$disk_image" 2>/dev/null)"
  fi
  printf '  profile:    %s\n' "$profile"
  printf '  host:       %s\n' "$host"
  printf '  image id:   %s\n' "$image_id"
  printf '  version:    %s\n' "$image_version"
  printf '  arch:       %s\n' "$image_arch"
  if [[ -n "$disk_image" ]]; then
    printf '  disk image: %s' "$disk_image"
    if [[ -n "$disk_size" ]]; then
      printf ' (%s bytes)' "$disk_size"
    elif [[ ! -f "$disk_image" ]]; then
      printf ' (MISSING)'
    fi
    printf '\n'
  fi
}

ab_confirm_typed_path() {
  local target="$1" answer
  printf '\nTo confirm destruction, type the target path exactly as shown above\n'
  printf 'and press enter. Anything else aborts.\n\n'
  printf '  > '
  IFS= read -r answer || return 1
  if [[ "$answer" == "$target" ]]; then return 0; fi
  printf 'Typed path did not match. Aborting.\n' >&2
  return 1
}

ab_confirm_read_existing_identity() {
  local device="$1" real part label fstype mnt
  real="$(readlink -f "$device")"
  [[ -b "$real" ]] || return 1
  local candidate=""
  while read -r part label fstype; do
    [[ -n "$part" && -n "$fstype" ]] || continue
    case "$fstype" in ext2|ext3|ext4|vfat|xfs|btrfs) ;; *) continue ;; esac
    case "$label" in ESP|HOME|DATA) continue ;; esac
    candidate="$part"
    break
  done < <(lsblk -nrpo NAME,PARTLABEL,FSTYPE "$real" 2>/dev/null)
  [[ -n "$candidate" ]] || return 1
  mnt="$(mktemp -d /tmp/ab-usb-probe.XXXXXX)" || return 1
  # shellcheck disable=SC2064
  trap "umount '$mnt' >/dev/null 2>&1 || true; rmdir '$mnt' >/dev/null 2>&1 || true" RETURN
  if ! mount -o ro "$candidate" "$mnt" 2>/dev/null; then return 1; fi
  local id_file="" c
  for c in "$mnt/root/USB-IDENTITY.env" "$mnt/USB-IDENTITY.env"; do
    if [[ -f "$c" ]]; then id_file="$c"; break; fi
  done
  [[ -n "$id_file" ]] || return 1
  awk '/^[A-Za-z_][A-Za-z0-9_]*=/ { print }' "$id_file"
  return 0
}

ab_confirm_write_usb_identity() {
  local path="$1" profile="${2:-unknown}" host="${3:-}" image_id="${4:-unknown}"
  local image_version="${5:-unknown}" image_arch="${6:-unknown}" git_rev="${7:-unknown}"
  local dir
  dir="$(dirname "$path")"
  install -d -m 0755 "$dir"
  umask 077
  cat > "$path" <<EOF
# Written by bin/ab-install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Used by the next flash to detect cross-host/cross-profile re-flashes.
AB_USB_IDENTITY_WRITTEN_AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AB_USB_IDENTITY_PROFILE=${profile}
AB_USB_IDENTITY_HOST=${host}
AB_USB_IDENTITY_IMAGE_ID=${image_id}
AB_USB_IDENTITY_IMAGE_VERSION=${image_version}
AB_USB_IDENTITY_IMAGE_ARCH=${image_arch}
AB_USB_IDENTITY_GIT_REV=${git_rev}
EOF
  chmod 0644 "$path"
}

ab_confirm_identity_mismatch() {
  local profile="$1" host="$2" image_id="$3" version="$4" arch="$5"
  local existing ex_host ex_profile ex_id
  existing="$(cat)"
  ex_profile="$(awk -F= '/^AB_USB_IDENTITY_PROFILE=/{print $2; exit}' <<<"$existing")"
  ex_host="$(awk -F= '/^AB_USB_IDENTITY_HOST=/{print $2; exit}'       <<<"$existing")"
  ex_id="$(awk -F= '/^AB_USB_IDENTITY_IMAGE_ID=/{print $2; exit}'     <<<"$existing")"
  [[ -z "$ex_id" ]] && return 0
  [[ "$ex_id" == "$image_id" ]] && return 0
  cat >&2 <<EOF

----------------------------------------------------------------------
WARNING: this disk already holds a different image identity.

Existing on disk:
  profile:    ${ex_profile:-unknown}
  host:       ${ex_host:-unknown}
  image id:   ${ex_id}

Incoming:
  profile:    ${profile}
  host:       ${host}
  image id:   ${image_id}

If the disk was originally built for a different host, reflashing it for
a new target is usually intentional, but it is also the exact shape of
the "I grabbed the wrong disk" mistake. The prompt below will still
require typing the device path, so you have one more chance to abort.
----------------------------------------------------------------------

EOF
  return 1
}

# ──────────────────────────────────────────────────────────────────────
# End of inlined helpers
# ──────────────────────────────────────────────────────────────────────

TARGET=""
BUILD_DIR=""
SOURCE_DIR=""
REPART_DIR="$PROJECT_ROOT/deploy.repart"
PROFILE=""
HOST=""
ASSUME_YES=false
LOADER_TIMEOUT=3
EMBED_FULL_IMAGE=false
# Set when --target was inferred from the boot disk via detect_boot_disk.
# Causes the destructive-confirmation step to skip the typed-path
# gate: the user did not pick the disk by name, so making them type
# it back is just friction. The other safety checks (banner, identity
# panel, removable refusal) still run.
TARGET_AUTO_DETECTED=false
# Whether to copy the heavy install bundle (.root.raw + .efi) into
# /root/ on the seeded disk. The bundle exists so the seeded disk can
# re-flash other targets without the project clone — useful for
# removable USB sticks, useless on a workstation that already has the
# repo. "auto" picks: yes for removable targets, no for fixed disks.
# Override with --copy-install-bundle / --no-copy-install-bundle.
COPY_INSTALL_BUNDLE="auto"
USB_ESP_SIZE=""
USB_ROOT_SIZE=""
IMAGE_ID=""
IMAGE_VERSION=""
IMAGE_ARCH=""
IMAGE_BASENAME=""
# Single source of truth for "<image-id>_<version>_<arch>" — the prefix
# every flash artifact is named with (.root.raw, .efi, .conf,
# .artifacts.env). load_build_metadata() resolves this from the build
# folder so on-disk reality wins over what build.env *says* the prefix
# should be — that way a manually copied / renamed bundle still flashes.
ARTIFACT_PREFIX=""
ALLOW_FIXED_DISK=no
# Layout sizing is expressed as two independent tokens, both of which
# accept the grammar "none | rest | <size>". The defaults are the
# same regardless of whether the target is a removable USB or a fixed
# disk — the unification point of this script is that USB testing
# exercises exactly the same partition-and-seed code as an internal
# install, so any difference at the layout level would defeat the
# purpose.
#
# DATA defaults to 'rest' because /mnt/data is the persistent slot
# shared across retained-version A/B swaps, so the natural reading of
# "the rest of the disk" is "everything that survives an OS update."
# /home is off by default; pass --home-size to opt in to a separate
# partition.
HOME_SIZE_TOKEN="none"
DATA_SIZE_TOKEN="rest"
DIAGNOSTIC_MODE=false
# Mode tristate, chosen at arg-parse time and resolved into REFLASH below:
#   auto        - detect_existing_ab_layout() decides: reflash if an A/B
#                 layout is already on the target (non-destructive),
#                 repartition otherwise. This is the right default for
#                 day-to-day "I plugged in my old test disk and want the
#                 latest build on it" because it preserves the DATA
#                 partition and the active root slot whenever it can.
#   reflash     - force --reflash; error out if the disk doesn't already
#                 have a valid A/B layout.
#   repartition - force a destructive systemd-repart bootstrap, even if
#                 the disk is already laid out correctly.
MODE="auto"
# REFLASH is the resolved boolean used by all the existing flow code.
# Computed from MODE after arg-parsing + load_build_metadata so user
# echo lines can name the resolved disk path.
REFLASH=false
LUKS_PASSPHRASE=""    # passphrase for LUKS-encrypted roots (--luks-passphrase)
LUKS_MAP=""           # mapper name opened by seed_first_root_slot; closed by cleanup()
LUKS_PASS_FILE=""     # tmpfile holding passphrase; shredded by cleanup()

usage() {
  cat <<'USAGE'
Usage: sudo ./bin/ab-install.sh --target /dev/sdX [options]

Bootstraps an A/B layout (ESP + 2 root slots + optional HOME + DATA) on a
target disk, manually seeds one root slot with the built .root.raw,
installs systemd-boot, and copies ITSELF + the image artifacts into
/root/ on the seeded disk so that disk can re-image others without
needing the build host. Works on:

  - removable USB / SD targets, and
  - fixed internal disks (pass --allow-fixed-disk).

Same script, same flags, same prompts, regardless of target — testing
on a USB exercises the same code that runs an internal-disk install.

Options:
  --target PATH         removable USB / SD device, fixed internal disk, or
                        raw disk image file. Optional when the running
                        system is already on an A/B layout — the boot
                        disk is auto-detected and its inactive slot is
                        flashed (pass --target to override or to flash
                        a different disk).
  --build-dir PATH      specific build folder under mkosi.output/builds/ to
                        flash. Takes precedence over --host / --profile.
                        On a booted live USB, this auto-detects to the
                        directory containing this script when a
                        *.root.raw is found there.
  --repart-dir DIR      bootstrap repart definitions (default: ./deploy.repart;
                        falls back to inlined ESP+A+B layout when missing)
  --profile NAME        resolve mkosi.output/builds/latest-NAME when --host
                        is not given and --build-dir is not set
  --host NAME           resolve mkosi.output/builds/latest-NAME (the host
                        name); with no --build-dir this is the usual way
                        to pick the right build
  --loader-timeout N    loader menu timeout to write to the ESP (default: 3)
  --esp-size SIZE       override the ESP size (default: 1G via deploy.repart)
                        accepts the same SIZE grammar as systemd-repart
                        SizeMinBytes (e.g. 512M, 1G).
                        Alias: --usb-esp-size (older name).
  --root-size SIZE      override the per-slot root size. With no override,
                        a removable target auto-sizes to ~3× the .root.raw
                        size; a fixed-disk target uses deploy.repart's value.
                        Alias: --usb-root-size.
  --home-size TOKEN     allocate a separate /home partition (Type=home,
                        Format=ext4, Label=HOME). TOKEN is one of:
                          none   - do not create /home (default)
                          rest   - take whatever space remains
                          SIZE   - explicit size, e.g. 64G
  --data-size TOKEN     allocate a /mnt/data partition (Type=linux-generic,
                        Format=ext4, Label=DATA). Same TOKEN grammar as
                        --home-size. Default: rest (the persistent slot
                        that survives A/B retained-version swaps).
  --embed-full-image    also copy the built full disk image (.raw) into the
                        bundle alongside the .root.raw / .efi / .conf. Useful
                        when you want the live USB to carry the full disk
                        image for sysupdate-style imaging of other hosts.
                        Default: off (the install path does not need it).
  --no-embed-full-image
                        explicit opposite of --embed-full-image; useful
                        when re-imaging an internal drive from a USB whose
                        bundle includes the full image but you do not want
                        to copy it again.
  --copy-install-bundle, --no-copy-install-bundle
                        copy the heavy install bundle (the .root.raw and
                        .efi files used to re-flash other disks) into
                        /root/ on the seeded disk, alongside the script
                        itself. Default: AUTO — yes for removable targets
                        (USB sticks need to be self-sufficient), no for
                        fixed disks (your workstation has the project
                        clone, no reason to burn ~3-4G of root space on
                        a duplicate of the .root.raw). The lightweight
                        identity files (build.env, SHA256SUMS, .conf,
                        .artifacts.env, ab-install.sh, README) are
                        always copied so /root/ stays a self-describing
                        record of what is installed.
  --allow-fixed-disk    permit writing to a non-removable (internal) disk;
                        the default refuses such targets to prevent the
                        "I flashed my laptop's SSD by accident" case
  --yes                 skip destructive confirmation prompts
  --diagnostic-mode     append initrd debug params to the boot entry
  --luks-passphrase PASSPHRASE
                        passphrase for a LUKS-encrypted root partition. Required
                        when *.root.raw uses LUKS (auto-detected after dd). The
                        passphrase is fed to cryptsetup via stdin and is not
                        stored anywhere on the disk.
  --reflash             FORCE reflash mode: do NOT repartition. Detect the
                        existing A/B layout, write the new image into the
                        *inactive* root slot, and leave the active slot +
                        any HOME / DATA partitions untouched.
                        Errors out if the target has no valid A/B layout.
                        This is the same as the auto default when a layout
                        is already present; pass it explicitly to fail fast
                        on a fresh disk.
  --reimage, --repartition
                        FORCE destructive bootstrap: wipe everything on the
                        target and re-create the GPT layout. Use this when
                        you want a fully fresh disk even though an A/B
                        layout already exists, e.g. to switch image-id
                        schemes, change HOME/DATA sizing, or recover from a
                        broken layout.

By default (no --reflash, no --repartition), the tool detects whether the
target already has a valid A/B layout and picks the right mode automatically:
present-layout → reflash, fresh-disk → repartition. The chosen mode is
printed before the destructive-confirmation prompt.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Normalize a layout-size token to one of:
#   none | rest | SIZE     (where SIZE matches systemd-repart SizeMinBytes)
# Empty input falls back to $2 (the existing value). die()s on
# malformed input so a typo at the prompt or in a flag doesn't silently
# produce an unintended layout.
normalize_size_token() {
  local value default_value lowered
  value="$1"
  default_value="$2"

  # Trim leading/trailing whitespace without spawning a subshell on
  # the (very) hot path of arg parsing.
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ -z "$value" ]]; then
    value="$default_value"
  fi

  lowered="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    none|no|off|"")
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

# Validates that AT MOST ONE of HOME / DATA requested 'rest'.
# systemd-repart would happily accept multiple unbounded partitions
# and silently allocate them in the order it sees on disk, which is
# not what an operator typing the same word twice means.
validate_layout_tokens() {
  local rest_count=0 t
  for t in "$HOME_SIZE_TOKEN" "$DATA_SIZE_TOKEN"; do
    [[ "$t" == "rest" ]] && rest_count=$((rest_count + 1))
  done
  if (( rest_count > 1 )); then
    die "only one of --home-size or --data-size may be 'rest' (got $rest_count)"
  fi
}

cleanup() {
    set +e
    [[ -n "${ROOT_MOUNT:-}" ]] && mountpoint -q "$ROOT_MOUNT" && umount "$ROOT_MOUNT"
    [[ -n "${ROOT_MOUNT:-}" && -d "$ROOT_MOUNT" ]] && rmdir "$ROOT_MOUNT"
    if [[ -n "${LUKS_PASS_FILE:-}" && -f "${LUKS_PASS_FILE}" ]]; then
        shred -u "$LUKS_PASS_FILE" 2>/dev/null || rm -f "$LUKS_PASS_FILE"
        LUKS_PASS_FILE=""
    fi
    if [[ -n "${LUKS_MAP:-}" ]]; then
        cryptsetup luksClose "$LUKS_MAP" >/dev/null 2>&1 || true
        LUKS_MAP=""
    fi
    [[ -n "${TEMP_REPART_DIR:-}" && -d "$TEMP_REPART_DIR" ]] && rm -rf "$TEMP_REPART_DIR"
    if [[ -n "${LOOPDEV:-}" ]]; then
        losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

load_build_metadata() {
  # On-target shortcut: when the script runs from /root/ on a
  # successfully-installed disk, the *.root.raw / *.efi / *.conf /
  # build.env that this same script just laid down are sitting right
  # next to it. Using SCRIPT_DIR as BUILD_DIR turns the on-target
  # invocation into a no-flag operation — no --host, no --profile,
  # no mkosi.output/builds tree required.
  if [[ -z "$BUILD_DIR" && -z "$HOST" && -z "$PROFILE" ]]; then
    if [[ -r "$SCRIPT_DIR/build.env" ]] && compgen -G "$SCRIPT_DIR/*.root.raw" >/dev/null 2>&1; then
      BUILD_DIR="$SCRIPT_DIR"
      echo "==> Detected on-target run: using $SCRIPT_DIR as the build artifact directory"
    fi
  fi

  # Per-host profile default: when --host is given and --profile is not,
  # look at hosts/<host>/profile.default so the tool picks the same
  # profile build.sh would have used by default. This is only for
  # display / identity output — resolution itself is by host symlink.
  if [[ -n "$HOST" && -z "$PROFILE" ]]; then
    local host_default_profile
    host_default_profile="$(ab_buildmeta_host_default_profile "$PROJECT_ROOT" "$HOST")"
    [[ -n "$host_default_profile" ]] && PROFILE="$host_default_profile"
  fi

  if [[ -z "$BUILD_DIR" ]]; then
    BUILD_DIR="$(ab_buildmeta_resolve_build_dir "$PROJECT_ROOT" "$PROFILE" "$HOST" || true)"
  fi

  if [[ -z "$BUILD_DIR" ]]; then
    if [[ -n "$HOST" ]]; then
      die "no build found for host='$HOST' under mkosi.output/builds/ — run ./build.sh --host '$HOST' first"
    elif [[ -n "$PROFILE" ]]; then
      die "no build found for profile='$PROFILE' under mkosi.output/builds/ — run ./build.sh --profile '$PROFILE' first"
    else
      die "no build found under mkosi.output/builds/ and no *.root.raw next to this script — run ./build.sh first, or pass --build-dir / --host / --profile, or copy the artifacts next to ab-install.sh"
    fi
  fi

  [[ -d "$BUILD_DIR" ]] || die "resolved build folder does not exist: $BUILD_DIR"
  ab_buildmeta_load_env "$BUILD_DIR" \
    || die "build folder is missing build.env: $BUILD_DIR"

  IMAGE_ID="${AB_LAST_BUILD_IMAGE_ID:-}"
  IMAGE_VERSION="${AB_LAST_BUILD_IMAGE_VERSION:-}"
  IMAGE_ARCH="${AB_LAST_BUILD_ARCH:-}"
  IMAGE_BASENAME="${AB_LAST_BUILD_IMAGE_BASENAME:-}"

  [[ -n "$IMAGE_ID" ]] || die "build.env is missing AB_LAST_BUILD_IMAGE_ID"
  [[ -n "$IMAGE_VERSION" ]] || die "build.env is missing AB_LAST_BUILD_IMAGE_VERSION"
  [[ -n "$IMAGE_ARCH" ]] || die "build.env is missing AB_LAST_BUILD_ARCH"
  [[ -n "$IMAGE_BASENAME" ]] || die "build.env is missing AB_LAST_BUILD_IMAGE_BASENAME"

  # Every path below this point reads from the resolved build folder.
  SOURCE_DIR="$BUILD_DIR"

  # Resolve the artifact prefix that every downstream lookup uses
  # (${prefix}.root.raw, .efi, .conf, .artifacts.env). The expected
  # prefix is ${IMAGE_ID}_${IMAGE_VERSION}_${IMAGE_ARCH} — but on a
  # live USB or after a manual bundle copy the on-disk filenames may
  # not match exactly (different mkosi arch spelling, the user
  # renamed something, build.env got out of sync). Trust the disk:
  # if the expected name is there use it, otherwise pick the lone
  # *.root.raw and derive the prefix from its name.
  local _expected_prefix="${IMAGE_ID}_${IMAGE_VERSION}_${IMAGE_ARCH}"
  if [[ -f "$SOURCE_DIR/${_expected_prefix}.root.raw" ]]; then
    ARTIFACT_PREFIX="$_expected_prefix"
  else
    local _candidates=()
    shopt -s nullglob
    _candidates=("$SOURCE_DIR"/*.root.raw)
    shopt -u nullglob
    if (( ${#_candidates[@]} == 1 )); then
      ARTIFACT_PREFIX="$(basename "${_candidates[0]}" .root.raw)"
      echo "==> Note: build.env prefix '${_expected_prefix}' did not match any file in $SOURCE_DIR" >&2
      echo "    Using actual on-disk prefix '$ARTIFACT_PREFIX' from $(basename "${_candidates[0]}")" >&2
    elif (( ${#_candidates[@]} == 0 )); then
      die "no *.root.raw found in $SOURCE_DIR (expected ${_expected_prefix}.root.raw)"
    else
      echo "ERROR: multiple *.root.raw files in $SOURCE_DIR; cannot pick one:" >&2
      printf '       %s\n' "${_candidates[@]}" >&2
      die "ambiguous source artifacts; remove the extras or pass --build-dir to a single-build folder"
    fi
  fi
}

print_selected_build() {
  echo "==> Selected build"
  echo "    Build folder:   $BUILD_DIR"
  echo "    Profile:        ${AB_LAST_BUILD_PROFILE:-${PROFILE:-unknown}}"
  echo "    Host:           ${AB_LAST_BUILD_HOST:-${HOST:-none}}"
  echo "    Image id:       $IMAGE_ID"
  echo "    Image version:  $IMAGE_VERSION"
  echo "    Artifact prefix:$ARTIFACT_PREFIX"
  if [[ -f "$SOURCE_DIR/$IMAGE_BASENAME" ]]; then
    echo "    Disk image:     $SOURCE_DIR/$IMAGE_BASENAME"
  else
    echo "    Disk image:     (not embedded; on-target install does not need the full disk image)"
  fi
}

# Shows the user two things right before the typed-path gate:
#   BEFORE: the current partition table on the target as lsblk sees
#           it right now. This is the "did I pick the right drive"
#           check -- familiar labels (DATA, HOME, a USB stick you
#           recognize) here are the last chance to notice a mistake.
#   AFTER:  the layout systemd-repart is about to create, from
#           --dry-run=yes. This is the "is this the layout I meant"
#           check -- confirms ESP + two roots + the trailing exFAT
#           storage partition match expectations before any writes.
# systemd-repart accepts the target path directly (block device or
# regular file), so this works before resolve_disk_device has
# loop-attached a file target.
preview_current_and_planned_layout() {
  local target_real
  target_real="$(readlink -f "$TARGET")"

  echo "Current partition table on target (BEFORE):"
  if [[ -b "$target_real" ]]; then
    # -f shows fstype/label/uuid without needing root on some hosts;
    # -o lays out the columns we want to see.
    lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINT "$target_real" 2>/dev/null \
      || echo "  (lsblk failed; target may have no partition table yet)"
  elif [[ -f "$target_real" ]]; then
    printf '  raw image file: %s (%s bytes)\n' \
      "$target_real" "$(stat -Lc '%s' "$target_real" 2>/dev/null || echo unknown)"
    printf '  (will be loop-attached before repart runs)\n'
  else
    echo "  (target is neither a block device nor a regular file)"
  fi
  echo

  echo "Planned layout after repart (AFTER):"
  # Redirect stderr to stdout so the layout table lands in the panel
  # rather than interleaving with the prompt. Filter out the
  # "Refusing to repartition, please re-run with --dry-run=no." line
  # that systemd-repart unconditionally appends to dry-run output —
  # it's misleading in a preview context because this script DOES
  # then re-run with --dry-run=no a few lines below. `|| true`
  # because a dry-run failure (e.g. image too small for the roots)
  # should still let the prompt proceed; the real run will fail
  # loudly and the user has already been warned.
  systemd-repart --dry-run=yes --empty=force \
    --definitions="$BOOTSTRAP_REPART_DIR" \
    "$target_real" 2>&1 \
    | grep -v '^Refusing to repartition' \
    | sed 's/^/  /' || true
  echo
}

# The one destructive-confirmation point for the USB write flow. Runs
# BEFORE bootstrap_disk() so the enhanced panel here (drive identity
# + full image identity from loaded build metadata) is the last thing
# the user reads. bootstrap_disk() is then invoked with --yes so the
# user isn't double-prompted with a less-informed version of the same
# question. This is also where the non-removable-disk refusal lives;
# bootstrap has its own copy for direct callers.
confirm_usb_write_or_abort() {
  [[ "$ASSUME_YES" == true ]] && return 0

  echo
  if [[ "$REFLASH" == true ]]; then
    echo "===================================================================="
    echo "RE-FLASH (non-destructive): writes to the *inactive* root slot only;"
    echo "the active slot, HOME / DATA partitions, and ESP fallback entries are kept."
    echo "===================================================================="
  else
    echo "===================================================================="
    echo "DESTRUCTIVE OPERATION: all partition data on the target will be lost"
    echo "===================================================================="
  fi
  echo
  echo "Target device:"
  ab_confirm_describe_target "$TARGET"
  echo
  echo "Image to install:"
  ab_confirm_describe_image \
    "${AB_LAST_BUILD_PROFILE:-unknown}" \
    "${AB_LAST_BUILD_HOST:-none}" \
    "$IMAGE_ID" \
    "$IMAGE_VERSION" \
    "$IMAGE_ARCH" \
    "$SOURCE_DIR/$IMAGE_BASENAME"
  echo

  if [[ "$REFLASH" == true ]]; then
    echo "Current partition table on target (will be REUSED in --reflash mode):"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINT "$(readlink -f "$TARGET")" 2>/dev/null \
      || echo "  (lsblk failed)"
    echo
  else
    preview_current_and_planned_layout
  fi

  # Cross-host re-flash detector. If the target USB already has a
  # USB-IDENTITY.env from a previous flash, read it (read-only mount)
  # and compare against what we're about to install. A mismatch prints
  # a warning but does not skip the typed-path gate; the operator can
  # still proceed after seeing the prior identity.
  local existing_identity
  existing_identity="$(ab_confirm_read_existing_identity "$TARGET" 2>/dev/null || true)"
  if [[ -n "$existing_identity" ]]; then
    ab_confirm_identity_mismatch \
      "${AB_LAST_BUILD_PROFILE:-unknown}" \
      "${AB_LAST_BUILD_HOST:-none}" \
      "$IMAGE_ID" \
      "$IMAGE_VERSION" \
      "$IMAGE_ARCH" \
      <<<"$existing_identity" || true
  fi

  ab_confirm_require_removable "$TARGET" "$ALLOW_FIXED_DISK" || exit 1
  if [[ "$TARGET_AUTO_DETECTED" == true ]]; then
    echo "==> Target was auto-detected from the boot disk; skipping typed-path gate."
    echo "    Pass --target to force a different disk; pass --yes to also skip"
    echo "    the slot picker if both slots are populated."
  else
    ab_confirm_typed_path "$TARGET" || exit 1
  fi
}

resolve_disk_device() {
  local target_real
  target_real="$(readlink -f "$TARGET")"

  # systemd-repart and the loop refresh want the *original* path
  # (block device or regular file), not the loop device path. Capture
  # it before any loop attachment so bootstrap_disk can pass it
  # through to systemd-repart and re-attach a fresh loop with
  # --partscan after the partition table is rewritten.
  TARGET_FOR_SYSUPDATE="$target_real"

  if [[ -b "$target_real" ]]; then
    DISK_DEVICE="$target_real"
    return 0
  fi

  [[ -f "$target_real" ]] || die "target is neither a block device nor a regular file: $TARGET"
  LOOPDEV="$(losetup --find --show --partscan "$target_real")"
  DISK_DEVICE="$LOOPDEV"
}

find_seeded_root_partition() {
  local line NAME PARTLABEL FSTYPE TYPE
  while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue
    [[ -n "$NAME" ]] || continue

    case "$PARTLABEL" in
      ESP|_empty|HOME|DATA)
        continue
        ;;
    esac

    # fstype check is now just a hint; we mostly care about the label
    if [[ "$PARTLABEL" == "${IMAGE_ID}_${IMAGE_VERSION}" || "$PARTLABEL" == ${IMAGE_ID}_* ]]; then
      printf '%s\n' "$NAME"
      return 0
    fi
  done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

  # Fallback: any non-reserved partition
  while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue
    [[ -n "$NAME" ]] || continue

    case "$PARTLABEL" in
      ESP|_empty|HOME|DATA)
        continue
        ;;
    esac
    printf '%s\n' "$NAME"
    return 0
  done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

  return 1
}

# Select a root partition to seed with the current image.
# Strategy:
#   - Prefer any root partition with PARTLABEL=_empty
#   - Otherwise, if --yes is NOT set, prompt the user to choose
#   - With --yes, deterministically pick the "oldest-looking"
#     slot (lexicographically smallest PARTLABEL) so repeated
#     invocations are predictable.
select_root_slot_for_seed() {
    local line NAME PARTLABEL FSTYPE TYPE candidates=() labels=()

    while IFS= read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        [[ -n "$NAME" ]] || continue

        case "$PARTLABEL" in
            ESP|HOME|DATA)
                continue
                ;;
        esac
        # root slots are usually ext4 but can be crypto_LUKS if encrypted
        [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]] || continue

        candidates+=("$NAME")
        labels+=("$PARTLABEL")
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

    (( ${#candidates[@]} > 0 )) || die "no candidate root partitions found on $DISK_DEVICE"

    # 1) Prefer an "_empty" slot
    for i in "${!candidates[@]}"; do
        if [[ "${labels[$i]}" == "_empty" ]]; then
            ROOT_PART="${candidates[$i]}"
            echo "==> Selected empty root slot for seed: $ROOT_PART (label=_empty)"
            return 0
        fi
    done

    # 2) If not in --yes mode, ask the user which slot to overwrite
    if [[ "$ASSUME_YES" != true ]]; then
        echo "Existing root slots on $DISK_DEVICE:"
        for i in "${!candidates[@]}"; do
            printf "  [%d] %s (PARTLABEL=%s)\n" "$i" "${candidates[$i]}" "${labels[$i]}"
        done
        echo
        echo "All root slots appear to be in use. Choose which one to overwrite."
        echo "Type the full device path (e.g. ${candidates[0]}) and press Enter:"
        read -r choice
        for i in "${!candidates[@]}"; do
            if [[ "$choice" == "${candidates[$i]}" ]]; then
                ROOT_PART="$choice"
                echo "==> Selected root slot for seed: $ROOT_PART (label=${labels[$i]})"
                return 0
            fi
        done
        die "no matching root slot for choice: $choice"
    fi

    # 3) With --yes and no _empty slots, pick a deterministic slot:
    #    lowest lexicographic PARTLABEL, fallback to first candidate.
    local best_idx=0 best_label="${labels[0]}"
    for i in "${!labels[@]}"; do
        if [[ "${labels[$i]}" < "$best_label" ]]; then
            best_label="${labels[$i]}"
            best_idx="$i"
        fi
    done

    ROOT_PART="${candidates[$best_idx]}"
    echo "==> Selected root slot for seed (auto --yes): $ROOT_PART (PARTLABEL=${labels[$best_idx]})"
    return 0
}

# Prune accumulated systemd-boot Type 1 BLS entries (and their
# referenced kernel/initrd files in /EFI/Linux) so the menu only ever
# shows up-to-date entries for the disk's CURRENT root slots.
#
# Strategy: keep at most one entry per current root slot — the
# just-written entry for the active slot, plus the newest existing
# entry pointing at any other current PARTUUID (the fallback to the
# previously-booted slot). Entries that:
#   * reference a PARTUUID that isn't on the disk anymore
#     (e.g. left over from a prior repartition)
#   * duplicate an already-kept slot with an older mtime / version
#   * couldn't have their PARTUUID parsed
# all get removed. /EFI/Linux/*.{linux,initrd,efi} files that no kept
# entry references are then cleaned up too.
#
# Safe by construction: the just-written entry is always preserved,
# and the most-recent fallback per slot is preserved, so a user can
# still rescue-boot a known-good slot. Bash 4+ associative arrays
# are used; the rest of this file already requires bash 4 (see the
# existing `declare -A seen` in ab_hostdeps_dedup_packages).
prune_old_boot_entries() {
    local esp_mount="$1"
    local current_entry_file="$2"
    local entries_dir="$esp_mount/loader/entries"
    local linux_dir="$esp_mount/EFI/Linux"

    [[ -d "$entries_dir" ]] || return 0

    # PARTUUIDs of every current root-shaped slot on the target disk,
    # plus a luks_uuid -> PARTUUID map so we can identify entries whose
    # cmdline uses `rd.luks.uuid=...` instead of `root=PARTUUID=...`.
    # `blkid -s UUID` on a crypto_LUKS partition returns the LUKS header
    # UUID, which is exactly what rd.luks.uuid= references.
    local valid_pus_glob=""
    declare -A luks_uuid_to_pu=()
    local line NAME PARTLABEL FSTYPE TYPE pu lu
    while read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        case "$PARTLABEL" in
            ESP|HOME|DATA) continue ;;
        esac
        [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]] || continue
        pu="$(blkid -s PARTUUID -o value "$NAME" 2>/dev/null || true)"
        [[ -n "$pu" ]] || continue
        valid_pus_glob="${valid_pus_glob}|${pu^^}"
        if [[ "$FSTYPE" == "crypto_LUKS" ]]; then
            lu="$(blkid -s UUID -o value "$NAME" 2>/dev/null || true)"
            [[ -n "$lu" ]] && luks_uuid_to_pu[${lu,,}]="${pu^^}"
        fi
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

    # Phase 1: pick a single winner per PARTUUID. The just-written
    # entry always wins for its slot; otherwise newest mtime wins.
    declare -A winner_per_pu=()
    declare -A winner_mtime=()

    local conf entry_pu entry_luks mt
    shopt -s nullglob
    for conf in "$entries_dir"/*.conf; do
        [[ -f "$conf" ]] || continue

        # Try to resolve the slot two ways: first `root=PARTUUID=`, then
        # `rd.luks.uuid=`. Either is enough to pin the entry to a slot.
        entry_pu="$(awk '
            /^options/ {
                for (i=1; i<=NF; i++) {
                    if (match($i, /^root=PARTUUID=/)) {
                        sub(/^root=PARTUUID=/, "", $i)
                        print toupper($i); exit
                    }
                }
            }' "$conf" 2>/dev/null)"

        if [[ -z "$entry_pu" ]]; then
            entry_luks="$(awk '
                /^options/ {
                    for (i=1; i<=NF; i++) {
                        if (match($i, /^rd\.luks\.uuid=/)) {
                            sub(/^rd\.luks\.uuid=/, "", $i)
                            print tolower($i); exit
                        }
                    }
                }' "$conf" 2>/dev/null)"
            if [[ -n "$entry_luks" && -n "${luks_uuid_to_pu[$entry_luks]:-}" ]]; then
                entry_pu="${luks_uuid_to_pu[$entry_luks]}"
            fi
        fi

        # Defensive: if we still couldn't pin this entry to a slot but
        # it's the entry we just wrote, keep it anyway. Better to leave
        # one un-classifiable entry behind than to brick the boot we
        # just produced.
        if [[ -z "$entry_pu" ]]; then
            if [[ "$conf" == "$current_entry_file" ]]; then
                winner_per_pu["__current__"]="$conf"
                winner_mtime["__current__"]=9999999999
            fi
            continue
        fi

        # Drop entries whose PARTUUID no longer exists on the disk.
        [[ "${valid_pus_glob}|" == *"|${entry_pu}|"* ]] || continue

        if [[ "$conf" == "$current_entry_file" ]]; then
            winner_per_pu[$entry_pu]="$conf"
            winner_mtime[$entry_pu]=9999999999
            continue
        fi

        mt="$(stat -c '%Y' "$conf" 2>/dev/null || echo 0)"
        if [[ -z "${winner_per_pu[$entry_pu]:-}" ]] || (( mt > ${winner_mtime[$entry_pu]:-0} )); then
            winner_per_pu[$entry_pu]="$conf"
            winner_mtime[$entry_pu]="$mt"
        fi
    done
    shopt -u nullglob

    # Phase 2: keep winners; collect their referenced kernel/initrd
    # files; delete losers.
    declare -A kept_files=()
    local removed_count=0 is_winner pu f
    shopt -s nullglob
    for conf in "$entries_dir"/*.conf; do
        [[ -f "$conf" ]] || continue
        is_winner=no
        for pu in "${!winner_per_pu[@]}"; do
            if [[ "${winner_per_pu[$pu]}" == "$conf" ]]; then
                is_winner=yes
                break
            fi
        done
        if [[ "$is_winner" == "yes" ]]; then
            while IFS= read -r f; do
                [[ -n "$f" ]] && kept_files[$f]=1
            done < <(awk '/^linux[[:space:]]/ { print $2 } /^initrd[[:space:]]/ { print $2 }' "$conf")
        else
            echo "    - pruning stale boot entry: $(basename "$conf")"
            rm -f "$conf"
            removed_count=$((removed_count + 1))
        fi
    done
    shopt -u nullglob
    (( removed_count > 0 )) \
        && echo "==> Pruned $removed_count stale boot entry(ies) from /loader/entries/"

    # Phase 3: orphan kernel / initrd / standalone-UKI files in
    # /EFI/Linux that no kept entry references.
    if [[ -d "$linux_dir" ]]; then
        local lf rel orphans=0
        shopt -s nullglob
        for lf in "$linux_dir"/*.linux "$linux_dir"/*.initrd "$linux_dir"/*.efi; do
            [[ -f "$lf" ]] || continue
            rel="/EFI/Linux/$(basename "$lf")"
            if [[ -z "${kept_files[$rel]:-}" ]]; then
                echo "    - pruning orphan: $(basename "$lf")"
                rm -f "$lf"
                orphans=$((orphans + 1))
            fi
        done
        shopt -u nullglob
        (( orphans > 0 )) \
            && echo "==> Pruned $orphans orphan kernel/initrd file(s) from /EFI/Linux/"
    fi
}

# --reflash helpers ---------------------------------------------------------

# Resolve the whole-disk device the running system booted from, by
# walking from / up through any LUKS / device-mapper layers to the
# underlying partition, and then to its parent disk. Prints the disk
# path on stdout (e.g. /dev/sda or /dev/nvme0n1) and returns 0; returns
# non-zero with no output when the chain can't be resolved (no
# findmnt, no lsblk, weird mount source, etc.).
#
# Used by the no-flag auto-target path: when a user runs ab-install
# from inside a booted A/B system without --target, the only sensible
# answer is "the disk you booted from" — the *other* slot of which is
# what they want to flash. Auto-detection is gated on the boot disk
# already having an A/B layout (see the call site) so we don't
# silently pick the wrong device when running from a non-A/B installer
# environment (e.g. a plain rescue ISO).
detect_boot_disk() {
  local root_src dm_name slave_dir slave parent_disk
  command -v findmnt >/dev/null 2>&1 || return 1
  command -v lsblk   >/dev/null 2>&1 || return 1

  root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n "$root_src" ]] || return 1

  # Unwrap LUKS / dm layers. /dev/mapper/luks-XXX -> underlying part
  # via /sys/class/block/<dm>/slaves/. Loop in case of stacked dm
  # (e.g. LUKS-on-LVM-on-part).
  local guard=0
  while [[ "$root_src" == /dev/mapper/* || "$root_src" == /dev/dm-* ]]; do
    (( guard++ < 8 )) || return 1
    dm_name="$(basename "$(readlink -f "$root_src" 2>/dev/null || echo "$root_src")")"
    slave_dir="/sys/class/block/$dm_name/slaves"
    [[ -d "$slave_dir" ]] || return 1
    slave="$(ls "$slave_dir" 2>/dev/null | head -n1)"
    [[ -n "$slave" ]] || return 1
    root_src="/dev/$slave"
  done

  parent_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | awk 'NF{print;exit}')"
  [[ -n "$parent_disk" ]] || return 1
  printf '/dev/%s\n' "$parent_disk"
}

# Non-destructive "is there already an A/B layout here?" probe. Used by
# the auto-mode dispatcher to decide between reflash and repartition.
# Returns 0 if the target has ≥1 ESP partition and ≥2 root-shaped slots
# (ext4 or unformatted, PARTLABEL not in {ESP,DATA,HOME});
# returns 1 in every other case. Never dies — even on a fresh disk
# with no partition table, lsblk is a clean no-op and we just return 1.
#
# Operates on a read-only loop attach for file targets so detection
# doesn't disturb the bootstrap path that re-attaches its own loop
# device. Block-device targets are inspected with lsblk directly.
detect_existing_ab_layout() {
  local target_real device tmp_loop=""
  target_real="$(readlink -f "$TARGET")"

  if [[ -b "$target_real" ]]; then
    device="$target_real"
  elif [[ -f "$target_real" ]]; then
    tmp_loop="$(losetup --find --show --partscan --read-only "$target_real" 2>/dev/null || true)"
    [[ -n "$tmp_loop" ]] || return 1
    device="$tmp_loop"
  else
    return 1
  fi

  local line NAME PARTLABEL FSTYPE TYPE esp_count=0 root_count=0
  while read -r line; do
    eval "$line"
    [[ "$TYPE" == "part" ]] || continue

    case "$PARTLABEL" in
      ESP)
        esp_count=$((esp_count + 1))
        ;;
      DATA|HOME)
        ;;
      *)
        if [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]]; then
          root_count=$((root_count + 1))
        fi
        ;;
    esac
  done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$device" 2>/dev/null)

  [[ -n "$tmp_loop" ]] && losetup -d "$tmp_loop" >/dev/null 2>&1 || true

  (( esp_count >= 1 && root_count >= 2 ))
}

# Validate that $DISK_DEVICE already has the GPT layout we expect:
# at least one ESP partition and two root-shaped partitions (ext4 or
# unformatted, PARTLABEL not in {ESP,DATA,HOME}). Errors out
# if the layout cannot be reused — the user should either drop
# --reflash to do a destructive bootstrap, or fix the disk manually.
validate_existing_ab_layout() {
    local line NAME PARTLABEL FSTYPE TYPE esp_count=0 root_count=0

    while read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue

        case "$PARTLABEL" in
            ESP)
                esp_count=$((esp_count + 1))
                ;;
            DATA|HOME)
                continue
                ;;
            *)
                if [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]]; then
                    root_count=$((root_count + 1))
                fi
                ;;
        esac
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

    (( esp_count >= 1 )) \
        || die "--reflash: target $DISK_DEVICE has no ESP partition; do a fresh write (drop --reflash) first"
    (( root_count >= 2 )) \
        || die "--reflash: target $DISK_DEVICE has fewer than 2 root slots ($root_count found); do a fresh write (drop --reflash) first"
}

# Read the loader.conf `default` entry on the USB's ESP and return
# the PARTUUID that entry's `options root=PARTUUID=...` resolves to.
# Empty string if the ESP can't be read, the default entry file
# is missing, or the entry has no root=PARTUUID= option.
#
# We match by PARTUUID rather than by PARTLABEL because a fresh-write
# always sets BOTH slots' PARTLABELs to "${IMAGE_ID}_${IMAGE_VERSION}"
# (sysupdate convention), and after the first reseed both slots end
# up with the same PARTLABEL — making PARTLABEL useless for telling
# the slots apart. PARTUUID, on the other hand, is assigned per-slot
# at systemd-repart time and stays stable as long as we don't
# repartition, so it's the right key for identifying "the slot the
# user is currently booting from".
read_default_entry_root_partuuid() {
    local esp_part esp_mount default_line default_entry options_line result="" line NAME PARTLABEL FSTYPE TYPE
    while read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        if [[ "$PARTLABEL" == "ESP" || "$FSTYPE" == "vfat" ]]; then
            esp_part="$NAME"
            break
        fi
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")
    [[ -n "$esp_part" ]] || { printf ''; return 0; }

    esp_mount="$(mktemp -d /tmp/ab-reflash-esp.XXXXXX)"
    if ! mount -o ro "$esp_part" "$esp_mount" 2>/dev/null; then
        rmdir "$esp_mount"
        printf ''
        return 0
    fi

    if [[ -f "$esp_mount/loader/loader.conf" ]]; then
        default_line="$(awk '/^default / { print $2; exit }' "$esp_mount/loader/loader.conf" || true)"
        default_entry="${default_line%.conf}"
        if [[ -n "$default_entry" && -f "$esp_mount/loader/entries/${default_entry}.conf" ]]; then
            options_line="$(awk '/^options / { sub(/^options /, ""); print; exit }' \
                "$esp_mount/loader/entries/${default_entry}.conf")"
            # Pull the PARTUUID value out of `root=PARTUUID=XXX`.
            # Use bash regex so we don't depend on awk/sed niceties.
            if [[ "$options_line" =~ root=PARTUUID=([A-Fa-f0-9-]+) ]]; then
                result="${BASH_REMATCH[1]}"
            fi
        fi
    fi

    umount "$esp_mount" 2>/dev/null || true
    rmdir "$esp_mount" 2>/dev/null || true
    printf '%s' "$result"
}

# --reflash slot selector. Picks the root slot whose PARTUUID is NOT
# the one referenced by the current loader.conf default entry's
# `root=PARTUUID=...` option — i.e. the slot the user is NOT booting
# from. Falls back to "_empty preferred, otherwise lex-smallest" if
# loader.conf can't be parsed.
select_inactive_root_slot_for_reseed() {
    local line NAME PARTLABEL FSTYPE TYPE partuuid
    local -a candidates=() labels=() partuuids=()
    local i active_partuuid active_idx=-1

    while IFS= read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        [[ -n "$NAME" ]] || continue

        case "$PARTLABEL" in
            ESP|DATA|HOME)
                continue
                ;;
        esac
        [[ "$FSTYPE" == "ext4" || "$FSTYPE" == "crypto_LUKS" || -z "$FSTYPE" ]] || continue

        partuuid="$(blkid -s PARTUUID -o value "$NAME" 2>/dev/null || true)"
        candidates+=("$NAME")
        labels+=("$PARTLABEL")
        partuuids+=("$partuuid")
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")

    (( ${#candidates[@]} >= 2 )) \
        || die "--reflash: expected ≥2 root slots on $DISK_DEVICE, found ${#candidates[@]}"

    # 1) An empty slot is unambiguously "not the active one".
    for i in "${!candidates[@]}"; do
        if [[ "${labels[$i]}" == "_empty" ]]; then
            ROOT_PART="${candidates[$i]}"
            echo "==> --reflash: selected empty slot $ROOT_PART (label=_empty)"
            return 0
        fi
    done

    # 2) Match loader.conf default's root=PARTUUID against candidate PARTUUIDs.
    active_partuuid="$(read_default_entry_root_partuuid)"
    if [[ -n "$active_partuuid" ]]; then
        for i in "${!candidates[@]}"; do
            # PARTUUID comparison is case-insensitive in practice (some tools
            # uppercase, others lowercase). Normalize both sides.
            if [[ "${partuuids[$i]^^}" == "${active_partuuid^^}" ]]; then
                active_idx="$i"
                break
            fi
        done
    fi

    # 2.5) loader.conf told us nothing useful — most commonly a LUKS
    # root, where the cmdline uses `rd.luks.uuid=...` and `root=/dev/mapper/...`
    # (no PARTUUID), so step 2 returned an empty string. When ab-install
    # is being run from a booted A/B system, the kernel itself knows
    # which partition `/` is mounted from; walk through any LUKS / dm
    # layers to find that partition's PARTUUID and match it.
    if (( active_idx < 0 )); then
        local mounted_pu
        mounted_pu="$(detect_active_root_partuuid 2>/dev/null || true)"
        if [[ -n "$mounted_pu" ]]; then
            for i in "${!candidates[@]}"; do
                if [[ "${partuuids[$i]^^}" == "${mounted_pu^^}" ]]; then
                    active_idx="$i"
                    active_partuuid="$mounted_pu"
                    echo "==> --reflash: matched active slot via mounted root: ${candidates[$i]}"
                    break
                fi
            done
        fi
    fi

    if (( active_idx >= 0 )); then
        for i in "${!candidates[@]}"; do
            if (( i != active_idx )); then
                ROOT_PART="${candidates[$i]}"
                echo "==> --reflash: selected inactive slot $ROOT_PART"
                echo "    (active is ${candidates[$active_idx]} PARTUUID=${active_partuuid})"
                return 0
            fi
        done
    fi

    # 3) Couldn't identify the active slot. With --yes pick the first
    # non-_empty candidate deterministically. Otherwise fall through
    # to the existing interactive picker.
    echo "==> --reflash: could not determine the active slot from loader.conf or live root"
    echo "    (loader.conf default=$(read_default_entry_root_partuuid || echo none))"
    if [[ "$ASSUME_YES" == true ]]; then
        ROOT_PART="${candidates[0]}"
        echo "==> --reflash: --yes, defaulting to first candidate $ROOT_PART (PARTLABEL=${labels[0]})"
        return 0
    fi
    select_root_slot_for_seed
}

# Walk from / through any LUKS / device-mapper layers to the underlying
# partition and return its GPT PARTUUID. This is the right answer for
# "which root slot is the running system booted from?" when the system
# is actually live (e.g. ab-install run from inside an A/B install),
# even when the boot cmdline uses rd.luks.uuid= rather than
# root=PARTUUID= and so loader.conf parsing alone can't tell the
# slots apart.
detect_active_root_partuuid() {
    local root_src dm_name slave_dir slave guard=0
    command -v findmnt >/dev/null 2>&1 || return 1
    command -v blkid   >/dev/null 2>&1 || return 1

    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    [[ -n "$root_src" ]] || return 1

    while [[ "$root_src" == /dev/mapper/* || "$root_src" == /dev/dm-* ]]; do
        (( guard++ < 8 )) || return 1
        dm_name="$(basename "$(readlink -f "$root_src" 2>/dev/null || echo "$root_src")")"
        slave_dir="/sys/class/block/$dm_name/slaves"
        [[ -d "$slave_dir" ]] || return 1
        slave="$(ls "$slave_dir" 2>/dev/null | head -n1)"
        [[ -n "$slave" ]] || return 1
        root_src="/dev/$slave"
    done

    blkid -s PARTUUID -o value "$root_src" 2>/dev/null
}

# --- end --reflash helpers -------------------------------------------------

# Seed the chosen ROOT_PART with ${prefix}.root.raw and relabel it to
# ${IMAGE_ID}_${IMAGE_VERSION}. This replaces the previous
# systemd-sysupdate --image seeding flow.
seed_first_root_slot() {
    local prefix partnum new_label

    [[ -n "${ARTIFACT_PREFIX:-}" ]] \
        || die "seed_first_root_slot: ARTIFACT_PREFIX not set (load_build_metadata not called?)"

    prefix="$ARTIFACT_PREFIX"
    [[ -f "$SOURCE_DIR/${prefix}.root.raw" ]] \
        || die "root filesystem image not found: $SOURCE_DIR/${prefix}.root.raw"

    if [[ "$REFLASH" == true ]]; then
        select_inactive_root_slot_for_reseed
    else
        select_root_slot_for_seed
    fi
    
    # Write the filesystem image into the chosen partition
    echo "==> Writing root filesystem image into $ROOT_PART from ${prefix}.root.raw"
    dd if="$SOURCE_DIR/${prefix}.root.raw" of="$ROOT_PART" bs=4M status=progress conv=fsync
    
    # Detect the root filesystem type so LUKS-specific paths skip steps
    # that only apply to plain ext4 roots.
    local root_fstype
    root_fstype="$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null || true)"
    echo "==> Detected root partition type: ${root_fstype:-unknown}"

    # Grow the ext4 filesystem to fill the partition (best-effort).
    # Skip entirely for LUKS: e2fsck misreads the LUKS header as a corrupt
    # ext4 superblock and irrecoverably overwrites LUKS metadata.
    if [[ "$root_fstype" == "crypto_LUKS" ]]; then
        echo "==> Root is LUKS-encrypted; skipping e2fsck/resize2fs"
    elif command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
        echo "==> Running e2fsck + resize2fs on $ROOT_PART"
        e2fsck -f -y "$ROOT_PART" || true
        resize2fs "$ROOT_PART" || true
    else
        echo "WARNING: e2fsck/resize2fs not available; skipping filesystem grow step" >&2
    fi
    
    # Update the GPT PARTLABEL for this partition so it encodes
    # IMAGE_ID + IMAGE_VERSION. We assume util-linux (sfdisk) is present.
    new_label="${IMAGE_ID}_${IMAGE_VERSION}"
    partnum="${ROOT_PART##*[!0-9]}"
    if command -v sfdisk >/dev/null 2>&1; then
        if [[ -n "$partnum" ]]; then
            echo "==> Setting GPT PARTLABEL for $ROOT_PART -> $new_label"
            sfdisk --part-label "$DISK_DEVICE" "$partnum" "$new_label" || \
                echo "WARNING: failed to update PARTLABEL for $ROOT_PART" >&2
        else
            echo "WARNING: could not determine partition number for $ROOT_PART; PARTLABEL unchanged" >&2
        fi
    else
        echo "WARNING: sfdisk not available; leaving PARTLABEL for $ROOT_PART unchanged" >&2
    fi
    
    # Wait for block devices to reappear after sfdisk altered the partition table
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 >/dev/null 2>&1 || true
    fi
    
    # A tiny sleep ensures that even if udevadm returns instantly, the kernel has 
    # definitely finished recreating the /dev/sdaX nodes before mount fires.
    sleep 2
    
    # Mount the seeded root for bundle copy
    ROOT_MOUNT="$(mktemp -d /tmp/ab-live-root.XXXXXX)"
    echo "==> Mounting seeded root $ROOT_PART on $ROOT_MOUNT"
    if [[ "$root_fstype" == "crypto_LUKS" ]]; then
        command -v cryptsetup >/dev/null 2>&1 \
            || die "cryptsetup is required to mount a LUKS-encrypted root; install cryptsetup on the build host"
        # ── Passphrase handling ───────────────────────────────────────────
        # Write passphrase to a chmod-600 tmpfile so luksOpen and resize
        # both use --key-file= (no pipe/stdin races). Loop on empty input
        # or wrong passphrase so a stray Enter from a previous step does
        # not silently abort the flash.
        local _luks_pass_file
        _luks_pass_file="$(mktemp /tmp/ab-luks-pass.XXXXXX)"
        chmod 600 "$_luks_pass_file"
        LUKS_PASS_FILE="$_luks_pass_file"   # registered for cleanup

        local luks_map="ab-live-root-luks-$$"

        if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
            # Passphrase already supplied externally (e.g. by a parent script).
            printf '%s' "$LUKS_PASSPHRASE" > "$_luks_pass_file"
            echo "==> Opening LUKS container $ROOT_PART -> /dev/mapper/$luks_map"
            cryptsetup luksOpen "$ROOT_PART" "$luks_map" --key-file="$_luks_pass_file"
        else
            echo "==> $ROOT_PART is LUKS-encrypted and no passphrase was supplied"
            local _luks_attempts=0
            while true; do
                (( _luks_attempts++ )) || true
                LUKS_PASSPHRASE=""
                read -rsp "    Enter LUKS passphrase (input hidden, not saved to history): " \
                    LUKS_PASSPHRASE </dev/tty
                echo >&2   # newline after hidden input
                if [[ -z "$LUKS_PASSPHRASE" ]]; then
                    echo "    (empty passphrase — please try again)" >&2
                    continue
                fi
                printf '%s' "$LUKS_PASSPHRASE" > "$_luks_pass_file"
                echo "==> Opening LUKS container $ROOT_PART -> /dev/mapper/$luks_map"
                if cryptsetup luksOpen "$ROOT_PART" "$luks_map" \
                        --key-file="$_luks_pass_file" 2>/dev/null; then
                    break   # success
                fi
                # Wrong passphrase — clear file and retry
                printf '%s' "" > "$_luks_pass_file"
                if (( _luks_attempts >= 5 )); then
                    die "Failed to open LUKS container $ROOT_PART after 5 attempts"
                fi
                echo "    Incorrect passphrase (attempt $_luks_attempts/5), try again." >&2
            done
        fi
        LUKS_MAP="$luks_map"
        # The .root.raw image is smaller than the allocated partition.
        # Expand the LUKS container to fill the full partition, then grow
        # the inner filesystem to match — otherwise the root has no free
        # space for the installer bundle.
        echo "==> Expanding LUKS container $luks_map to fill partition $ROOT_PART"
        cryptsetup resize "$luks_map" --key-file="$_luks_pass_file"
        if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
            echo "==> Running e2fsck + resize2fs on /dev/mapper/$luks_map"
            e2fsck -f -y "/dev/mapper/$luks_map" || true
            resize2fs "/dev/mapper/$luks_map" || true
        else
            echo "WARNING: e2fsck/resize2fs not available; inner filesystem not grown" >&2
        fi
        mount "/dev/mapper/$luks_map" "$ROOT_MOUNT"
    else
        mount "$ROOT_PART" "$ROOT_MOUNT"
    fi

    # Determine PARTUUID of the seeded root partition for boot entry
    local root_partuuid="" luks_uuid=""
    if command -v blkid >/dev/null 2>&1; then
        root_partuuid="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
        if [[ -z "$root_partuuid" ]]; then
            echo "WARNING: could not determine PARTUUID for $ROOT_PART; boot entry will not be patched" >&2
        else
            echo "==> Seeded root PARTUUID: $root_partuuid"
        fi
        # For LUKS roots, also capture the LUKS header UUID (different from PARTUUID).
        # blkid -s UUID on a LUKS partition returns the UUID stored inside the LUKS
        # header, which is what rd.luks.uuid= / cryptdevice=UUID= must reference.
        if [[ "$root_fstype" == "crypto_LUKS" ]]; then
            luks_uuid="$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || true)"
            [[ -n "$luks_uuid" ]] && echo "==> LUKS container UUID: $luks_uuid"
        fi
    else
        echo "WARNING: blkid not available; boot entry will not be patched with PARTUUID." >&2
    fi

    # --- Seed the ESP ---
    # We also need to copy the UKI (.efi) and bootloader entry (.conf) to the ESP,
    # because we skipped systemd-sysupdate which normally handles this step.
    
    # Wait for udev to see the new partitions from systemd-repart
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=5 >/dev/null 2>&1 || true
    fi
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt "$DISK_DEVICE" >/dev/null 2>&1 || true
    fi
    
    local esp_part="" line NAME PARTLABEL FSTYPE TYPE
    while read -r line; do
        eval "$line"
        [[ "$TYPE" == "part" ]] || continue
        if [[ "$PARTLABEL" == "ESP" ]]; then
            esp_part="$NAME"
            break
        fi
    done < <(lsblk -P -npo NAME,PARTLABEL,FSTYPE,TYPE "$DISK_DEVICE")
    if [[ -n "$esp_part" ]]; then
        local esp_mount
        esp_mount="$(mktemp -d /tmp/ab-live-esp.XXXXXX)"
        echo "==> Mounting ESP $esp_part to seed bootloader files"
        mount "$esp_part" "$esp_mount"
        
        install -d -m 0755 "$esp_mount/EFI/Linux" "$esp_mount/loader/entries"

        # In --reflash mode the entry filename is suffixed with the
        # target slot's basename so both A and B slots can coexist as
        # named entries in /loader/entries/. The previously-default
        # entry stays in place as a known-good fallback you can pick
        # from the systemd-boot menu if the new one fails to come up.
        # In fresh-write mode the entry file is just ${prefix}.conf
        # and any stale entries from a previous flash get wiped, since
        # the rest of the disk has already been repartitioned anyway.
        local entry_basename
        if [[ "$REFLASH" == true ]]; then
            entry_basename="${prefix}_$(basename "$ROOT_PART")"
            echo "==> --reflash: keeping previously-installed boot entries as fallback"
        else
            entry_basename="${prefix}"
            echo "==> Wiping old boot entries from USB ESP"
            rm -f "$esp_mount/loader/entries/"*.conf
            # Bootstrap repartitions the disk, so any old kernel /
            # initrd / standalone UKI in /EFI/Linux belongs to a slot
            # that no longer exists. Clear them out so the menu and
            # the ESP free space match the freshly-written layout.
            if [[ -d "$esp_mount/EFI/Linux" ]]; then
                rm -f "$esp_mount/EFI/Linux/"*.linux \
                      "$esp_mount/EFI/Linux/"*.initrd \
                      "$esp_mount/EFI/Linux/"*.efi
            fi
        fi

        # Set the new entry as the explicit default in loader.conf so
        # systemd-boot picks the freshly-flashed slot on next boot.
        echo "==> Setting ${entry_basename}.conf as the default boot entry"
        if [[ -f "$esp_mount/loader/loader.conf" ]]; then
            sed -i -E "s/^default .*/default ${entry_basename}.conf/" "$esp_mount/loader/loader.conf"
        else
            printf "default %s.conf\ntimeout 5\nconsole-mode keep\n" "${entry_basename}" > "$esp_mount/loader/loader.conf"
        fi
        
        # ── Extract kernel + initrd from the UKI for Type 1 BLS booting ──────────
        # Why not boot the UKI as Type 2: systemd-stub bakes its cmdline into the
        # .cmdline PE section at UKI build time. For Type 2 entries the .conf's
        # `options` line is treated inconsistently across systemd-boot versions
        # (sometimes appended, sometimes ignored), and the previous fix that
        # patched the UKI's .cmdline section in-place via `objcopy --update-section`
        # is fragile: PE section sizes are fixed at build, and growing the cmdline
        # past the existing pad shifts later sections, corrupting the UKI and
        # producing exactly the "boot failure with no useful message" symptom.
        #
        # Type 1 BLS sidesteps the whole problem: kernel and initrd are loaded
        # directly from named files on the ESP, and `options` in the .conf is
        # the authoritative cmdline. No post-build rewriting required.
        #
        # `objcopy -O binary --only-section=` is a *read* operation that emits a
        # fresh file — it does not mutate the UKI, so the PE-vs-ELF target
        # ambiguity that broke `--update-section` does not apply here.
        local _uki_src=""
        if [[ -f "$SOURCE_DIR/${prefix}.efi" ]]; then
            _uki_src="$SOURCE_DIR/${prefix}.efi"
        fi

        if [[ -n "$_uki_src" ]]; then
            if ! command -v objcopy >/dev/null 2>&1; then
                die "objcopy is required to extract kernel/initrd from the UKI; install binutils on the build host"
            fi

            local _kernel_dst="$esp_mount/EFI/Linux/${prefix}.linux"
            local _initrd_dst="$esp_mount/EFI/Linux/${prefix}.initrd"

            # We deliberately do NOT auto-delete other *.linux / *.initrd
            # pairs from /EFI/Linux. In --reflash mode the OTHER slot's
            # BLS entry references its own .linux/.initrd — deleting that
            # would brick the still-bootable fallback slot. Old versions
            # accumulate slowly (one extra pair per distinct version
            # reflashed); the 1G ESP is sized to absorb that.

            echo "==> Extracting .linux from UKI -> $(basename "$_kernel_dst")"
            objcopy -O binary --only-section=.linux "$_uki_src" "$_kernel_dst"
            echo "==> Extracting .initrd from UKI -> $(basename "$_initrd_dst")"
            objcopy -O binary --only-section=.initrd "$_uki_src" "$_initrd_dst"

            [[ -s "$_kernel_dst" ]] || die "extracted kernel from UKI is empty (.linux section missing or unreadable)"
            [[ -s "$_initrd_dst" ]] || die "extracted initrd from UKI is empty (.initrd section missing or unreadable)"

            chmod 0644 "$_kernel_dst" "$_initrd_dst"

            # Diagnostic: confirm the T2 keyboard/touchbar modules actually made
            # it into the initrd. Without these the built-in keyboard is dead
            # before the real root is up, so Ctrl+Alt+F<n> can't switch tty.
            if command -v lsinitramfs >/dev/null 2>&1; then
                if lsinitramfs "$_initrd_dst" 2>/dev/null | grep -qE 'apple_bce|apple-bce|apple_ib|apple-ib|appletb'; then
                    echo "==> Initrd contains Apple T2 keyboard/touchbar modules"
                else
                    echo "WARNING: initrd does NOT appear to contain apple_bce / apple_ib_* / appletb modules." >&2
                    echo "         Built-in MacBook keyboard will not work in early boot," >&2
                    echo "         and Ctrl+Alt+F<n> will not switch tty before /sysroot mounts." >&2
                    echo "         Use an external USB keyboard, or rebuild with mkosi.finalize" >&2
                    echo "         forcing update-initramfs after ExtraTrees are applied." >&2
                fi
            fi
        else
            die "no UKI found at $SOURCE_DIR/${prefix}.efi; cannot construct Type 1 BLS entry"
        fi

        if [[ -f "$SOURCE_DIR/${prefix}.conf" ]]; then
            # entry_basename is set above; in --reflash mode it's
            # ${prefix}_<root-slot-basename>, otherwise ${prefix}.
            local conf_dest="$esp_mount/loader/entries/${entry_basename}.conf"

            # Read source options (everything after the leading "options ").
            local _src_options
            _src_options="$(grep '^options ' "$SOURCE_DIR/${prefix}.conf" | sed 's/^options //')"

            # Replace any baked-in root= (the build-time value uses PARTLABEL,
            # but PARTUUID is what we just learned from the actual seeded slot).
            if [[ -n "$root_partuuid" ]]; then
                _src_options="$(echo "$_src_options" | sed -E 's#root=[^ ]*##g')"
                if [[ "$root_fstype" == "crypto_LUKS" && -n "$luks_uuid" ]]; then
                    # LUKS root: the initrd must unlock the LUKS container before it
                    # can mount /sysroot. rd.luks.uuid tells systemd-cryptsetup (or
                    # cryptsetup-initramfs) which container to unlock; the mapper
                    # device is then available as /dev/mapper/luks-<UUID>.
                    # Note: luks_uuid is the UUID from the LUKS header (blkid UUID),
                    # NOT the GPT PARTUUID — they are different values.
                    _src_options="rd.luks.uuid=$luks_uuid root=/dev/mapper/luks-$luks_uuid rootwait $_src_options"
                    echo "==> Setting rd.luks.uuid=$luks_uuid root=/dev/mapper/luks-$luks_uuid in boot entry"
                elif [[ "$root_fstype" == "crypto_LUKS" ]]; then
                    echo "WARNING: could not determine LUKS UUID; boot entry may not unlock the root" >&2
                    _src_options="root=PARTUUID=$root_partuuid rootwait $_src_options"
                    echo "==> Setting root=PARTUUID=$root_partuuid in boot entry (LUKS UUID unknown)"
                else
                    _src_options="root=PARTUUID=$root_partuuid rootfstype=ext4 rootwait $_src_options"
                    echo "==> Setting root=PARTUUID=$root_partuuid in boot entry"
                fi
            else
                echo "WARNING: root PARTUUID unknown; leaving boot entry root= unchanged." >&2
            fi

            if [[ "$DIAGNOSTIC_MODE" == true ]]; then
                echo "==> Diagnostic mode: appending initrd debug params to boot entry"
                _src_options="${_src_options//quiet/}"
                # initramfs-tools-only flags (no rd.break, no
                # systemd.unit=debug-shell.service — both have caused boot
                # regressions before and neither helps here).
                local _diag_extras="break=mount break=bottom panic=0 loglevel=7 earlyprintk=vga systemd.log_level=debug systemd.log_target=console systemd.journald.forward_to_console=1 console=tty0 systemd.show_status=1 systemd.setenv=SYSTEMD_SULOGIN_FORCE=1 systemd.debug-shell=1"
                for p in $_diag_extras; do
                    if ! grep -qw "$p" <<<"$_src_options"; then
                        _src_options="$_src_options $p"
                    fi
                done
            fi

            # Collapse whitespace so the final cmdline is tidy in logs.
            _src_options="$(echo "$_src_options" | tr -s ' ' | sed -E 's#^ +##; s# +$##')"

            # Write a Type 1 BLS entry. Crucially: NO `uki` line, so systemd-boot
            # uses linux=/initrd=/options= directly and does not look for an
            # embedded cmdline.
            local _slot_tag=""
            [[ "$REFLASH" == true ]] && _slot_tag=" [slot=$(basename "$ROOT_PART")]"

            {
                echo "# Generated by bin/ab-install.sh (Type 1 BLS for live-test USB)"
                echo "title Debian TEST BOOT (${IMAGE_ID}) ${IMAGE_VERSION}${_slot_tag}"
                # sort-key includes slot basename so multiple coexisting
                # entries (one per slot) sort deterministically in the
                # systemd-boot menu instead of all collapsing on top of
                # each other and confusing the user about which is which.
                echo "sort-key ${IMAGE_ID}_$(basename "$ROOT_PART")"
                echo "version ${IMAGE_VERSION}"
                echo "linux /EFI/Linux/${prefix}.linux"
                echo "initrd /EFI/Linux/${prefix}.initrd"
                echo "options ${_src_options}"
            } > "$conf_dest"

            echo "==> Wrote Type 1 BLS boot entry: $conf_dest"
            echo "    cmdline: ${_src_options}"

            # Now that the new entry is in place, prune anything that
            # has been left behind from prior reflashes / image
            # versions / re-bootstraps. The user reported boot menus
            # accumulating dozens of stale entries; this cap brings
            # it back to "one entry per current root slot".
            prune_old_boot_entries "$esp_mount" "$conf_dest"
        fi

        umount "$esp_mount"
        rmdir "$esp_mount"
    else
        echo "WARNING: Could not locate ESP partition to copy bootloader files." >&2
    fi
}

# Resolve COPY_INSTALL_BUNDLE=auto into yes/no based on whether the
# target is a removable device. Idempotent: when the user already
# passed --copy-install-bundle / --no-copy-install-bundle the global
# is already yes/no and this function is a no-op. Falls back to "yes"
# (current behavior, copy everything) when removable status can't be
# determined — better to over-copy and leave a working re-flash kit
# than to silently strip artifacts the operator might have expected.
resolve_copy_install_bundle() {
  [[ "$COPY_INSTALL_BUNDLE" == "auto" ]] || return 0
  local removable
  removable="$(ab_confirm_removable_flag "$TARGET")"
  case "$removable" in
    1) COPY_INSTALL_BUNDLE=yes ;;
    0) COPY_INSTALL_BUNDLE=no ;;
    *) COPY_INSTALL_BUNDLE=yes ;;
  esac
}

required_bundle_files() {
  local prefix="$ARTIFACT_PREFIX"
  printf '%s\n' \
    "$SCRIPT_PATH" \
    "$SOURCE_DIR/${prefix}.conf" \
    "$SOURCE_DIR/${prefix}.artifacts.env" \
    "$SOURCE_DIR/SHA256SUMS" \
    "$SOURCE_DIR/build.env"

  if [[ "$COPY_INSTALL_BUNDLE" == "yes" ]]; then
    printf '%s\n' \
      "$SOURCE_DIR/${prefix}.root.raw" \
      "$SOURCE_DIR/${prefix}.efi"
  fi

  if [[ "$EMBED_FULL_IMAGE" == true ]]; then
    printf '%s\n' "$SOURCE_DIR/$IMAGE_BASENAME"
  fi
}

bundle_bytes_required() {
  local total=0 file size
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ -e "$file" ]] || die "bundle source file not found: $file"
    size="$(stat -Lc '%s' "$file")"
    total=$((total + size))
  done < <(required_bundle_files)
  printf '%s\n' "$total"
}

copy_file_preserving_layout() {
  local src="$1"
  local dest="$2"
  install -D -m 0644 "$src" "$dest"
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

prepare_bootstrap_repart_dir() {
  TEMP_REPART_DIR="$(mktemp -d /tmp/ab-usb-repart.XXXXXX)"
  BOOTSTRAP_REPART_DIR="$TEMP_REPART_DIR"

  # Auto-size root slots from the .root.raw image size when the user has not
  # given an explicit --root-size. Each slot gets 3× the raw image size,
  # rounded up to the next whole GiB, so the slot comfortably holds:
  #   (1) the dd'd OS image itself
  #   (2) the full installer bundle (includes another copy of .root.raw)
  #   (3) headroom for the image to grow over many A/B reflash cycles
  #
  # Example: 6 GiB raw → 18 GiB per slot → 36 GiB total (A+B).
  # On a 64 GiB disk: 1 GiB ESP + 36 GiB roots + ~27 GiB DATA.
  # Pass --root-size explicitly to override.
  if [[ -z "$USB_ROOT_SIZE" && -n "${ARTIFACT_PREFIX:-}" ]]; then
    local _raw_path="$SOURCE_DIR/${ARTIFACT_PREFIX}.root.raw"
    if [[ -f "$_raw_path" ]]; then
      local _raw_bytes _gib=$((1024 * 1024 * 1024))
      _raw_bytes="$(stat -Lc '%s' "$_raw_path" 2>/dev/null || echo 0)"
      if [[ "$_raw_bytes" =~ ^[0-9]+$ ]] && (( _raw_bytes > 0 )); then
        local _target_bytes=$(( _raw_bytes * 3 ))
        local _target_gib=$(( (_target_bytes + _gib - 1) / _gib ))
        local _raw_gib=$(( (_raw_bytes + _gib - 1) / _gib ))
        USB_ROOT_SIZE="${_target_gib}G"
        echo "==> Auto-sized root slots: ${_target_gib}G each"              "(3× ~${_raw_gib}G raw; ${_target_gib}G × 2 = $(( _target_gib * 2 ))G total for A+B)"
      fi
    fi
  fi

  # Base ESP + A/B layout. Inlined defaults so the script does not
  # depend on deploy.repart/*.conf existing on disk — the on-target
  # invocation runs from /root/ where there is no repo. --repart-dir
  # still exists as an escape hatch for advanced users who want to
  # supply their own confs (any *.conf in the directory is copied
  # in before the size overrides below).
  if [[ -n "$REPART_DIR" && -d "$REPART_DIR" ]] && compgen -G "$REPART_DIR/*.conf" >/dev/null 2>&1; then
    cp "$REPART_DIR"/*.conf "$TEMP_REPART_DIR/"
  fi
  : "${USB_ESP_SIZE:=1G}"
  : "${USB_ROOT_SIZE:=8G}"
  write_fixed_partition_conf "$TEMP_REPART_DIR/00-esp.conf" esp ESP "$USB_ESP_SIZE" vfat
  write_fixed_partition_conf "$TEMP_REPART_DIR/10-root-a.conf" root _empty "$USB_ROOT_SIZE" ext4
  write_fixed_partition_conf "$TEMP_REPART_DIR/11-root-b.conf" root _empty "$USB_ROOT_SIZE" ext4

  # HOME / DATA partitions are part of the unified layout model. Each
  # token can be 'none' (skip), 'rest' (no Size*Bytes so systemd-repart
  # grows it into whatever's left), or an explicit size.
  # validate_layout_tokens has already made sure at most one of the
  # two asked for 'rest'.
  rm -f "$TEMP_REPART_DIR/20-home.conf" \
        "$TEMP_REPART_DIR/30-data.conf"

  case "$HOME_SIZE_TOKEN" in
    none)
      ;;
    rest)
      write_flexible_partition_conf "$TEMP_REPART_DIR/20-home.conf" home HOME 2G ext4
      ;;
    *)
      write_fixed_partition_conf "$TEMP_REPART_DIR/20-home.conf" home HOME "$HOME_SIZE_TOKEN" ext4
      ;;
  esac

  case "$DATA_SIZE_TOKEN" in
    none)
      ;;
    rest)
      write_flexible_partition_conf "$TEMP_REPART_DIR/30-data.conf" linux-generic DATA 2G ext4
      ;;
    *)
      write_fixed_partition_conf "$TEMP_REPART_DIR/30-data.conf" linux-generic DATA "$DATA_SIZE_TOKEN" ext4
      ;;
  esac
}

# Helper for "give this partition at least N bytes, but grow it into
# whatever space is left after the fixed-size partitions". Mirrors what
# the on-target install path used to do locally; lifted here so the
# unified layout generator owns both shapes.
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

find_esp_partition() {
  local part label fstype
  while read -r part label fstype; do
    if [[ "$label" == "ESP" || "$fstype" == "vfat" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
  done < <(lsblk -nrpo NAME,PARTLABEL,FSTYPE "$DISK_DEVICE")
  return 1
}

wait_for_esp_partition() {
  local part="" i
  command -v udevadm >/dev/null 2>&1 && udevadm settle >/dev/null 2>&1 || true
  command -v partprobe >/dev/null 2>&1 && partprobe "$DISK_DEVICE" >/dev/null 2>&1 || true
  command -v blockdev >/dev/null 2>&1 && blockdev --rereadpt "$DISK_DEVICE" >/dev/null 2>&1 || true
  for i in $(seq 1 20); do
    part="$(find_esp_partition || true)"
    if [[ -n "$part" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=5 >/dev/null 2>&1 || true
    sleep 0.5
  done
  return 1
}

write_loader_conf() {
  local path="$1"
  install -d -m 0755 "$(dirname "$path")"
  cat > "$path" <<EOF
# Managed by bin/ab-install.sh
default *@saved
editor yes
timeout $LOADER_TIMEOUT
console-mode keep
EOF
}

# Inlined replacement for the previous inlined bootstrap_disk()
# subprocess. Runs systemd-repart against the prepared definitions
# directory, finds and mounts the freshly-formatted ESP, installs
# systemd-boot via bootctl, writes loader.conf, and releases the ESP
# so the seed step that follows has a clean view of the disk.
bootstrap_disk() {
  echo "==> Repartitioning $TARGET with systemd-repart"
  systemd-repart --dry-run=no --empty=force \
    --definitions="$BOOTSTRAP_REPART_DIR" "$TARGET_FOR_SYSUPDATE"

  # Refresh the loop attach so DISK_DEVICE points at the new partition
  # layout. Block-device targets don't need this because the kernel
  # rescans automatically.
  if [[ -n "${LOOPDEV:-}" ]]; then
    losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
    LOOPDEV="$(losetup --find --show --partscan "$TARGET_FOR_SYSUPDATE")"
    DISK_DEVICE="$LOOPDEV"
  fi

  local esp_part esp_mount
  esp_part="$(wait_for_esp_partition)" \
    || die "unable to locate ESP partition after repart"
  esp_mount="$(mktemp -d /tmp/ab-esp.XXXXXX)"
  mount "$esp_part" "$esp_mount"

  echo "==> Installing systemd-boot into target ESP"
  bootctl --esp-path="$esp_mount" --no-variables install
  write_loader_conf "$esp_mount/loader/loader.conf"

  umount "$esp_mount"
  rmdir "$esp_mount"
  sync
  command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=10 >/dev/null 2>&1 || true
}

wait_for_seeded_root_partition() {
  local part="" i
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle >/dev/null 2>&1 || true
  fi
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$DISK_DEVICE" >/dev/null 2>&1 || true
  fi
  if command -v blockdev >/dev/null 2>&1; then
    blockdev --rereadpt "$DISK_DEVICE" >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 20); do
    part="$(find_seeded_root_partition || true)"
    if [[ -n "$part" ]]; then
      printf '%s\n' "$part"
      return 0
    fi
    if command -v udevadm >/dev/null 2>&1; then
      udevadm settle --timeout=5 >/dev/null 2>&1 || true
    fi
    sleep 0.5
  done
  return 1
}

copy_bundle() {
  # Flat layout under /root/ — no subdirectory, no separate scripts.
  # Everything the installer needs at runtime lives next to the script:
  #
  #   /root/ab-install.sh                      ← the script itself (this file)
  #   /root/<prefix>.root.raw                  ← what gets dd'd into a root slot
  #   /root/<prefix>.efi                       ← UKI for systemd-boot
  #   /root/<prefix>.conf                      ← BLS entry source
  #   /root/<prefix>.artifacts.env             ← per-build artifact metadata
  #   /root/build.env                          ← image-id / version / arch
  #   /root/SHA256SUMS                         ← integrity check
  #   /root/USB-IDENTITY.env                   ← cross-flash identity probe
  #   /root/INSTALL-TO-INTERNAL-DISK.sh        ← muscle-memory alias for ab-install.sh
  #   /root/<full-image>.raw                   ← only when --embed-full-image
  local out="$ROOT_MOUNT/root"
  local required avail headroom
  required="$(bundle_bytes_required)"
  avail="$(df -B1 --output=avail "$ROOT_MOUNT" | tail -n1 | tr -d '[:space:]')"
  headroom=$((256 * 1024 * 1024))

  if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < required + headroom )); then
    die "root filesystem on $ROOT_PART has $(( avail / 1024 / 1024 )) MiB free; the installer payload needs about $(( (required + headroom) / 1024 / 1024 )) MiB. Re-run with --root-size set large enough to hold the dd'd image plus the payload (3× the .root.raw size is a safe rule of thumb)."
  fi

  install -d -m 0700 "$out"
  # `install -d -m MODE` only sets the mode on directories it CREATES;
  # an existing /root from the dd'd .root.raw keeps whatever mode it
  # was built with. Force 0700 explicitly so a pre-existing 0755 from
  # the source image is corrected here too. (mkosi.finalize also
  # locks /root at build time, but defense-in-depth: re-running the
  # installer over an older image needs the same lock applied.)
  chmod 0700 "$out"

  # The script itself. This is the SAME file you ran to create this
  # disk; copying it verbatim guarantees /root/ab-install.sh on the
  # target behaves identically when invoked there.
  echo "==> Copying ab-install.sh into $out"
  install -m 0755 "$SCRIPT_PATH" "$out/ab-install.sh"

  # Lightweight identity artifacts (always copied — these total a few
  # tens of KB and serve as a self-describing "what is installed here"
  # record that survives even when the heavy bundle is skipped).
  local prefix="$ARTIFACT_PREFIX"
  echo "==> Copying image identity files into $out"
  install -m 0644 "$SOURCE_DIR/${prefix}.conf"          "$out/${prefix}.conf"
  install -m 0644 "$SOURCE_DIR/${prefix}.artifacts.env" "$out/${prefix}.artifacts.env"
  install -m 0644 "$SOURCE_DIR/SHA256SUMS"              "$out/SHA256SUMS"
  install -m 0644 "$SOURCE_DIR/build.env"               "$out/build.env"

  # Heavy artifacts. Skipped when COPY_INSTALL_BUNDLE=no (the auto
  # default for fixed-disk targets), because a workstation has the
  # project clone and burning 3-4 GiB of root space on a duplicate
  # of the .root.raw + UKI is just dead weight.
  if [[ "$COPY_INSTALL_BUNDLE" == "yes" ]]; then
    echo "==> Copying re-flash bundle into $out (.root.raw, .efi)"
    install -m 0644 "$SOURCE_DIR/${prefix}.root.raw"    "$out/${prefix}.root.raw"
    install -m 0644 "$SOURCE_DIR/${prefix}.efi"         "$out/${prefix}.efi"
  else
    echo "==> Skipping re-flash bundle (.root.raw, .efi) — fixed-disk target"
    echo "    Pass --copy-install-bundle to force-include them."
  fi

  if [[ "$EMBED_FULL_IMAGE" == true ]]; then
    [[ -f "$SOURCE_DIR/$IMAGE_BASENAME" ]] \
      || die "--embed-full-image was requested but the full disk image is not in $SOURCE_DIR ($IMAGE_BASENAME). Run ./build.sh on the host first, or drop --embed-full-image."
    install -m 0644 "$SOURCE_DIR/$IMAGE_BASENAME"       "$out/$IMAGE_BASENAME"
  fi

  # Muscle-memory alias. Only useful when the heavy bundle is also
  # present, since the script needs *.root.raw next to itself to do
  # any work. Skip it on fixed-disk installs to avoid leaving a
  # launcher that just dies with "no *.root.raw" the moment someone
  # runs it.
  if [[ "$COPY_INSTALL_BUNDLE" == "yes" ]]; then
    cat > "$out/INSTALL-TO-INTERNAL-DISK.sh" <<'LAUNCHER'
#!/usr/bin/env bash
exec /root/ab-install.sh "$@"
LAUNCHER
    chmod 0755 "$out/INSTALL-TO-INTERNAL-DISK.sh"
  fi

  if [[ "$COPY_INSTALL_BUNDLE" == "yes" ]]; then
    cat > "$out/README.txt" <<EOF
Install payload (laid down by bin/ab-install.sh)
================================================

This disk was bootstrapped from build:
  image id:      $IMAGE_ID
  image version: $IMAGE_VERSION
  arch:          $IMAGE_ARCH

Recommended workflow after booting:
  sudo /root/ab-install.sh

(For muscle memory, /root/INSTALL-TO-INTERNAL-DISK.sh is a thin alias.)

The script auto-detects the image artifacts in /root/ next to itself,
so it asks the same questions it asked the build host: target disk,
ESP / root / home / data sizes. Default layout:
  - 1G ESP
  - two retained root partitions of 8G each
  - /mnt/data taking the rest of the disk (persistent across A/B swaps)

To iterate on the build without losing the disk's DATA partition,
use --reflash on the host:
  sudo ./bin/ab-install.sh --target /dev/sdX --reflash --yes
That writes the new image into whichever root slot is NOT currently the
default-boot slot, leaves the active slot in place as a known-good
fallback, and does not repartition or wipe DATA.

Subsequent in-place updates of the *internal* disk after install go
through systemd-sysupdate (./bin/sysupdate-local-update.sh on the
build host or its bundled copy when shipped) and only ever rewrite
the inactive root slot; HOME / DATA / ESP partition data is preserved.
EOF
  else
    cat > "$out/README.txt" <<EOF
Install identity (laid down by bin/ab-install.sh)
=================================================

This disk was bootstrapped from build:
  image id:      $IMAGE_ID
  image version: $IMAGE_VERSION
  arch:          $IMAGE_ARCH

Only the lightweight identity files were copied here (build.env,
SHA256SUMS, ${ARTIFACT_PREFIX}.conf, ${ARTIFACT_PREFIX}.artifacts.env,
ab-install.sh). The heavy install bundle (.root.raw, .efi) was NOT
copied, because this is a fixed-disk install where you operate from
the project clone instead. To re-flash:

  cd /path/to/debian-system-image-provisioning
  sudo ./bin/ab-install.sh --host <hostname> --reflash --yes

Subsequent in-place updates go through systemd-sysupdate
(./bin/sysupdate-local-update.sh) and only ever rewrite the inactive
root slot; HOME / DATA / ESP partition data is preserved.

If you want the full re-flash kit on the disk anyway (so this machine
can re-image other targets without the project clone), re-run the
install with --copy-install-bundle.
EOF
  fi
  chmod 0644 "$out/README.txt"

  # Drop the identity file that the NEXT flash's
  # ab_confirm_read_existing_identity looks for. The git rev is
  # best-effort; lands as 'unknown' if the build happened outside a
  # git checkout.
  local git_rev
  git_rev="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  ab_confirm_write_usb_identity \
    "$out/USB-IDENTITY.env" \
    "${AB_LAST_BUILD_PROFILE:-unknown}" \
    "${AB_LAST_BUILD_HOST:-}" \
    "$IMAGE_ID" \
    "$IMAGE_VERSION" \
    "$IMAGE_ARCH" \
    "$git_rev"
}

# Detect whether the source .root.raw is LUKS-encrypted and, if so, collect
# and verify the passphrase BEFORE the long-running bootstrap begins. This
# lets the operator type the passphrase once at the start and then walk away
# until the USB is ready — no surprise prompt after a 20-minute dd.
#
# If --luks-passphrase was already supplied on the command line, this is a
# no-op (we still verify it against the image so a typo is caught early).
preflight_collect_luks_passphrase() {
  local raw_path="$SOURCE_DIR/${ARTIFACT_PREFIX}.root.raw"

  # Can't pre-check if the image file doesn't exist yet (should never happen
  # at this point, but be defensive).
  [[ -f "$raw_path" ]] || return 0

  # Use cryptsetup isLuks to detect LUKS without needing blkid TYPE parsing.
  if ! command -v cryptsetup >/dev/null 2>&1; then
    return 0  # cryptsetup not available; LUKS will be caught later if needed
  fi
  if ! cryptsetup isLuks "$raw_path" 2>/dev/null; then
    return 0  # not LUKS-encrypted
  fi

  echo "==> Source image is LUKS-encrypted."
  echo "    Collecting passphrase now so the flash can run unattended."

  local attempts=0 tmp_key tmp_map
  tmp_key="$(mktemp /tmp/ab-luks-preflight.XXXXXX)"
  chmod 600 "$tmp_key"
  # No global EXIT trap needed — we shred tmp_key on every return path below.

  while true; do
    (( attempts++ )) || true

    if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
      # Passphrase was supplied via --luks-passphrase; verify it once.
      printf '%s' "$LUKS_PASSPHRASE" > "$tmp_key"
    else
      read -rsp "  Enter LUKS passphrase: " LUKS_PASSPHRASE </dev/tty
      echo >&2
      if [[ -z "$LUKS_PASSPHRASE" ]]; then
        echo "  (empty passphrase — please try again)" >&2
        LUKS_PASSPHRASE=""
        continue
      fi
      printf '%s' "$LUKS_PASSPHRASE" > "$tmp_key"
    fi

    # --test-passphrase verifies the key slot without actually opening the
    # device, so it works on both block devices and regular files.
    tmp_map="ab-luks-preflight-verify-$$"
    if cryptsetup luksOpen --test-passphrase "$raw_path"          --key-file="$tmp_key" 2>/dev/null; then
      echo "==> LUKS passphrase verified. Flash will proceed unattended."
      break
    fi

    echo "  Incorrect passphrase (attempt $attempts/5)." >&2
    LUKS_PASSPHRASE=""
    if (( attempts >= 5 )); then
      shred -u "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
      die "Failed to verify LUKS passphrase after 5 attempts"
    fi
  done

  shred -u "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
}


while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:?missing target path}"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="${2:?missing build dir}"
      shift 2
      ;;
    --repart-dir)
      REPART_DIR="${2:?missing repart dir}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:?missing profile name}"
      shift 2
      ;;
    --host)
      HOST="${2:?missing host name}"
      shift 2
      ;;
    --loader-timeout)
      LOADER_TIMEOUT="${2:?missing loader timeout}"
      shift 2
      ;;
    --esp-size|--usb-esp-size)
      USB_ESP_SIZE="${2:?missing ESP size}"
      shift 2
      ;;
    --root-size|--usb-root-size)
      USB_ROOT_SIZE="${2:?missing root size}"
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
    --embed-full-image)
      EMBED_FULL_IMAGE=true
      shift
      ;;
    --no-embed-full-image)
      EMBED_FULL_IMAGE=false
      shift
      ;;
    --copy-install-bundle)
      COPY_INSTALL_BUNDLE=yes
      shift
      ;;
    --no-copy-install-bundle)
      COPY_INSTALL_BUNDLE=no
      shift
      ;;
    --allow-fixed-disk)
      ALLOW_FIXED_DISK=yes
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --diagnostic-mode)
      DIAGNOSTIC_MODE=true
      shift
      ;;
    --luks-passphrase)
      LUKS_PASSPHRASE="${2:?missing passphrase}"
      shift 2
      ;;
    --reflash)
      MODE="reflash"
      shift
      ;;
    --reimage|--repartition)
      MODE="repartition"
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

[[ $EUID -eq 0 ]] || die "ab-install.sh must run as root"

# No --target given: try the boot disk. If the running system already
# lives on an A/B layout, the only meaningful target is "the disk we
# booted from" — auto-mode will then pick the inactive slot via
# select_inactive_root_slot_for_reseed. Detection is gated on the boot
# disk having an existing A/B layout so this does not silently pick
# the wrong device when running from a plain rescue / installer
# environment that happens to have / mounted somewhere.
if [[ -z "$TARGET" ]]; then
  _candidate_target="$(detect_boot_disk 2>/dev/null || true)"
  if [[ -n "$_candidate_target" && -b "$_candidate_target" ]]; then
    TARGET="$_candidate_target"
    if detect_existing_ab_layout; then
      TARGET_AUTO_DETECTED=true
      echo "==> Auto-detected target: $TARGET (boot disk; has an existing A/B layout)"
      echo "    Will write to the inactive root slot. Pass --target to override."
    else
      echo "==> Boot disk $TARGET has no A/B layout; auto-detection skipped." >&2
      echo "    Pass --target explicitly to flash a different disk, or run on" >&2
      echo "    a system that is already A/B-installed." >&2
      TARGET=""
    fi
  fi
  unset _candidate_target
fi

[[ -n "$TARGET" ]] || die "--target is required"

# validate_layout_tokens enforces "at most one of HOME/DATA is 'rest'"
# before we tell systemd-repart, so a typo at the prompt or in a flag
# turns into a clear error instead of a surprise layout.
validate_layout_tokens

if ! ab_hostdeps_have_all_commands systemd-repart systemd-sysupdate bootctl mkfs.fat mkfs.ext4 e2fsck resize2fs losetup lsblk df blkid objcopy; then
  # binutils provides objcopy, which we now use to extract the kernel and
  # initrd PE sections out of the UKI for Type 1 BLS booting (see comments
  # near the .linux/.initrd extraction below for why Type 1 BLS). e2fsprogs
  # provides mkfs.ext4 + resize2fs + e2fsck, used to format and grow ext4
  # root/home/data partitions; mkosi-built minimal Debian images do NOT
  # ship e2fsprogs by default, so this must be installed explicitly when
  # this script runs from a booted live USB.
  ab_hostdeps_ensure_packages "hardware test USB prerequisites" systemd-container systemd-repart systemd-boot-tools systemd-boot-efi dosfstools e2fsprogs fdisk util-linux binutils || exit 1
fi
ab_hostdeps_ensure_commands "hardware test USB prerequisites" systemd-repart systemd-sysupdate bootctl mkfs.fat mkfs.ext4 e2fsck resize2fs losetup lsblk df blkid objcopy || {
  echo "==> If this host still cannot provide systemd-sysupdate, use a newer Debian/systemd host for the native USB workflow." >&2
  echo "==> Fast fallback for a hardware smoke test: write the built .raw image directly to the USB instead of using the native installer USB flow." >&2
  exit 1
}

load_build_metadata
print_selected_build
need_cmd losetup
need_cmd lsblk
need_cmd mount
need_cmd install
need_cmd df
need_cmd dd
need_cmd sfdisk
need_cmd blkid

# The full disk image (IMAGE_BASENAME, e.g. mkosi_<ver>.raw) is NOT
# required to flash — only ${ARTIFACT_PREFIX}.root.raw is needed for
# the install path. Only --embed-full-image cares about it, and that
# requirement is enforced inside copy_bundle so it can produce a more
# specific error.

# Resolve MODE → REFLASH. In auto mode this is where we peek at the
# target so the destructive-confirmation banner downstream knows
# whether the run is going to wipe everything or just rewrite the
# inactive slot. The peek is read-only and detaches its scratch loop
# device immediately so it does not interfere with bootstrap_disk's
# own loop attachment.
case "$MODE" in
  reflash)
    REFLASH=true
    echo "==> Mode: --reflash (forced); will reuse existing A/B layout"
    ;;
  repartition)
    REFLASH=false
    echo "==> Mode: --repartition (forced); will WIPE and re-bootstrap the target"
    ;;
  auto)
    if detect_existing_ab_layout; then
      REFLASH=true
      echo "==> Mode: auto-detected existing A/B layout on $TARGET → using --reflash (non-destructive)"
      echo "    (pass --repartition to force a destructive re-bootstrap instead)"
    else
      REFLASH=false
      echo "==> Mode: no existing A/B layout on $TARGET → using --repartition (destructive bootstrap)"
      echo "    (pass --reflash to fail fast instead of bootstrapping)"
    fi
    ;;
  *)
    die "internal error: unknown MODE='$MODE'"
    ;;
esac

if [[ "$REFLASH" == true ]]; then
    # --reflash: validate the existing layout, skip systemd-repart and
    # bootctl install entirely. The user has already booted from this
    # disk at least once, so the systemd-boot binary on the ESP is
    # known-working; we don't need to rewrite it. HOME and DATA are
    # left untouched — preserving them across reflashes is the whole
    # point of this mode.
    resolve_disk_device
    validate_existing_ab_layout
    confirm_usb_write_or_abort
    # Collect LUKS passphrase before slow dd — no-op if not LUKS or already supplied.
    preflight_collect_luks_passphrase
else
    resolve_disk_device
    prepare_bootstrap_repart_dir
    confirm_usb_write_or_abort
    # Collect LUKS passphrase before the slow systemd-repart format + dd.
    # No-op when image is not LUKS-encrypted or passphrase already supplied.
    preflight_collect_luks_passphrase

    echo "==> Bootstrapping A/B layout on $TARGET"
    bootstrap_disk
fi

# Seed the first system version directly by writing the root.raw image
# into a root slot, instead of using systemd-sysupdate --image on the
# entire disk. This avoids fragile systemd-dissect behavior on
# freshly-repartitioned, still-empty disks.
seed_first_root_slot

# Resolve COPY_INSTALL_BUNDLE=auto now that TARGET is known. Done
# here (rather than during arg parsing) so the resolved value reflects
# the actual target the user is writing to.
resolve_copy_install_bundle

# With ROOT_MOUNT set by seed_first_root_slot(), copy the installer
# bundle onto the seeded root filesystem.
copy_bundle

echo "==> Syncing data to disk (this may take several minutes)..."
sync

echo "==> Install ready on $TARGET"
echo " Seeded root: $ROOT_PART"
echo " Layout:      home=${HOME_SIZE_TOKEN} data=${DATA_SIZE_TOKEN}"
if [[ "$COPY_INSTALL_BUNDLE" == "yes" ]]; then
    echo " Installer entry: /root/ab-install.sh (alias /root/INSTALL-TO-INTERNAL-DISK.sh)"
else
    echo " Installer entry: not bundled (fixed-disk default; see /root/README.txt)"
fi
if [[ "$EMBED_FULL_IMAGE" == true ]]; then
    echo " Full raw image: copied into /root/"
fi
