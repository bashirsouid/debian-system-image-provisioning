#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/host-deps.sh
source "$PROJECT_ROOT/scripts/lib/host-deps.sh"
# shellcheck source=scripts/lib/build-meta.sh
source "$PROJECT_ROOT/scripts/lib/build-meta.sh"

PROFILE="devbox"
HOST=""
BUILD_DIR=""
RUNTIME_HOME=false
EPHEMERAL=true
QEMU_HOME_SEED=true
RUNTIME_TREES=()
EXPLICIT_PROFILE=false
EXPLICIT_HOST=false
IMAGE_ID=""
IMAGE_VERSION=""

# Diagnostic options. Default off; exist specifically so we can figure
# out *why* a VM will not boot before committing to a flash.
DEBUG=false
SERIAL=false
BOOT_NSPAWN=false
EXTRA_KERNEL_ARGS=()
EXTRA_MKOSI_ARGS=()
# Build picker: when no --build-dir/--host/--profile is given AND the
# session is interactive, show a numbered list of every build under
# mkosi.output/builds/ so the user can pick which image to boot. Set
# AB_RUN_PICK=auto (default), always, or never to override.
PICK_MODE="auto"
LIST_BUILDS=false

usage() {
  cat <<'USAGE'
Usage: ./run.sh [options]

Options:
  --profile NAME          boot profile (default: devbox, or last built profile
                          when mkosi.output/builds/ has a matching build)
  --host NAME             include runtime config from hosts/NAME/mkosi.conf.d/
                          and reuse the image built for that host
  --build-dir PATH        specific build folder under mkosi.output/builds/
                          to boot; takes precedence over --host / --profile
  --runtime-home          ask mkosi to mount the invoking host home at /root
                          inside the VM for disposable compatibility testing
  --runtime-tree SPEC     mount a host directory into the VM using mkosi's
                          RuntimeTrees= support; SPEC is hostpath[:guestpath]
  --ephemeral             boot from a temporary snapshot of the image
                          (default)
  --persistent            boot the image with persistent writes
  --no-qemu-home-seed     do not mount the repo sample home seed into the VM

Diagnostic options (use these when the image won't boot):
  --debug                 mkosi --debug + verbose systemd logs + serial console
  --serial                force serial/interactive console instead of GUI so
                          boot output scrolls into this terminal
  --list                  list every build under mkosi.output/builds/ and exit
  --latest                bypass the interactive picker and use the newest
                          build (the behavior before the picker was added)
  --pick                  force the interactive picker even when --host /
                          --profile would otherwise resolve a single build
  --boot-nspawn           boot with 'mkosi boot' (systemd-nspawn) instead of a
                          real VM. Bypasses firmware + bootloader + kernel +
                          initrd entirely and is the fastest way to tell
                          whether the root tree itself is broken vs. the
                          boot chain.
  --kernel-arg ARG        append ARG to the guest kernel cmdline (repeatable)
  --mkosi-arg ARG         append ARG to the mkosi invocation (repeatable)

Examples:
  ./run.sh --profile devbox
  ./run.sh --debug
  ./run.sh --boot-nspawn
  ./run.sh --serial --kernel-arg systemd.unit=rescue.target
  ./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"

Notes:
  - run.sh defaults to an ephemeral VM so QEMU smoke tests do not mutate
    the built image you may later flash.
  - If a previous build folder exists under mkosi.output/builds/, run.sh
    reads its build.env so mkosi vm opens the image that was just built
    instead of recalculating a new timestamped version.
  - For testing host data, prefer mkosi's native runtime mount features over
    raw QEMU arguments so we stay on the supported path.
  - RuntimeHome mounts the current host home at /root in the guest on current
    Debian-trixie mkosi.
  - For full-home sharing, use disposable runs (--ephemeral) and keep in mind
    that the guest will be touching live host data.

Troubleshooting a VM that will not boot:
  1) ./run.sh --boot-nspawn            # does the root FS itself work?
  2) ./run.sh --debug                  # serial console + full systemd debug
  3) ./run.sh --serial --kernel-arg systemd.unit=rescue.target
                                       # drop straight to rescue shell
  4) mkosi summary                     # print the resolved config; confirms
                                       # a kernel package is actually present
                                       # in the resolved Packages= list
USAGE
}

