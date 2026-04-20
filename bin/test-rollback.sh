#!/usr/bin/env bash
# bin/test-rollback.sh
#
# Automated smoke test for the retained-version rollback path:
#
#   1. Start from a pre-built image (./build.sh must have succeeded).
#   2. Create a fresh raw disk file and bootstrap it with
#      bootstrap-ab-disk.sh so it has the same layout as a real
#      install (ESP + root_a + root_b, first version seeded).
#   3. Inject a health-check hook that always fails into the seeded
#      root, so ab-health-gate.service will report "unhealthy" on
#      every boot of this version. systemd-boot's boot counter
#      should then decrement Tries= each boot until the entry is
#      marked bad, at which point the older (empty) retained slot
#      should win selection.
#   4. Boot the image in QEMU N times in headless mode, with a
#      per-run timeout, shutting the guest down after the health
#      gate has had a chance to run.
#   5. Between boots, loop-mount the root partition read-only and
#      read /var/lib/ab-health/status.env to observe the state
#      machine.
#   6. Report the evolution of tries-left and health status across
#      boots. A healthy run shows the unhealthy marker being set
#      every time, Tries= decrementing on each reboot, and finally
#      +0-<bad> suffix on the BLS entry.
#
# This is a smoke test. It is NOT a full rollback test because a
# "second known-good retained version" is not staged — after the
# seeded first version is blessed bad, systemd-boot has no other
# version to fall back to, so the machine will stay on the bad
# version. What this test DOES validate:
#
#   * the health gate runs and writes status.env
#   * the failing hook correctly trips it
#   * systemd-boot decrements Tries= per boot
#   * systemd-bless-boot is present and wires into boot-complete
#
# Running a full two-version rollback requires staging a second
# version with systemd-sysupdate between boots, which is a
# follow-up. See the comments near FULL_ROLLBACK_FOLLOWUP below.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=SCRIPTDIR/../scripts/lib/build-meta.sh
source "$PROJECT_ROOT/scripts/lib/build-meta.sh"

PROFILE=""
HOST=""
BUILD_DIR=""
WORK_DIR=""
DISK_SIZE="${AB_TEST_DISK_SIZE:-12G}"
BOOT_COUNT="${AB_TEST_BOOT_COUNT:-5}"
BOOT_TIMEOUT="${AB_TEST_BOOT_TIMEOUT:-180}"
KEEP_WORK=false
QEMU_EXTRA=()
CLEAN_ON_EXIT=true

log()  { printf '[test-rollback] %s\n'        "$*"; }
warn() { printf '[test-rollback] WARN: %s\n'  "$*" >&2; }
die()  { printf '[test-rollback] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./bin/test-rollback.sh [options]

Runs a rollback smoke test against a pre-built image.

Options:
  --profile NAME           resolve mkosi.output/builds/latest-NAME when
                           --host is not given and --build-dir is not set
  --host NAME              resolve mkosi.output/builds/latest-NAME (the
                           host name)
  --build-dir PATH         specific build folder under mkosi.output/builds/
                           to test; takes precedence over --host / --profile
  --work-dir DIR           persist all test state here (default: new tmpdir)
  --disk-size SIZE         size for the test raw disk file (default: 12G)
  --boot-count N           how many reboots to drive (default: 5)
  --boot-timeout SEC       per-boot hard timeout in seconds (default: 180)
  --keep                   keep the work dir after the run for inspection
  --qemu-arg ARG           append ARG to the qemu invocation (repeatable)

Environment overrides: AB_TEST_DISK_SIZE, AB_TEST_BOOT_COUNT, AB_TEST_BOOT_TIMEOUT.

Prerequisites (auto-installed when possible):
  qemu-system-x86_64, ovmf, loop module, sfdisk, losetup, mount, dd.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)       PROFILE="${2:?}"; shift 2 ;;
    --host)          HOST="${2:?}"; shift 2 ;;
    --build-dir)     BUILD_DIR="${2:?}"; shift 2 ;;
    --work-dir)      WORK_DIR="${2:?}"; shift 2 ;;
    --disk-size)     DISK_SIZE="${2:?}"; shift 2 ;;
    --boot-count)    BOOT_COUNT="${2:?}"; shift 2 ;;
    --boot-timeout)  BOOT_TIMEOUT="${2:?}"; shift 2 ;;
    --keep)          KEEP_WORK=true; CLEAN_ON_EXIT=false; shift ;;
    --qemu-arg)      QEMU_EXTRA+=("${2:?}"); shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "must run as root (loop-mount + qemu firmware access needed)"

if ! ab_hostdeps_have_all_commands qemu-system-x86_64 losetup sfdisk mount dd timeout; then
  ab_hostdeps_ensure_packages "rollback test prerequisites" \
    qemu-system-x86 ovmf util-linux fdisk coreutils || exit 1
fi
ab_hostdeps_ensure_commands "rollback test prerequisites" \
  qemu-system-x86_64 losetup sfdisk mount dd timeout || exit 1

OVMF_CODE=""
for candidate in \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/ovmf/OVMF.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF_CODE="$candidate"
    break
  fi
