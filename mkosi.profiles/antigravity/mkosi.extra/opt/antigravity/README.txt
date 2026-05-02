Drop the Antigravity AppImage here:

    /opt/antigravity/Antigravity.AppImage

Then mark it executable:

    sudo chmod +x /opt/antigravity/Antigravity.AppImage

The /usr/local/bin/antigravity launcher and the
/usr/local/share/applications/antigravity.desktop entry will pick it
up automatically — no rebuild required.

Why isn't it baked into the image? Google does not currently ship
Antigravity through a stable apt repo or Flathub remote, so the
download URL is not safe to pin into a reproducible build. Once
Antigravity lands on Flathub, this profile will switch to a first-
boot `flatpak install` oneshot.
