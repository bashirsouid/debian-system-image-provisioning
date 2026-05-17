# x1g13 host overlay (ThinkPad X1 Carbon Gen 13)

This overlay is a workstation-oriented host configuration for the Lenovo X1 Carbon Gen 13 with Intel Lunar Lake (Core Ultra 200V) processor.

Use it with:

```bash
./build.sh --profile devbox --host x1g13
```

## Hardware status

| Component | Driver | Status | Notes |
|-----------|--------|--------|-------|
| GPU (Arc / Xe LPG) | `xe` | ✓ Working | i915 blacklisted; xe firmware shipped in extra tree |
| Display (1920×1200 IPS) | `xe` / KMS | ✓ Working | `video=eDP-1:1920x1200@60` forces correct console res |
| Wi-Fi (BE201 / WiFi 7) | `iwlwifi` + `iwlmvm` | ✓ Working | Needs `firmware-iwlwifi` from trixie-backports (bz-b0-fm-c0 series) |
| Bluetooth (CNVi IML) | `btintel` | ✓ Working | Needs `ibt-0190-0291-iml.sfi` from backports `firmware-iwlwifi` |
| Audio (SOF / HDA) | `snd-sof-pci-intel-lnl` | ✓ Working | Needs `firmware-sof-signed` (in `thinkpad-g13` profile) |
| NPU (VPU 40xx) | `intel_npu` | ✓ Working | Needs `firmware-misc-nonfree` from backports; module auto-loaded |
| TrackPoint | `psmouse` | ✓ Working | Detected as Elan TrackPoint |
| Keyboard / Fn keys | `thinkpad_acpi` | ✓ Working | rfkill, backlight brightness, battery status all exposed |
| ThinkPad power mgmt | `tlp` | ✓ Working | Configured via `etc/tlp.conf` |
| Fan control | `thinkfan` | ⚠ Disabled | Installed but disabled; needs `/etc/thinkfan.yaml` before use |

## What this overlay provides

- Backports apt source + pin for Lunar Lake firmware packages (`trixie-backports`)
- xe firmware shipped as binaries in `mkosi.extra/usr/lib/firmware/xe/` and `i915/`
- i915 blacklisted system-wide (modprobe.d + kernel cmdline) so xe driver wins
- Wi-Fi power-save enabled; `11n_disable` removed (was limiting 5 GHz on WiFi 7)
- Wi-Fi / Bluetooth / NPU modules added to initramfs so firmware loads before LUKS unlock
- TLP ThinkPad power management with SSD write-back caching
- Intel NPU kernel module (`intel_npu`) auto-loaded at boot
- Display resolution forced to 1920×1200 at KMS layer
- GPU runtime suspend (5 s autosuspend) via tmpfiles.d

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

- **Firmware backports** (`etc/apt/preferences.d/firmware-from-backports`,
  `etc/apt/sources.list.d/trixie-backports.sources`): Trixie stable's
  `firmware-nonfree` snapshot predates Lunar Lake launch and lacks the BE201
  WiFi, CNVi BT IML, NPU VPU, and SOF LNL firmware blobs.  Remove both files
  once trixie stable ships `firmware-nonfree >= 20241210`.

- **xe firmware in tree** (`mkosi.extra/usr/lib/firmware/xe/`, `i915/`):
  xe GuC/HuC/GSC and i915/xe2lpd DMC firmware are shipped as binary blobs
  because at time of writing the Trixie `firmware-misc-nonfree` snapshot may
  not include the exact Lunar Lake versions.  Remove these blobs once the
  package ships matching or newer versions and is stable.
