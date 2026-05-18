#!/usr/bin/env bash
# Run once on the build machine (evox2) to stage Lunar Lake firmware blobs
# directly into the x1g13 extra tree, so the image build never depends on
# APT-installed firmware timing or incremental cache state.
#
# Prerequisites — on evox2, ensure backports firmware is installed:
#   sudo apt-get install -t trixie-backports \
#       firmware-iwlwifi firmware-misc-nonfree firmware-sof-signed
#
# Then run from repo root:
#   bash scripts/fetch-lnl-firmware.sh
#
# After the script exits successfully:
#   git add hosts/x1g13/mkosi.extra/usr/lib/firmware/
#   ./build.sh x1g13

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIRMWARE_DST="$REPO_ROOT/hosts/x1g13/mkosi.extra/usr/lib/firmware"
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# --- helpers -----------------------------------------------------------------

# Extract all firmware packages to $TMPDIR_WORK/extract.
# Called lazily only when local system copy isn't available.
PACKAGES_EXTRACTED=0
extract_packages() {
    [[ "$PACKAGES_EXTRACTED" -eq 1 ]] && return
    PACKAGES_EXTRACTED=1

    local dl_dir="$TMPDIR_WORK/debs"
    local ex_dir="$TMPDIR_WORK/extract"
    mkdir -p "$dl_dir" "$ex_dir"
    cd "$dl_dir"

    echo "  [apt-download] trying trixie-backports..."
    if ! apt-get download -t trixie-backports \
            firmware-iwlwifi firmware-misc-nonfree firmware-sof-signed 2>/dev/null; then
        echo "  [apt-download] backports unavailable, trying trixie stable..."
        apt-get download firmware-iwlwifi firmware-misc-nonfree firmware-sof-signed
    fi

    echo "  [extract] unpacking debs..."
    for deb in ./*.deb; do
        dpkg-deb -x "$deb" "$ex_dir/"
    done
    cd - > /dev/null
}

# Copy a glob of source files to dst_dir.
# Tries local system first; falls back to extracted packages.
stage_glob() {
    local src_glob="$1"  # glob on local system (e.g. /usr/lib/firmware/iwlwifi-bz*)
    local pkg_glob="$2"  # same glob under $TMPDIR_WORK/extract
    local dst_dir="$3"
    local label="$4"

    echo "--- $label ---"
    # shellcheck disable=SC2086
    local files
    files=$(ls $src_glob 2>/dev/null || true)
    if [[ -n "$files" ]]; then
        echo "  [local] found on system"
        mkdir -p "$dst_dir"
        # shellcheck disable=SC2086
        cp -v $src_glob "$dst_dir/"
        return
    fi

    extract_packages
    # shellcheck disable=SC2086
    files=$(ls $TMPDIR_WORK/extract/$pkg_glob 2>/dev/null || true)
    if [[ -n "$files" ]]; then
        mkdir -p "$dst_dir"
        # shellcheck disable=SC2086
        cp -v $TMPDIR_WORK/extract/$pkg_glob "$dst_dir/"
    else
        echo "  WARNING: $label not found — WiFi/BT/NPU/audio may not work"
    fi
}

stage_dir() {
    local src="$1"
    local pkg_rel="$2"
    local dst="$3"
    local label="$4"

    echo "--- $label ---"
    if [[ -d "$src" ]]; then
        echo "  [local] found on system"
        mkdir -p "$dst"
        cp -rv "$src/." "$dst/"
        return
    fi

    extract_packages
    local pkg_src="$TMPDIR_WORK/extract/$pkg_rel"
    if [[ -d "$pkg_src" ]]; then
        mkdir -p "$dst"
        cp -rv "$pkg_src/." "$dst/"
    else
        echo "  WARNING: $label not found — audio may not work"
    fi
}

# --- main --------------------------------------------------------------------

echo "==> Staging Lunar Lake firmware into $FIRMWARE_DST"
echo ""

# Wi-Fi 7 BE201 — iwlwifi bz-b0-fm-c0 series
stage_glob \
    "/usr/lib/firmware/iwlwifi-bz-b0*" \
    "usr/lib/firmware/iwlwifi-bz-b0*" \
    "$FIRMWARE_DST" \
    "Wi-Fi 7 BE201 (iwlwifi bz-b0-fm-c0)"

# Verify the critical WiFi firmware was staged
if ! ls "$FIRMWARE_DST"/iwlwifi-bz-b0* &>/dev/null; then
    echo ""
    echo "ERROR: iwlwifi-bz-b0 firmware was not staged."
    echo "       Install it first:"
    echo "         sudo apt-get install -t trixie-backports firmware-iwlwifi"
    echo "       Then re-run this script."
    exit 1
fi

# Bluetooth CNVi IML — prefer -iml suffix (Lunar Lake format)
echo "--- Bluetooth CNVi (ibt-0190-0291-iml) ---"
BT_SRC_GLOB="/usr/lib/firmware/intel/ibt-0190-0291-iml*"
BT_FILES=$(ls $BT_SRC_GLOB 2>/dev/null || true)
if [[ -n "$BT_FILES" ]]; then
    echo "  [local] found on system (IML format)"
    mkdir -p "$FIRMWARE_DST/intel"
    # shellcheck disable=SC2086
    cp -v $BT_SRC_GLOB "$FIRMWARE_DST/intel/"
else
    extract_packages
    IML_PKG=$(ls "$TMPDIR_WORK/extract/usr/lib/firmware/intel/ibt-0190-0291-iml"* 2>/dev/null || true)
    if [[ -n "$IML_PKG" ]]; then
        mkdir -p "$FIRMWARE_DST/intel"
        # shellcheck disable=SC2086
        cp -v $IML_PKG "$FIRMWARE_DST/intel/"
    else
        echo "  WARNING: ibt-0190-0291-iml* not found"
    fi
fi

# NPU / VPU 40xx
stage_glob \
    "/usr/lib/firmware/intel/vpu/vpu_40xx*" \
    "usr/lib/firmware/intel/vpu/vpu_40xx*" \
    "$FIRMWARE_DST/intel/vpu" \
    "NPU (intel_vpu / vpu_40xx)"

# SOF audio — Lunar Lake IPC4 firmware
stage_dir \
    "/usr/lib/firmware/intel/sof-ipc4/lnl" \
    "usr/lib/firmware/intel/sof-ipc4/lnl" \
    "$FIRMWARE_DST/intel/sof-ipc4/lnl" \
    "SOF audio (sof-lnl IPC4)"

echo ""
echo "==> Staged files (non-xe, non-bin):"
find "$FIRMWARE_DST" \
    \( -path '*/xe/*' -o -path '*/i915/*' \) -prune \
    -o -type f -print | sort

echo ""
echo "==> Next steps:"
echo "    git add hosts/x1g13/mkosi.extra/usr/lib/firmware/"
echo "    ./build.sh x1g13"