# Parse arguments BEFORE running any host-dep install step, so that
# ./run.sh --help on a fresh checkout does not prompt for sudo just to
# print usage.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:?missing profile name}"
      EXPLICIT_PROFILE=true
      shift 2
      ;;
    --host)
      HOST="${2:?missing host name}"
      EXPLICIT_HOST=true
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="${2:?missing build dir}"
      shift 2
      ;;
    --runtime-home)
      RUNTIME_HOME=true
      shift
      ;;
    --runtime-tree)
      RUNTIME_TREES+=("${2:?missing runtime tree spec}")
      shift 2
      ;;
    --ephemeral)
      EPHEMERAL=true
      shift
      ;;
    --persistent)
      EPHEMERAL=false
      shift
      ;;
    --no-qemu-home-seed)
      QEMU_HOME_SEED=false
      shift
      ;;
    --debug)
      DEBUG=true
      SERIAL=true
      shift
      ;;
    --serial)
      SERIAL=true
      shift
      ;;
    --boot-nspawn)
      BOOT_NSPAWN=true
      shift
      ;;
    --kernel-arg)
      EXTRA_KERNEL_ARGS+=("${2:?missing kernel arg}")
      shift 2
      ;;
    --mkosi-arg)
      EXTRA_MKOSI_ARGS+=("${2:?missing mkosi arg}")
      shift 2
      ;;
    --list)
      LIST_BUILDS=true
      shift
      ;;
    --latest)
      PICK_MODE="never"
      shift
      ;;
    --pick)
      PICK_MODE="always"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Host deps. 'mkosi vm' on an x86-64 UEFI image needs more than just
# mkosi itself: qemu-system-x86, a UEFI firmware (ovmf), virtiofsd (for
# RuntimeTrees= on recent mkosi), and swtpm when the image or profile
# touches vTPM. Missing any of these can cause 'mkosi vm' to fail in
# ways that look like "the image won't boot".
REQUIRED_CMDS=(mkosi)
REQUIRED_PKGS=(mkosi)
if [[ "$BOOT_NSPAWN" == true ]]; then
  REQUIRED_CMDS+=(systemd-nspawn)
  REQUIRED_PKGS+=(systemd-container)
else
  REQUIRED_CMDS+=(qemu-system-x86_64 virtiofsd swtpm)
  REQUIRED_PKGS+=(qemu-system-x86 ovmf virtiofsd swtpm)
fi

if ! ab_hostdeps_have_all_commands "${REQUIRED_CMDS[@]}"; then
  ab_hostdeps_ensure_packages "vm run prerequisites" "${REQUIRED_PKGS[@]}" || exit 1
fi
ab_hostdeps_ensure_commands "vm run prerequisites" "${REQUIRED_CMDS[@]}" || {
  # On Debian, virtiofsd installs at /usr/libexec/virtiofsd, which is not
  # on $PATH for non-root sessions. host-deps.sh now adds /usr/libexec to
  # PATH and to its candidate list, but if a user was bitten before that
  # fix landed, suggest the workaround.
  echo "==> If virtiofsd is reported missing but 'apt install virtiofsd' succeeded," >&2
  echo "    Debian ships the binary at /usr/libexec/virtiofsd. Re-run with" >&2
  echo "    PATH=\"\$PATH:/usr/libexec\" ./run.sh ..." >&2
  exit 1
}

# --list: dump the build inventory and exit. Useful when the user just
# wants to know what's available without booting anything.
if [[ "$LIST_BUILDS" == true ]]; then
  if ! ab_buildmeta_enumerate_builds "$PROJECT_ROOT" | grep -q .; then
    echo "No builds found under $PROJECT_ROOT/mkosi.output/builds/" >&2
    echo "Run ./build.sh first." >&2
    exit 1
  fi
  ab_buildmeta_format_builds_table "$PROJECT_ROOT"
  exit 0
fi

# Per-host default profile resolution. If --host was passed without
# --profile, read hosts/<host>/profile.default and use that before the
# metadata-load step, so metadata lookup uses the right profile key.
# --profile on the command line always wins.
if [[ "$EXPLICIT_PROFILE" == false && "$EXPLICIT_HOST" == true ]]; then
  _host_default_profile="$(ab_buildmeta_host_default_profile "$PROJECT_ROOT" "$HOST")"
  if [[ -n "$_host_default_profile" ]]; then
    echo "==> Using default profile from hosts/$HOST/profile.default: $_host_default_profile"
    PROFILE="$_host_default_profile"
  fi
fi

# Resolve the build folder. --build-dir wins; otherwise pick the newest
# build that matches --host / --profile, or fall back to the global
# 'latest' symlink. A missing folder is not fatal here — run.sh can still
# boot by rebuilding in-place; the metadata lookup is an optimization so
# mkosi vm reuses the last built image-version instead of minting a new
# one and invalidating the cache.
METADATA_LOADED=false

# Decide whether to run the build picker:
#   - --pick (PICK_MODE=always): always run the picker, ignore --host/--profile
#   - --latest (PICK_MODE=never): never run the picker, use latest symlink
#   - default (PICK_MODE=auto): run only when no --host/--profile/--build-dir
#     was given, the session is interactive, and ≥2 builds exist.
PICK_BUILD=false
case "$PICK_MODE" in
  always)
    PICK_BUILD=true
    ;;
  never)
    PICK_BUILD=false
    ;;
  auto)
    if [[ -z "$BUILD_DIR" && "$EXPLICIT_HOST" == false && "$EXPLICIT_PROFILE" == false ]]; then
      _build_count="$(ab_buildmeta_enumerate_builds "$PROJECT_ROOT" | grep -c . || true)"
      if (( _build_count > 1 )) && [[ -t 0 && -t 2 ]]; then
        PICK_BUILD=true
      fi
      unset _build_count
    fi
    ;;
