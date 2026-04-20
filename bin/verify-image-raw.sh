#!/bin/bash
# bin/verify-image-raw.sh
#
# Sanity-checks a built image.raw before you flash or publish it. Fails
# loudly if anything is wrong so you do not boot a broken image onto
# real hardware.
#
# Usage:
#   ./bin/verify-image-raw.sh [--image mkosi.output/builds/latest/<image_id>_<ver>.raw]
#
# Checks:
#   1. File exists and is > 100 MiB.
#   2. GPT partition table present and parsable by sfdisk.
#   3. At least one ESP and at least one Linux root partition.
#   4. ESP contains /EFI/BOOT/BOOT*.EFI (fallback loader) or /EFI/systemd/.
#   5. Root partition contains a recognizable Debian rootfs (/etc/os-release).
#   6. /etc/ssh/sshd_config.d/50-hardening.conf exists and has a real username
#      substituted (not __INITIAL_USERNAME__).
#   7. /etc/credstore.encrypted/ contains the expected encrypted blobs
#      if the remote-access add-on is enabled.
#   8. /var/lib/systemd/credential.secret exists and is mode 0400.

set -euo pipefail

log()  { printf '[verify-image] %s\n'       "$*" >&2; }
ok()   { printf '[verify-image] ok:    %s\n' "$*" >&2; }
fail() { printf '[verify-image] FAIL:  %s\n' "$*" >&2; exit 1; }
warn() { printf '[verify-image] WARN:  %s\n' "$*" >&2; }

IMAGE=""

