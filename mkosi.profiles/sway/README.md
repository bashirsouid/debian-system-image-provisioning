# sway

Sway Wayland compositor profile for mkosi.

This profile provides a minimal, Wayland-native desktop environment using sway as the compositor. It includes all necessary Wayland infrastructure, sway-specific tools, and productivity applications.

## Components

- **Compositor**: sway (i3-compatible Wayland compositor)
- **Lock screen**: swaylock
- **Launcher**: wofi
- **Display management**: wdisplays
- **Screenshot tools**: grim + slurp
- **Clipboard**: wl-clipboard
- **Terminal**: kitty (primary) + foot (backup)
- **Audio**: PipeWire + wireplumber
- **Productivity**: mousepad, qalc, atuin, jq

## Dependencies

This profile includes its own audio stack (PipeWire) and does not depend on the separate `audio-pipewire` profile. It also includes Bluetooth support via bluez and network utilities.

## Usage

Include in your host profile list:
```
profiles = desktop-sway
```

Or select individual profiles:
```
profiles = sway audio-pipewire bluetooth wifi dev-tools ssh-server
```

## Notes

- No X11 components are included (no xorg, no xserver-xorg-legacy)
- GNOME components are intentionally excluded
- Display manager: Uses GDM3 via the `desktop-sway` role (configured separately)
- Session file: `/usr/share/wayland-sessions/sway.desktop`