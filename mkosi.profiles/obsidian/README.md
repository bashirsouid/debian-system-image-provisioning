# obsidian

This profile installs the Obsidian markdown editor (`md.obsidian.Obsidian`) via Flatpak from Flathub.

## Integration
- Automatically pulls in the `flatpak` profile via `requires="flatpak"` in `profile.manifest`.
- Ships font packages (`fonts-noto-color-emoji`, `fonts-symbola`, `fonts-dejavu-core`, `fonts-liberation2`) for text rendering.
- Deploys `obsidian-flatpak-init.service` & `.timer` systemd units to install Obsidian from Flathub on first boot.
