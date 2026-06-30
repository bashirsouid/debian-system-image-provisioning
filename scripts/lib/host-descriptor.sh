#!/usr/bin/env bash
#
# Host *instance* descriptor support (prototype).
#
# A host instance is the small, personal, NON-SECRET configuration that
# describes one physical machine: which profiles it runs, its hostname,
# kernel-cmdline extras, image-id suffix, Secure Boot posture, and its
# persistent /home mount. The three layers of this project are:
#
#   1. Core            generic, public  (mkosi.conf, hardening, build.sh)
#   2. Model profiles  generic, public  (mkosi.profiles/* — hardware/drivers
#                                         keyed by hardware identity)
#   3. Host instances  personal         (this file's concern + the age vault)
#
# Secrets stay in the age vault (secrets/*.json.age, already per-host).
# Hardware enablement stays in mkosi.profiles/. This file is the third
# leg: everything left over that is "this machine of mine" but is NOT a
# secret — so it stays plaintext and reviewable rather than being buried
# in an encrypted blob.
#
# Descriptors live in hosts.local/<name>.conf and are gitignored (they
# are personal). The committed template is hosts.local.example/<name>.conf.
# Format is plaintext "key = value", one per line, '#' starts a comment:
#
#     profiles        = kernel-liquorix devbox wifi ssh-server
#     hostname        = evox2             # writes /etc/hostname AND /etc/hosts
#     image_id_suffix = evox2
#     kernel_cmdline  = quiet amdgpu.gttsize=3072
#     architecture    = arm64             # optional; omit for x86-64
#     secure_boot     = yes               # yes -> sign UKI; no -> opt-out marker
#     persistent_home = LABEL=HOME ext4   # "<source> [fstype]"; generates fstab
#     packages        = firmware-linux    # optional host-only [Content] Packages=
#     backup_paths    = /etc/s3-backup-paths.conf /home   # -> /etc/s3-backup-paths.conf
#     kopia_filesystem_targets = ext1:/mnt/ext1 ext2:/mnt/ext2  # -> /etc/kopia/targets.json
#     kopia_cloud_targets      = wasabi:https://s3.wasabi.com    # -> /etc/kopia/targets.json
#     kopia_sources            = /home                  # -> /etc/kopia/sources.conf
#     kopia_extra_excludes     = *.iso /mnt/data/Cache/ # -> /etc/kopia/excludes.local.conf
#
# When a descriptor exists, ab_host_descriptor_materialize renders a
# synthetic host overlay under .mkosi-host/<name>/ that is byte-for-byte
# the layout build.sh already knows how to consume (profile.default,
# image-id-suffix, kernel-cmdline.extra, mkosi.conf.d/30-secure-boot.conf
# or secure-boot.disabled, mkosi.extra/...). build.sh points its existing
# host-overlay logic at that directory via $HOST_BASE. The descriptor is
# therefore purely an INPUT ADAPTER — none of build.sh's consumption
# logic has to change.
#
# When no descriptor exists, materialize echoes the legacy hosts/<name>/
# path unchanged, so un-migrated hosts behave exactly as before.

# Echo the descriptor path for <host> if one exists; return 1 otherwise.
ab_host_descriptor_file() {
  local root="$1" host="$2"
  [[ -n "$host" ]] || return 1
  local f="$root/hosts.local/$host.conf"
  [[ -f "$f" ]] || return 1
  printf '%s\n' "$f"
}

# Print the value for a single "key = value" line, or empty. Parsed with
# awk (never sourced) so a malformed descriptor cannot execute code or
# poison the caller's shell. Strips surrounding quotes and trailing
# " # comments" (a '#' must be preceded by whitespace to count as a
# comment, so values like amdgpu.gttsize=3072 survive intact).
ab_host_descriptor_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }

  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      sub(/[[:space:]]+#.*$/, "")
      if (continuation) {
        current_val = current_val " " $0
      } else {
        current_val = $0
      }

      if (current_val ~ /\\$/) {
        sub(/\\$/, "", current_val)
        continuation = 1
        next
      } else {
        continuation = 0
      }

      if (match(current_val, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/)) {
        name = substr(current_val, RSTART, RLENGTH)
        sub(/[[:space:]]*=[[:space:]]*$/, "", name)
        sub(/^[[:space:]]+/, "", name)
        if (name == k) {
          val = substr(current_val, RSTART + RLENGTH)
          sub(/^[[:space:]]+/, "", val)
          sub(/[[:space:]]+$/, "", val)
          if (match(val, /^".*"$/) || match(val, /^'\''.*'\''$/)) {
            val = substr(val, 2, length(val) - 2)
          }
          gsub(/[[:space:]]+/, " ", val)
          print val
          exit
        }
      }
    }
  ' "$file"
}