esac

if [[ "$PICK_BUILD" == true && -z "$BUILD_DIR" ]]; then
  BUILD_DIR="$(ab_buildmeta_pick_build_interactive "$PROJECT_ROOT" || true)"
  if [[ -z "$BUILD_DIR" ]]; then
    # Picker bailed (q, EOF, no TTY, no builds). Fall back to latest so
    # ./run.sh still does *something* sensible — same behavior as before
    # the picker was added.
    BUILD_DIR="$(ab_buildmeta_resolve_build_dir "$PROJECT_ROOT" "" "" || true)"
  fi
fi

if [[ -z "$BUILD_DIR" ]]; then
  if [[ "$EXPLICIT_PROFILE" == true || "$EXPLICIT_HOST" == true ]]; then
    BUILD_DIR="$(ab_buildmeta_resolve_build_dir "$PROJECT_ROOT" "$PROFILE" "$HOST" || true)"
  else
    BUILD_DIR="$(ab_buildmeta_resolve_build_dir "$PROJECT_ROOT" "" "" || true)"
  fi
fi
if [[ -n "$BUILD_DIR" ]] && ab_buildmeta_load_env "$BUILD_DIR"; then
  METADATA_LOADED=true
  if [[ "$EXPLICIT_PROFILE" == false && -n "${AB_LAST_BUILD_PROFILE:-}" ]]; then
    PROFILE="$AB_LAST_BUILD_PROFILE"
  fi
  if [[ "$EXPLICIT_HOST" == false ]]; then
    HOST="${AB_LAST_BUILD_HOST:-}"
  fi
fi

if [[ "$METADATA_LOADED" == true ]]; then
  IMAGE_ID="${AB_LAST_BUILD_IMAGE_ID:-}"
  IMAGE_VERSION="${AB_LAST_BUILD_IMAGE_VERSION:-}"
fi

args=("--profile=$PROFILE")

