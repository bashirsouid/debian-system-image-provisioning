# x1g13 host overlay (ThinkPad X1 Carbon Gen 13)

This overlay is a workstation-oriented host configuration for the Lenovo X1 Carbon Gen 13 with Intel Lunar Lake (Core Ultra 200V) processor.

Use it with:

```bash
./build.sh --profile devbox --host x1g13
```

## First-time setup: stage Lunar Lake firmware

Trixie stable's `firmware-nonfree` snapshot predates the Lunar Lake launch and
is missing WiFi, Bluetooth, NPU, and audio firmware for this machine.  Run this
once on the build host **before** the first build:

```bash
# Install backports firmware on the build host so the script can copy from it
sudo apt-get install -t trixie-backports \
    firmware-iwlwifi firmware-misc-nonfree firmware-sof-signed

# Stage the Lunar Lake blobs directly into the extra tree
bash scripts/fetch-lnl-firmware.sh

# Commit the resulting binary files and rebuild
git add hosts/x1g13/mkosi.extra/usr/lib/firmware/
./build.sh x1g13
```

The script copies the blobs from the local system into
`hosts/x1g13/mkosi.extra/usr/lib/firmware/` so they are checked into git and
the image build never depends on APT timing or incremental-cache state.

## Hardware status

| Component | Driver | Status | Notes |
|-----------|--------|--------|-------|
| GPU (Arc / Xe LPG) | `xe` | ✓ Working | i915 blacklisted; xe firmware in extra tree |
| Display (1920×1200 IPS) | `xe` / KMS | ✓ Working | `video=eDP-1:1920x1200@60` sets KMS console res |
| Wi-Fi (BE201 / WiFi 7) | `iwlwifi` + `iwlmvm` | ⚠ Needs setup | Run `scripts/fetch-lnl-firmware.sh` to stage bz-b0-fm-c0 blobs |
| Bluetooth (CNVi IML) | `btintel` | ⚠ Needs setup | Same script stages `ibt-0190-0291-iml.sfi` |
| Audio (SOF / HDA) | `snd-sof-pci-intel-lnl` | ⚠ Needs setup | Same script stages `sof-lnl.ri` IPC4 blob |
| NPU (VPU 40xx) | `intel_npu` | ⚠ Needs setup | Same script stages `vpu_40xx_v1.bin` |
| TrackPoint | `psmouse` | ✓ Working | Detected as Elan TrackPoint |
| Keyboard / Fn keys | `thinkpad_acpi` | ✓ Working | rfkill, backlight brightness, battery status all exposed |
| ThinkPad power mgmt | `tlp` | ✓ Working | Configured via `etc/tlp.conf` |
| Fan control | `thinkfan` | ⚠ Disabled | Needs `/etc/thinkfan.yaml` before enabling |

## What this overlay provides

- Lunar Lake firmware shipped as binaries in `mkosi.extra/usr/lib/firmware/`
  (xe GPU blobs pre-staged; WiFi/BT/NPU/audio populated by `fetch-lnl-firmware.sh`)
- i915 blacklisted system-wide (modprobe.d + kernel cmdline) so xe driver wins
- Wi-Fi power-save enabled; `11n_disable` removed (was limiting 5 GHz on WiFi 7)
- Wi-Fi / Bluetooth / NPU modules in initramfs so firmware loads before LUKS unlock
- TLP ThinkPad power management with SSD write-back caching
- Intel NPU kernel module (`intel_npu`) auto-loaded at boot
- Display resolution forced to 1920×1200 at KMS layer
- GPU runtime PM left to the kernel/TLP; the old tmpfiles.d override was
  removed because xe rejects those writes on this hardware

## Enabling fan control (optional)

thinkfan is installed but disabled by default.  Once you know the correct sensor
and fan sysfs paths for your machine, create `/etc/thinkfan.yaml`:

```yaml
# Example — verify hwmon paths with: ls /sys/class/hwmon/*/name
fans:
  - tpacpi: /proc/acpi/ibm/fan

levels:
  - ["level auto", 0, 100]
```

Then: `systemctl enable --now thinkfan`

## TODOs / known workarounds

- **All Lunar Lake firmware in tree** (`mkosi.extra/usr/lib/firmware/`):
  All Lunar Lake firmware blobs (xe GPU, WiFi bz-b0, BT IML, NPU VPU, SOF LNL)
  are shipped as binaries in the extra tree because Trixie stable's
  `firmware-nonfree` snapshot predates the Lunar Lake launch (September 2024)
  and does not include them.  Once Trixie stable ships `firmware-nonfree >=
  20241210`, the blobs staged by `fetch-lnl-firmware.sh` can be removed and the
  backports pin in `etc/apt/preferences.d/firmware-from-backports` and source
  in `etc/apt/sources.list.d/trixie-backports.sources` can be deleted.

- **Enabling fan control**: thinkfan is installed but disabled.  Create
  `/etc/thinkfan.yaml` with correct sensor/fan paths then run
  `systemctl enable --now thinkfan`.
