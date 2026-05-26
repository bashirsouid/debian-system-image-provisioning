# Laptop‑Screen Recovery Profile

## Overview

The `laptop-screen` profile ensures that the built‑in laptop panel (eDP) is never left disabled after monitors are unplugged. It provides three independent recovery mechanisms:

| Mechanism | Trigger | What runs | Enabled by default |
|-----------|---------|------------|-------------------|
| **Key‑bind (Triggerhappy)** | Press **Fn + F8** or the `KEY_DISPLAYTOGGLE` key | `/usr/local/bin/monitor-fallback.sh` (via Triggerhappy) | Yes – the profile installs `triggerhappy` and the key bindings |
| **Udev hot‑plug** | Kernel reports a DRM connector event (monitor plug/unplug) | `monitor-fallback.service` → `monitor-fallback.sh` | Yes – udev rule `99‑monitor‑hotplug.rules` |
| **Systemd timer fallback** | Every minute (first run 1 min after boot) | Same service/script as above | Yes – `monitor-fallback.timer` |

All three paths call the **same** recovery script, so the behavior is identical regardless of how it is invoked.

## File layout

```
mkosi.profiles/
└─ laptop‑screen/
   ├─ mkosi.conf                     # declares dependency on x11‑xserver‑utils
   ├─ profile.manifest               # description of the profile
   ├─ mkosi.extra/
   │   ├─ etc/
   │   │   ├─ systemd/
   │   │   │   ├─ enable‑monitor‑services.service
   │   │   │   ├─ monitor‑fallback.service
   │   │   │   └─ monitor‑fallback.timer
   │   │   └─ udev/
   │   │       └─ rules.d/
   │   │           └─ 99‑monitor‑hotplug.rules
   │   └─ usr/
   │       └─ local/
   │           ├─ bin/
   │           │   └─ monitor‑fallback.sh   # core recovery script
   │           └─ sbin/
   │               └─ enable‑monitor‑services.sh
   └─ README.md                      # (this file)
```

## How the recovery script works

`/usr/local/bin/monitor-fallback.sh`:

1. Detects the user owning the active X session (using `loginctl`, `who`, `logname`, or fallback to the first regular UID).
2. Exports `DISPLAY=:0` and sets `XAUTHORITY` to the user’s `.Xauthority`.
3. Uses `xrandr` to:
   - Re‑enable **all** connected outputs (`--auto`).
   - If **no external** monitor (HDMI/DP/DVI/VGA/USB‑C/DisplayPort) is connected, makes the internal panel (`eDP`/`LVDS`) primary.
4. The script is idempotent – running it repeatedly does not cause side effects.

## Triggerhappy key bindings

The key bindings are installed by the `screen-f8-recovery-key` profile but are overridden here to point to the unified script:

- `KEY_DISPLAYTOGGLE` → `/usr/local/bin/monitor-fallback.sh`
- `KEY_F8` → `/usr/local/bin/monitor-fallback.sh`

The file is located at:

```
/etc/triggerhappy/triggers.d/screen-wake.conf
```

## Systemd units

| Unit | Description | When enabled |
|------|-------------|--------------|
| `monitor-fallback.service` | Executes the recovery script once | Enabled automatically by the udev rule |
| `monitor-fallback.timer`   | Calls the service every minute | Enabled by `enable-monitor-services.service` |
| `enable-monitor-services.service` | Enables the timer, reloads udev, and (if present) starts `triggerhappy.service` | Enabled by default (installed in the profile) |

## Enabling / Disabling individual layers

- **Disable the timer**: `systemctl disable --now monitor-fallback.timer`
- **Disable udev rule**: remove or rename `/etc/udev/rules.d/99‑monitor‑hotplug.rules`
- **Disable key‑bind**: edit `/etc/triggerhappy/triggers.d/screen-wake.conf` and comment out the lines.

## Troubleshooting

1. **Script does nothing** – Check that an X server is running (`pgrep Xorg`). Look at `journalctl -u monitor-fallback.service` for errors.
2. **Key‑bind not recognized** – Verify `triggerhappy` is running: `systemctl status triggerhappy.service`. Restart with `systemctl restart triggerhappy.service`.
3. **Udev rule not firing** – Run `udevadm test /sys/class/drm/card0` and look for the `RUN+` line. Ensure `systemd-udevd` is active.
4. **External monitor stays off after plug‑in** – Confirm the monitor appears in `xrandr --query`. If not, check the cable and driver.

## Compatibility notes

- The script assumes the internal panel is named `eDP*` or `LVDS*`. Adjust `INTERNAL_OUTPUT` inside the script if your hardware uses a different name.
- Works with any display manager (GDM, LightDM, etc.) because it discovers the active X session dynamically.
- The recovery logic does not depend on the window manager; it works even when AwesomeWM is not yet running.

## License

This profile is part of the *my‑mkosi‑test* repository and is distributed under the same license as the rest of the project.

---

*End of file*