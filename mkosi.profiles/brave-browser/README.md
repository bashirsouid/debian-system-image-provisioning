# Brave Browser

This profile installs the **Brave** web browser (free for Linux users) from Brave's official APT repository.

## Usage
Add the profile to a host descriptor (e.g., `hosts.local/x1g13.conf`):

```ini
profiles = ... brave-browser
```

The profile adds the Brave signing key, configures the APT source, and installs the `brave-browser` package.