# Point mkosi at the resolved build folder. mkosi.conf sets
# OutputDirectory=mkosi.output/ but build.sh moves finished artifacts out
# of mkosi.output/ and into mkosi.output/builds/<ts>__<profile>__<host>/
# once a build completes. The CLI flag --output-dir does NOT help here:
# mkosi vm intentionally ignores config-rewriting flags on cached builds
# and prints "Ignoring --output-directory from the CLI. Run with -f to
# rebuild...". So instead we stage symlinks of the build artifacts back
# into mkosi.output/ for the duration of this run, and trap-clean them
# afterwards. mkosi.output/ is documented as kept empty between builds,
# so the symlinks are safe; the trap is what guarantees we leave it that
# way even on Ctrl-C.
STAGED_ARTIFACTS=()
cleanup_staged_artifacts() {
  if (( ${#STAGED_ARTIFACTS[@]} > 0 )); then
    rm -f "${STAGED_ARTIFACTS[@]}" 2>/dev/null || true
  fi
}
trap cleanup_staged_artifacts EXIT
if [[ -n "$BUILD_DIR" && -n "$IMAGE_ID" && -n "$IMAGE_VERSION" ]]; then
  _mkosi_output_dir="$PROJECT_ROOT/mkosi.output"
  install -d -m 0755 "$_mkosi_output_dir"
  shopt -s nullglob
  for _src in "$BUILD_DIR/${IMAGE_ID}_${IMAGE_VERSION}"*; do
    [[ -f "$_src" ]] || continue
    _dest="$_mkosi_output_dir/$(basename "$_src")"
    # Don't clobber a real file or a foreign symlink someone else placed
    # there — only stage if the slot is unoccupied. Without this we'd
    # silently overwrite a half-built image left behind by an aborted
    # run, which `rm -f` in the trap would then permanently delete.
    [[ -e "$_dest" || -L "$_dest" ]] && continue
    ln -s "$_src" "$_dest"
    STAGED_ARTIFACTS+=("$_dest")
  done
  shopt -u nullglob
  unset _mkosi_output_dir _src _dest
fi

if [[ -n "$IMAGE_ID" ]]; then
  args+=("--image-id=$IMAGE_ID")
fi
if [[ -n "$IMAGE_VERSION" ]]; then
  args+=("--image-version=$IMAGE_VERSION")
fi

if [[ "$QEMU_HOME_SEED" == true && ( "$PROFILE" == "devbox" || "$PROFILE" == "macbook" ) ]]; then
  SAMPLE_HOME_SEED="$PROJECT_ROOT/runtime-seeds/qemu-home"
  if [[ -d "$SAMPLE_HOME_SEED" ]]; then
    RUNTIME_TREES+=("$SAMPLE_HOME_SEED:/run/qemu-home-seed")
  fi
fi

if [[ -n "$HOST" ]]; then
  HOST_DIR="hosts/$HOST"
  if [[ ! -d "$HOST_DIR" ]]; then
    echo "ERROR: host directory $HOST_DIR not found" >&2
    exit 1
  fi
  [[ -d "$HOST_DIR/mkosi.conf.d" ]] && args+=("--include=$HOST_DIR/mkosi.conf.d")
fi

$RUNTIME_HOME && args+=("--runtime-home=yes")
$EPHEMERAL && args+=("--ephemeral=yes")

for spec in "${RUNTIME_TREES[@]}"; do
  args+=("--runtime-tree=$spec")
done

# Serial console overrides the Console=gui default in mkosi.conf and
# tells the guest systemd to actually push journal output onto the
# serial console. Without this, when boot fails, the VM window flashes
# and dies and you have no way to read the failure.
if [[ "$SERIAL" == true ]]; then
  args+=("--console=interactive")
  EXTRA_KERNEL_ARGS+=(
    "console=ttyS0,115200"
    "console=tty0"
    "systemd.journald.forward_to_console=1"
  )
fi

# Debug mode: verbose mkosi + verbose systemd + verbose udev. First flag
# to reach for when you do not understand why a newly built image is
# failing.
if [[ "$DEBUG" == true ]]; then
  args+=("--debug")
  EXTRA_KERNEL_ARGS+=(
    "systemd.log_level=debug"
    "systemd.log_target=console"
    "udev.log_level=info"
    "rd.udev.log_level=info"
  )
fi

# Splice extra kernel args in via KernelCommandLineExtra=. mkosi passes
# these to the guest via SMBIOS at runtime; they are NOT baked into the
# image, which is what we want for diagnostic iteration.
if (( ${#EXTRA_KERNEL_ARGS[@]} > 0 )); then
  args+=("--kernel-command-line-extra=${EXTRA_KERNEL_ARGS[*]}")
fi

if (( ${#EXTRA_MKOSI_ARGS[@]} > 0 )); then
  args+=("${EXTRA_MKOSI_ARGS[@]}")
fi

# Choose verb last so --boot-nspawn can coexist with every other flag.
VERB="vm"
if [[ "$BOOT_NSPAWN" == true ]]; then
  VERB="boot"
fi

echo "==> Booting the image (verb: $VERB, profile: $PROFILE)..."
if [[ -n "$HOST" ]]; then
  echo "==> Host overlay: $HOST"
fi
if [[ -n "$IMAGE_VERSION" ]]; then
  echo "==> Reusing last built image version: $IMAGE_VERSION"
fi
if [[ "$RUNTIME_HOME" == true ]]; then
  echo "==> mkosi RuntimeHome enabled for this VM run"
fi
if [[ "$EPHEMERAL" == true ]]; then
  echo "==> Ephemeral VM snapshot enabled"
fi
if [[ "$SERIAL" == true ]]; then
  echo "==> Serial/interactive console enabled"
fi
if [[ "$DEBUG" == true ]]; then
  echo "==> Debug logging enabled"
fi
if [[ "$BOOT_NSPAWN" == true ]]; then
  echo "==> Using systemd-nspawn (bypasses firmware + bootloader + kernel + initrd)"
fi
if [[ "$QEMU_HOME_SEED" == true && ( "$PROFILE" == "devbox" || "$PROFILE" == "macbook" ) ]]; then
  echo "==> QEMU sample home seed enabled"
fi
for spec in "${RUNTIME_TREES[@]}"; do
  echo "==> Runtime tree: $spec"
done

# Do not exec on failure; print a triage hint instead, which is the
# whole reason this script wraps mkosi in the first place.
if mkosi "${args[@]}" "$VERB"; then
  exit 0
fi
rc=$?
cat >&2 <<'HINT'

mkosi exited with a non-zero status.

Quick triage:
  - Does the root tree work at all?
      ./run.sh --boot-nspawn
    If that works but the real VM does not, the break is in firmware,
    bootloader, UKI, or initrd.
  - Is a kernel actually in the image?
      mkosi summary
    Check the resolved Packages= list for a linux-image-* entry. The
    base mkosi.conf does not pull a kernel; kernels come from the
    profile (liquorix / t2linux / stock). If the profile's kernel
    install failed silently, systemd-boot has nothing to load.
  - Is ovmf installed on the host? 'mkosi vm' needs a UEFI firmware.
  - Re-run with --debug to get verbose systemd + mkosi output on the
    serial console.
HINT
exit "$rc"