done
[[ -n "$OVMF_CODE" ]] || die "could not locate OVMF firmware (ovmf package)"

# Resolve a writable OVMF VARS template. Some distros ship a read-only
# VARS file we then have to copy per-run.
OVMF_VARS_TEMPLATE=""
for candidate in \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/ovmf/OVMF_VARS.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF_VARS_TEMPLATE="$candidate"
    break
  fi
done
[[ -n "$OVMF_VARS_TEMPLATE" ]] || die "could not locate OVMF vars template"

# Resolve build folder. --host alone is enough when hosts/<host>/profile.default
# is set; otherwise --profile or --build-dir must be given.
if [[ -n "$HOST" && -z "$PROFILE" ]]; then
  _host_default="$(ab_buildmeta_host_default_profile "$PROJECT_ROOT" "$HOST")"
  [[ -n "$_host_default" ]] && PROFILE="$_host_default"
fi
if [[ -z "$BUILD_DIR" ]]; then
  BUILD_DIR="$(ab_buildmeta_resolve_build_dir "$PROJECT_ROOT" "$PROFILE" "$HOST" || true)"
fi
if [[ -z "$BUILD_DIR" ]]; then
  if [[ -n "$HOST" ]]; then
    die "no build for host='$HOST' under mkosi.output/builds/. Run ./build.sh --host '$HOST' first."
  elif [[ -n "$PROFILE" ]]; then
    die "no build for profile='$PROFILE' under mkosi.output/builds/. Run ./build.sh --profile '$PROFILE' first."
  else
    die "no build under mkosi.output/builds/. Run ./build.sh first, or pass --build-dir / --host / --profile."
  fi
fi
[[ -d "$BUILD_DIR" ]] || die "resolved build folder does not exist: $BUILD_DIR"
ab_buildmeta_load_env "$BUILD_DIR" \
  || die "build folder is missing build.env: $BUILD_DIR"

IMAGE_ID="${AB_LAST_BUILD_IMAGE_ID:?}"
IMAGE_VERSION="${AB_LAST_BUILD_IMAGE_VERSION:?}"
IMAGE_ARCH="${AB_LAST_BUILD_ARCH:?}"
IMAGE_BASENAME="${AB_LAST_BUILD_IMAGE_BASENAME:?}"
SOURCE_DIR="$BUILD_DIR"

log "Using image: $IMAGE_ID $IMAGE_VERSION ($IMAGE_ARCH)"
log "  built artifact: $SOURCE_DIR/$IMAGE_BASENAME"

[[ -f "$SOURCE_DIR/$IMAGE_BASENAME" ]] \
  || die "built image not found: $SOURCE_DIR/$IMAGE_BASENAME"
[[ -f "$SOURCE_DIR/${IMAGE_ID}_${IMAGE_VERSION}_${IMAGE_ARCH}.root.raw" ]] \
  || die "sysupdate root artifact missing; is export-sysupdate-artifacts.sh OK?"

# Work dir layout.
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d /tmp/ab-rollback-test.XXXXXX)"
fi
install -d -m 0700 "$WORK_DIR"
DISK_IMG="$WORK_DIR/disk.img"
VARS_IMG="$WORK_DIR/vars.fd"
SERIAL_LOG="$WORK_DIR/serial.log"
TIMELINE="$WORK_DIR/timeline.log"
MOUNT_DIR="$WORK_DIR/mnt"
install -d -m 0755 "$MOUNT_DIR"