# Resolve <host> to an overlay directory build.sh can consume, and print
# its absolute path on stdout.
#
#   * descriptor present -> render .mkosi-host/<host>/ from it and print that
#   * descriptor absent  -> print the legacy $root/hosts/<host> path as-is
#
# Returns non-zero only on a malformed descriptor (e.g. bad secure_boot),
# so build.sh's `set -e` aborts loudly rather than building something
# subtly wrong.
ab_host_descriptor_materialize() {
  local root="$1" host="$2"
  local desc
  if ! desc="$(ab_host_descriptor_file "$root" "$host")"; then
    printf '%s\n' "$root/hosts/$host"
    return 0
  fi

  local out="$root/.mkosi-host/$host"
  rm -rf "$out"
  install -d -m 0755 "$out" "$out/mkosi.conf.d" "$out/mkosi.extra/etc"

  local profiles hostname image_id_suffix kernel_cmdline secure_boot
  local persistent_home backup_paths architecture packages extra_mounts
  local kopia_filesystem_targets kopia_cloud_targets kopia_extra_excludes kopia_sources
  profiles="$(ab_host_descriptor_value "$desc" profiles)"
  hostname="$(ab_host_descriptor_value "$desc" hostname)"
  image_id_suffix="$(ab_host_descriptor_value "$desc" image_id_suffix)"
  kernel_cmdline="$(ab_host_descriptor_value "$desc" kernel_cmdline)"
  secure_boot="$(ab_host_descriptor_value "$desc" secure_boot)"
  persistent_home="$(ab_host_descriptor_value "$desc" persistent_home)"
  extra_mounts="$(ab_host_descriptor_value "$desc" extra_mounts)"
  backup_paths="$(ab_host_descriptor_value "$desc" backup_paths)"
  architecture="$(ab_host_descriptor_value "$desc" architecture)"
  packages="$(ab_host_descriptor_value "$desc" packages)"
  kopia_filesystem_targets="$(ab_host_descriptor_value "$desc" kopia_filesystem_targets)"
  kopia_cloud_targets="$(ab_host_descriptor_value "$desc" kopia_cloud_targets)"
  kopia_extra_excludes="$(ab_host_descriptor_value "$desc" kopia_extra_excludes)"
  kopia_sources="$(ab_host_descriptor_value "$desc" kopia_sources)"

  [[ -n "$profiles" ]]        && printf '%s\n' "$profiles"        > "$out/profile.default"
  [[ -n "$image_id_suffix" ]] && printf '%s\n' "$image_id_suffix" > "$out/image-id-suffix"
  [[ -n "$kernel_cmdline" ]]  && printf '%s\n' "$kernel_cmdline"  > "$out/kernel-cmdline.extra"

  # Hostname: write /etc/hostname AND a matching /etc/hosts. The base
  # image ships /etc/hosts with "127.0.1.1 qemu"; without this override a
  # host's own name would not resolve to a loopback address. (Previously
  # only the macbook host bothered to override /etc/hosts; generating it
  # here fixes that consistently for every descriptor-defined host.)
  if [[ -n "$hostname" ]]; then
    printf '%s\n' "$hostname" > "$out/mkosi.extra/etc/hostname"
    cat > "$out/mkosi.extra/etc/hosts" <<HOSTS
127.0.0.1 localhost
127.0.1.1 $hostname

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS
  fi

  # Non-default CPU architecture (e.g. arm64 for an Oracle Ampere box).
  # read_architecture_from_configs() in build.sh greps this drop-in.
  if [[ -n "$architecture" ]]; then
    cat > "$out/mkosi.conf.d/10-architecture.conf" <<ARCH
# Generated from hosts.local/$host.conf (architecture).
[Distribution]
Architecture=$architecture
ARCH
  fi

  # Extra host-only packages (space-separated). Non-secret, per-machine;
  # genuinely host-wide package needs that don't warrant their own profile.
  if [[ -n "$packages" ]]; then
    {
      printf '# Generated from hosts.local/%s.conf (packages).\n' "$host"
      printf '[Content]\nPackages=\n'
      local _pkg
      for _pkg in $packages; do
        printf '    %s\n' "$_pkg"
      done
    } > "$out/mkosi.conf.d/20-packages.conf"
  fi

  # Secure Boot posture. Mirrors the per-host 30-secure-boot.conf the
  # legacy hosts/* dirs carry; build.sh still demands an explicit posture
  # for every --host build, so an unset value falls through to that gate.
  case "$secure_boot" in
    yes|true|1)
      cat > "$out/mkosi.conf.d/30-secure-boot.conf" <<'SB'
