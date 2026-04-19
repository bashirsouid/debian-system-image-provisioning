#!/usr/bin/env bash
# scripts/lib/confirm-destructive.sh
#
# Shared helpers for scripts that wipe a whole disk. All functions are
# prefixed ab_confirm_ to match the host-deps.sh / build-meta.sh style
# in this repo. The goal is a single prompt that:
#
#   1. Reproduces information the user can physically check on the
#      device (model, vendor, size, serial) so "wrong drive" is visible
#      before the destruction, not after it.
#   2. Reproduces the image identity being written next to the drive
#      identity in the same panel, so a macbook-image-into-devbox-USB
#      mistake is equally visible.
#   3. Demands the user type the device path rather than a single y,
#      which defeats muscle-memory y<enter>.
#   4. Refuses non-removable devices by default so an absent-minded
#      --target /dev/nvme0n1 against the host's own SSD is rejected.

# Prints a human-readable summary of a block device or raw image file.
# Usage: ab_confirm_describe_target PATH
ab_confirm_describe_target() {
  local target="$1"
  local real size model vendor serial tran rotational removable labels part_count

  if [[ -z "$target" || ! -e "$target" ]]; then
    printf '  target:     %s (does not exist)\n' "$target"
    return 0
  fi

  real="$(readlink -f "$target")"
  printf '  target:     %s' "$target"
  [[ "$real" != "$target" ]] && printf ' -> %s' "$real"
  printf '\n'

  if [[ -b "$real" ]]; then
    # lsblk -dn picks just the device, no partitions; --bytes gets
    # machine-parseable size but we also grab the pretty size.
    size="$(lsblk -dno SIZE "$real" 2>/dev/null | awk 'NF{print;exit}')"
    model="$(lsblk -dno MODEL "$real" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF{print;exit}')"
    vendor="$(lsblk -dno VENDOR "$real" 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF{print;exit}')"
    serial="$(lsblk -dno SERIAL "$real" 2>/dev/null | awk 'NF{print;exit}')"
    tran="$(lsblk -dno TRAN "$real" 2>/dev/null | awk 'NF{print;exit}')"
    rotational="$(lsblk -dno ROTA "$real" 2>/dev/null | awk 'NF{print;exit}')"
    removable="$(ab_confirm_removable_flag "$real")"
    labels="$(lsblk -rno PARTLABEL "$real" 2>/dev/null | awk 'NF' | paste -sd, - 2>/dev/null)"
    part_count="$(lsblk -rno NAME "$real" 2>/dev/null | wc -l)"
    # subtract 1 because the disk itself counts
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

# Returns 1/0/unknown on stdout. Uses /sys/block/<name>/removable, which
# the kernel sets to 1 for USB mass storage and SD cards and 0 for
# SATA/NVMe/virtio. Loop devices report 0; raw image files have no
# /sys entry and get reported as unknown.
ab_confirm_removable_flag() {
  local device="$1"
  local real name path
  real="$(readlink -f "$device")"
  [[ -b "$real" ]] || { printf 'unknown\n'; return 0; }
  name="$(basename "$real")"
  path="/sys/block/$name/removable"
  if [[ -r "$path" ]]; then
    cat "$path"
  else
    printf 'unknown\n'
  fi
}

# Refuses non-removable block devices. Pass --allow-fixed-disk=yes as
# $2 to override (for the live installer that explicitly wants to
# write to an internal disk).
# Usage: ab_confirm_require_removable PATH ALLOW_FIXED_YES_NO
ab_confirm_require_removable() {
  local target="$1"
  local allow_fixed="${2:-no}"
  local removable

  if [[ ! -b "$(readlink -f "$target")" ]]; then
    # File-backed targets are loop-attached; removable doesn't apply.
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
       the host's own SSD when you meant a USB stick. If you genuinely
       intend to install to an internal disk (the live installer does),
       re-run with --allow-fixed-disk.
EOF
      return 1
      ;;
    *)
      # unknown removable status: err on the side of caution
      if [[ "$allow_fixed" == "yes" ]]; then
        return 0
      fi
      cat >&2 <<EOF
ERROR: could not determine whether $target is a removable device. Re-run
       with --allow-fixed-disk if you are sure.
EOF
      return 1
      ;;
  esac
}

# Prints an identity block for the image about to be written. Reads
# from caller-supplied environment-style variables so this works whether
# the caller has build metadata loaded (write-live-test-usb.sh) or only
# a bundled .artifacts.env (live-usb-install.sh).
# Usage: ab_confirm_describe_image PROFILE HOST IMAGE_ID IMAGE_VERSION IMAGE_ARCH DISK_IMAGE_PATH
ab_confirm_describe_image() {
  local profile="${1:-unknown}"
  local host="${2:-none}"
  local image_id="${3:-unknown}"
  local image_version="${4:-unknown}"
  local image_arch="${5:-unknown}"
  local disk_image="${6:-}"
  local disk_size="" disk_sha=""

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
  # Keep for future: could sha256sum the disk image here when the
  # user wants a cryptographic sanity check before writing, but that
  # hashes multiple GiB synchronously so it's off by default.
  :
}

# Interactive gate. Demands the user type the target path exactly.
# Returns 0 on confirmation, 1 on any other response (including EOF).
# Usage: ab_confirm_typed_path TARGET
ab_confirm_typed_path() {
  local target="$1"
  local answer
  printf '\nTo confirm destruction, type the target path exactly as shown above\n'
  printf 'and press enter. Anything else aborts.\n\n'
  printf '  > '
  IFS= read -r answer || return 1
  if [[ "$answer" == "$target" ]]; then
    return 0
  fi
  printf 'Typed path did not match. Aborting.\n' >&2
  return 1
}