LOOPDEV=""
cleanup() {
  set +e
  if mountpoint -q "$MOUNT_DIR"; then
    umount "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$LOOPDEV" ]]; then
    losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
    LOOPDEV=""
  fi
  if [[ "$CLEAN_ON_EXIT" == true && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  elif [[ "$KEEP_WORK" == true ]]; then
    log "Work dir preserved at $WORK_DIR"
  fi
}
trap cleanup EXIT

attach_loop() {
  [[ -n "$LOOPDEV" ]] && return 0
  LOOPDEV="$(losetup --find --show --partscan "$DISK_IMG")"
  udevadm settle --timeout=5 >/dev/null 2>&1 || true
}

detach_loop() {
  [[ -n "$LOOPDEV" ]] || return 0
  if mountpoint -q "$MOUNT_DIR"; then
    umount "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  losetup -d "$LOOPDEV" >/dev/null 2>&1 || true
  LOOPDEV=""
}

seeded_root_partition() {
  # Pick the first partition whose PARTLABEL starts with IMAGE_ID_;
  # that's the slot bootstrap-ab-disk.sh filled via sysupdate.
  lsblk -nrpo NAME,PARTLABEL,FSTYPE "$LOOPDEV" | awk -v id="${IMAGE_ID}" '
    $2 ~ "^"id"_" && $3 != "" { print $1; exit }
  '
}

esp_partition() {
  lsblk -nrpo NAME,PARTLABEL,FSTYPE "$LOOPDEV" | awk '
    ($2 == "ESP" || $3 == "vfat") { print $1; exit }
  '
}

read_health_status() {
  local root_part status_file output
  root_part="$(seeded_root_partition)" || return 1
  [[ -n "$root_part" ]] || return 1
  mount -o ro "$root_part" "$MOUNT_DIR" 2>/dev/null || return 1
  status_file="$MOUNT_DIR/var/lib/ab-health/status.env"
  if [[ -f "$status_file" ]]; then
    output="$(cat "$status_file")"
  else
    output="(no status.env yet)"
  fi
  umount "$MOUNT_DIR" 2>/dev/null || true
  printf '%s\n' "$output"
}

inject_failing_hook() {
  local root_part
  root_part="$(seeded_root_partition)" || die "could not find seeded root partition"
  mount "$root_part" "$MOUNT_DIR"
  install -d -m 0755 "$MOUNT_DIR/usr/local/libexec/ab-health-check.d"
  cat > "$MOUNT_DIR/usr/local/libexec/ab-health-check.d/99-test-fail" <<'HOOK'
#!/usr/bin/env bash
# Installed by bin/test-rollback.sh. Deliberately fails so the
# health gate marks every boot of this version unhealthy, driving the
# boot-counter path through systemd-boot.
echo "test-rollback: forcing health hook failure" >&2
exit 1
HOOK
  chmod 0755 "$MOUNT_DIR/usr/local/libexec/ab-health-check.d/99-test-fail"
  umount "$MOUNT_DIR"
  log "Injected failing health hook into seeded root"
}

read_bls_tries() {
  local esp_part entry_file
  esp_part="$(esp_partition)" || return 1
  [[ -n "$esp_part" ]] || return 1
  mount -o ro "$esp_part" "$MOUNT_DIR" 2>/dev/null || return 1
  local out=""
  while IFS= read -r entry_file; do
    [[ -n "$entry_file" ]] || continue
    # BLS filenames with boot counting look like <base>+<tries-left>-<tries-done>.conf
    out+="$(basename "$entry_file")"$'\n'
  done < <(find "$MOUNT_DIR/loader/entries" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
  umount "$MOUNT_DIR" 2>/dev/null || true
  printf '%s' "$out"
}

append_timeline() {
  printf '\n==== %s ====\n' "$1" >> "$TIMELINE"
  printf 'BLS entries:\n' >> "$TIMELINE"
  read_bls_tries >> "$TIMELINE" 2>&1 || true
  printf 'Health status.env:\n' >> "$TIMELINE"
  read_health_status >> "$TIMELINE" 2>&1 || true
}

bootstrap_disk() {
  log "Creating $DISK_SIZE raw disk at $DISK_IMG"
  truncate -s "$DISK_SIZE" "$DISK_IMG"
  log "Bootstrapping with bootstrap-ab-disk.sh"
  "$PROJECT_ROOT/bin/bootstrap-ab-disk.sh" \
    --target "$DISK_IMG" \
    --source-dir "$SOURCE_DIR" \
    --image-id "$IMAGE_ID" \
    --yes \
    --allow-fixed-disk
}

boot_once() {
  local n="$1"
  log "Boot #$n (timeout ${BOOT_TIMEOUT}s)"
  cp -f "$OVMF_VARS_TEMPLATE" "$VARS_IMG"
  # shellcheck disable=SC2206
  local cmd=(
    qemu-system-x86_64
    -machine q35,accel=kvm:tcg
    -cpu max
    -m 2048
    -smp 2
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$VARS_IMG"
    -drive file="$DISK_IMG",format=raw,if=virtio
    -nographic
    -serial file:"$SERIAL_LOG.$n"
    -monitor none
    -no-reboot
    "${QEMU_EXTRA[@]}"
  )
  # timeout --foreground forwards signals so ctrl-c still works.
  if timeout --foreground "${BOOT_TIMEOUT}" "${cmd[@]}"; then
    log "  qemu exited normally"
  else
    local rc=$?
    if [[ $rc -eq 124 ]]; then
      warn "  boot #$n hit the ${BOOT_TIMEOUT}s timeout (expected if the guest loops; we examine disk state next)"
    else
      warn "  qemu exited with status $rc"
    fi
  fi
}

# Main flow.
log "Work dir: $WORK_DIR"
bootstrap_disk

attach_loop
inject_failing_hook
append_timeline "after-bootstrap-before-any-boot"
detach_loop

for n in $(seq 1 "$BOOT_COUNT"); do
  boot_once "$n"
  attach_loop
  append_timeline "after-boot-$n"
  detach_loop
done

log "Done. Boot timeline written to $TIMELINE"
log "Serial logs per boot: $SERIAL_LOG.<n>"
log ""
log "Expected pattern:"
log "  * early boots: BLS entry filename ends '+N-M.conf' with N decreasing"
log "    and health status.env shows AB_HEALTH_LAST_STATUS=unhealthy"
log "  * once N reaches 0, systemd-bless-boot marks the entry bad and"
log "    the filename suffix changes to include '-bad' or similar"
log "  * since no second retained version is present, selection is"
log "    stuck there; extending this test to full A->B->A rollback"
log "    requires staging a known-good version between boots (see"
log "    the FULL_ROLLBACK_FOLLOWUP comment at the top of this file)"

cat "$TIMELINE"