# Generated from hosts.local/<host>.conf (secure_boot = yes).
# mkosi signs the UKI with .secureboot/db.key; enroll db.crt in UEFI.
[Validation]
SecureBoot=yes
SecureBootKey=.secureboot/db.key
SecureBootCertificate=.secureboot/db.crt
SB
      ;;
    no|false|0)
      printf 'Secure Boot opt-out declared in hosts.local/%s.conf (secure_boot = no).\n' \
        "$host" > "$out/secure-boot.disabled"
      ;;
    "")
      : # leave unset; build.sh will require an explicit posture, as for legacy hosts
      ;;
    *)
      printf 'ab_host_descriptor: ERROR: secure_boot must be yes or no (got: %s)\n' \
        "$secure_boot" >&2
      return 1
      ;;
  esac

  # Persistent /home and extra_mounts -> generate the standard fstab entries.
  # Options for /home mirror the long-standing hosts/*/mkosi.extra/etc/fstab
  # template: nofail so a missing HOME partition (QEMU, fresh USB) is not a boot
  # failure, and a short device-timeout so those boots don't stall for 90s.
  if [[ -n "$persistent_home" || -n "$extra_mounts" ]]; then
    : > "$out/mkosi.extra/etc/fstab"
  fi

  if [[ -n "$persistent_home" ]]; then
    local home_src home_fstype
    home_src="${persistent_home%% *}"
    home_fstype="${persistent_home#* }"
    [[ "$home_fstype" == "$persistent_home" ]] && home_fstype="ext4"
    {
      printf '# Generated from hosts.local/%s.conf (persistent_home).\n' "$host"
      printf '# /home lives outside the slot image so A/B root updates never replace user data.\n'
      printf '%s /home %s nofail,x-systemd.device-timeout=2s 0 2\n' "$home_src" "$home_fstype"
    } >> "$out/mkosi.extra/etc/fstab"
  fi

  if [[ -n "$extra_mounts" ]]; then
    {
      printf '# Generated from hosts.local/%s.conf (extra_mounts).\n' "$host"
      local entry src mountpoint fstype options
      for entry in $extra_mounts; do
        # entry is src:mountpoint[:fstype[:options]]
        IFS=':' read -r src mountpoint fstype options <<< "$entry"

        [[ -n "$src" && -n "$mountpoint" ]] || {
          printf 'ab_host_descriptor: ERROR: extra_mounts entry %q must be source:mountpoint[:fstype[:options]]\n' "$entry" >&2
          return 1
        }

        if [[ -z "$fstype" ]]; then
          fstype="auto"
        fi
        if [[ -z "$options" ]]; then
          options="nofail,x-systemd.device-timeout=2s"
        fi

        printf '%s %s %s %s 0 2\n' "$src" "$mountpoint" "$fstype" "$options"
      done
    } >> "$out/mkosi.extra/etc/fstab"

    # Pre-create mount point directories in the host's overlay tree
    # so they are baked into the read-only root image at build time.
    local entry src mountpoint fstype options
    for entry in $extra_mounts; do
      IFS=':' read -r src mountpoint fstype options <<< "$entry"
      if [[ -n "$mountpoint" ]]; then
        local local_mountpoint_dir="${mountpoint#/}"
        install -d -m 0755 "$out/mkosi.extra/$local_mountpoint_dir"
      fi
    done
  fi

  # Optional non-secret backup paths -> /etc/s3-backup-paths.conf
  # (one path per line; this is the format the existing conf uses).
  if [[ -n "$backup_paths" ]]; then
    {
      printf '# Generated from hosts.local/%s.conf (backup_paths).\n' "$host"
      local _p
      for _p in $backup_paths; do
        printf '%s\n' "$_p"
      done
    } > "$out/mkosi.extra/etc/s3-backup-paths.conf"
  fi

  # Kopia backup stack — non-secret per-host config. Targets are rendered into
  # /etc/kopia/targets.json (consumed by /usr/lib/kopia/kopia.backup.*.bash).
  # Secrets (passphrase, S3 keys) stay in the age vault, NOT here.
  #
  #   kopia_filesystem_targets = name:/mnt/point  name2:/mnt/point2
  #   kopia_cloud_targets      = name:https://endpoint  name2:https://endpoint2
  #   kopia_extra_excludes     = pattern1 pattern2     (-> excludes.local.conf)
  #   kopia_sources            = /home /etc/important  (-> sources.conf)
  if [[ -n "$kopia_filesystem_targets" || -n "$kopia_cloud_targets" \
        || -n "$kopia_extra_excludes" || -n "$kopia_sources" ]]; then
    command -v jq >/dev/null 2>&1 || {
      printf 'ab_host_descriptor: ERROR: jq is required to render kopia targets for %s\n' "$host" >&2
      return 1
    }
    install -d -m 0755 "$out/mkosi.extra/etc/kopia"
  fi

  if [[ -n "$kopia_filesystem_targets" || -n "$kopia_cloud_targets" ]]; then
    local _fs_json="[]" _cloud_json="[]" _entry _nm _rest
    local -a _objs=()
    if [[ -n "$kopia_filesystem_targets" ]]; then
      _objs=()
      for _entry in $kopia_filesystem_targets; do
        _nm="${_entry%%:*}"; _rest="${_entry#*:}"
        if [[ "$_nm" == "$_entry" || -z "$_rest" ]]; then
          printf 'ab_host_descriptor: ERROR: kopia_filesystem_targets entry %q must be name:/mountpoint\n' "$_entry" >&2
          return 1
        fi
        _objs+=("$(jq -n --arg n "$_nm" --arg m "$_rest" '{name:$n, mount:$m}')")
      done
      _fs_json="$(printf '%s\n' "${_objs[@]}" | jq -s '.')"
    fi
    if [[ -n "$kopia_cloud_targets" ]]; then
      _objs=()
      for _entry in $kopia_cloud_targets; do
        _nm="${_entry%%:*}"; _rest="${_entry#*:}"
        if [[ "$_nm" == "$_entry" || -z "$_rest" ]]; then
          printf 'ab_host_descriptor: ERROR: kopia_cloud_targets entry %q must be name:https://endpoint\n' "$_entry" >&2
          return 1
        fi
        _objs+=("$(jq -n --arg n "$_nm" --arg e "$_rest" '{name:$n, endpoint:$e}')")
      done
      _cloud_json="$(printf '%s\n' "${_objs[@]}" | jq -s '.')"
    fi
    jq -n --argjson fs "$_fs_json" --argjson cloud "$_cloud_json" \
      '{filesystem:$fs, cloud:$cloud}' > "$out/mkosi.extra/etc/kopia/targets.json"
  fi

  if [[ -n "$kopia_extra_excludes" ]]; then
    {
      printf '%s\n' \
        "# /etc/kopia/excludes.local.conf -- per-host Kopia ignore patterns, one" \
        "# per line, merged on top of /etc/kopia/excludes.conf. '#' starts a" \
        "# comment; blank lines are ignored." \
        "#" \
        "# Generated from hosts.local/${host}.conf (kopia_extra_excludes) by the" \
        "# last mkosi build. One-off change between builds: edit this file in" \
        "# place -- it is re-read on every backup run, no rebuild needed." \
        "# *Adding* a pattern takes effect immediately; to *re-enable* an" \
        "# excluded path, add it to /etc/kopia/clear.excludes.conf rather than" \
        "# deleting it here (see kopia-base/README.md). The next mkosi build" \
        "# regenerates this file from the descriptor, discarding edits." \
        ""
      local _ex
      for _ex in $kopia_extra_excludes; do
        printf '%s\n' "$_ex"
      done
    } > "$out/mkosi.extra/etc/kopia/excludes.local.conf"
  fi

  if [[ -n "$kopia_sources" ]]; then
    {
      printf '%s\n' \
        "# /etc/kopia/sources.conf -- filesystem paths to snapshot, one per line." \
        "# Applies to every backup target (filesystem and cloud). '#' starts a" \
        "# comment; blank lines are ignored." \
        "#" \
        "# Generated from hosts.local/${host}.conf (kopia_sources) by the last" \
        "# mkosi build. One-off change between builds: edit this file in place --" \
        "# it is re-read on every backup run (no rebuild needed) and takes full" \
        "# effect immediately. The next mkosi build regenerates it from the" \
        "# descriptor, discarding edits. See kopia-base/README.md." \
        ""
      local _s
      for _s in $kopia_sources; do
        printf '%s\n' "$_s"
      done
    } > "$out/mkosi.extra/etc/kopia/sources.conf"
  fi

  printf '%s\n' "$out"
}
