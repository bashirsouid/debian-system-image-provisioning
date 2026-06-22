# joystickwake

**Prevents DPMS timeout (screen blanking) when using a joystick/gamepad controller.**

This profile configures joystickwake to run as a user systemd service. The upstream source is cloned during the mkosi build phase and installed to `/usr/bin/joystickwake`, where the systemd user service `joystickwake.service` auto-starts it at user login.

## Configuration

If needed, create `~/.config/joystickwake/joystickwake.conf` to override defaults:

```ini
command = xdg-screensaver reset
cooldown = 30
loglevel = warning
```

See the [upstream documentation](https://codeberg.org/forestix/joystickwake) for available options.

## Debugging

Start manually with debug logging:
```bash
/usr/bin/joystickwake --loglevel debug
```

## Dependencies

- **Python runtime**: `python3`, `python3-pyudev`, `python3-setuptools`
- **Optional enhancements**: `python3-dbus-next` (D-Bus session idle inhibition), `python3-xlib` (clean X11 exit)

No secret values are required unless otherwise documented.
