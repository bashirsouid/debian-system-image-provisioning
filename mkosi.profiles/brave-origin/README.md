# Brave Origin

This profile installs the **Brave Origin** web browser (free for Linux) from Brave's official APT repository. Brave Origin is a de‑bloated version of Brave that removes AI chat, Rewards, VPN promos, and other extras while keeping Shields and Chromium security updates.

## Usage
Add the profile to a host descriptor (e.g., `hosts.local/x1g13.conf`):

```ini
profiles = ... brave-origin
```

The profile adds the Brave signing key, configures the APT source, and installs the `brave-origin` package.