while (($#)); do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) fail "unknown arg: $1" ;;
    esac
done

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"

if [[ -z "${IMAGE}" ]]; then
    # Pick the newest .raw in the newest build folder under
    # mkosi.output/builds/. The 'latest' symlink is refreshed by build.sh
    # after each successful build; following it keeps this tool pointing
    # at the build you just made without having to pass --image every
    # time. The split-out sysupdate partitions (.root.raw, .vmlinuz.raw,
    # .initrd.raw) are excluded so we only pick the full disk image.
    latest_build="${REPO_ROOT}/mkosi.output/builds/latest"
    if [[ -L "${latest_build}" || -d "${latest_build}" ]]; then
        newest=""
        newest_mtime=0
        shopt -s nullglob
        for candidate in "${latest_build}"/*.raw; do
            case "${candidate}" in
                *.root.raw|*.vmlinuz.raw|*.initrd.raw) continue ;;
            esac
            mtime="$(stat -c '%Y' "${candidate}" 2>/dev/null || echo 0)"
            if (( mtime > newest_mtime )); then
                newest_mtime="${mtime}"
                newest="${candidate}"
            fi
        done
        shopt -u nullglob
        IMAGE="${newest}"
    fi
fi
[[ -n "${IMAGE}" && -f "${IMAGE}" ]] || fail "could not locate an image.raw. Pass --image."

log "image: ${IMAGE}"

# --- 1. size -------------------------------------------------------------
size="$(stat -c '%s' "${IMAGE}")"
(( size > 100*1024*1024 )) || fail "image is only ${size} bytes; almost certainly truncated."
ok "size = ${size} bytes"

# --- 2. GPT table --------------------------------------------------------
if ! command -v sfdisk >/dev/null; then
    fail "sfdisk not installed (apt-get install --no-install-recommends fdisk)"
fi

if ! sfdisk -d "${IMAGE}" >/dev/null 2>&1; then
    fail "sfdisk cannot read a partition table from ${IMAGE}"
fi
ok "partition table readable"

# Parse partition layout
parts_json="$(sfdisk -J "${IMAGE}")"
table_label="$(jq -r '.partitiontable.label' <<<"${parts_json}")"
[[ "${table_label}" == "gpt" ]] || fail "partition table label is '${table_label}', expected 'gpt'"
ok "GPT partition table"

# --- 3. ESP + root -------------------------------------------------------
# ESP type GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
# Linux root x86-64 GUID: 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
# Linux root arm64 GUID:  B921B045-1DF0-41C3-AF44-4C6F280D3FAE

have_esp="no"
have_root="no"
while IFS= read -r t; do
    case "${t,,}" in
        c12a7328-f81f-11d2-ba4b-00a0c93ec93b) have_esp="yes" ;;
        4f68bce3-e8cd-4db1-96e7-fbcaf984b709) have_root="yes" ;;
        b921b045-1df0-41c3-af44-4c6f280d3fae) have_root="yes" ;;
    esac
done < <(jq -r '.partitiontable.partitions[].type' <<<"${parts_json}")

[[ "${have_esp}"  == "yes" ]] || fail "no ESP partition found"
[[ "${have_root}" == "yes" ]] || fail "no Linux root partition found"
ok "ESP + Linux root partitions present"

# --- 4-8. filesystem spot-checks via systemd-dissect --------------------
if ! command -v systemd-dissect >/dev/null; then
    warn "systemd-dissect not installed; skipping filesystem-level checks."
    warn "apt-get install --no-install-recommends systemd-container"
    log "partition-level checks passed."
    exit 0
fi

# systemd-dissect needs root for direct loop setup in some kernels.
if [[ $EUID -ne 0 ]]; then
    warn "not root; filesystem-level checks need sudo. Re-run with sudo for a full verify."
    log "partition-level checks passed."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'systemd-dissect --umount "${TMP}" 2>/dev/null || true; rmdir "${TMP}" 2>/dev/null || true' EXIT

systemd-dissect --mount --read-only "${IMAGE}" "${TMP}"

# 4. ESP boot entry
esp_mount=""
for m in "${TMP}/boot" "${TMP}/efi" "${TMP}/boot/efi"; do
    [[ -d "$m" ]] && esp_mount="$m" && break
done
if [[ -n "${esp_mount}" ]]; then
    if [[ -d "${esp_mount}/EFI/systemd" ]] || compgen -G "${esp_mount}/EFI/BOOT/BOOT*.EFI" >/dev/null; then
        ok "ESP has a bootloader"
    else
        fail "ESP mounted at ${esp_mount} but no EFI/systemd or EFI/BOOT loader found."
    fi
else
    warn "ESP not auto-mounted by systemd-dissect; cannot verify bootloader."
fi

# 5. rootfs identity
[[ -f "${TMP}/etc/os-release" ]] || fail "rootfs has no /etc/os-release"
os_name="$(. "${TMP}/etc/os-release"; printf '%s' "${NAME:-?}")"
ok "rootfs os-release NAME='${os_name}'"

# 6. sshd hardening substitution
hardening="${TMP}/etc/ssh/sshd_config.d/50-hardening.conf"
if [[ -f "${hardening}" ]]; then
    if grep -q '__INITIAL_USERNAME__' "${hardening}"; then
        fail "${hardening} still contains __INITIAL_USERNAME__ placeholder. package-credentials.sh did not run."
    fi
    ok "sshd hardening file has username substituted"
else
    warn "no 50-hardening.conf found; remote-access add-on not applied?"
fi

# 7. credstore blobs
for f in tailscale-authkey cloudflared-token; do
    p="${TMP}/etc/credstore.encrypted/${f}"
    if [[ -f "${p}" ]]; then
        m="$(stat -c '%a' "${p}")"
        if [[ "${m}" != "600" ]]; then
            fail "${p} has permissions ${m}, expected 600"
        fi
        ok "${f} present and 0600"
    else
        warn "${f} not found; skipping (add-on disabled?)"
    fi
done

# 8. credential.secret
cs="${TMP}/var/lib/systemd/credential.secret"
if [[ -f "${cs}" ]]; then
    m="$(stat -c '%a' "${cs}")"
    if [[ "${m}" != "400" ]]; then
        fail "${cs} has permissions ${m}, expected 400"
    fi
    ok "credential.secret present and 0400"
else
    warn "credential.secret not found; systemd-creds will not be able to decrypt credstore."
fi

log "image verification passed."
