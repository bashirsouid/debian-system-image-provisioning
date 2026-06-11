# tor-browser

This profile installs Tor Browser Launcher (`torbrowser-launcher`) from Debian's `contrib` repository.

On first run, the launcher downloads and verifies the official Tor Browser bundle from the Tor Project, installs it to `~/.local/share/torbrowser/`, and launches it. Subsequent runs use the installed browser, which self-updates.

## Usage

Add to your host descriptor:

```ini
profiles = tor-browser
```

The `contrib` component is enabled via the profile's `trixie-contrib.sources` file.