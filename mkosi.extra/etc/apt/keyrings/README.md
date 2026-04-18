# /etc/apt/keyrings inside the image

Holds the PUBLIC signing keys for third-party apt repos used by the
mkosi build.

Keys are NOT committed because they rotate. They are fetched and
placed here by `scripts/fetch-third-party-keys.sh`, which should be
called from `update-3rd-party-deps.sh`.

Expected files after fetching:

    cloudflare-main.gpg
    tailscale-archive-keyring.gpg

The signing key files must be dearmored (binary GPG format, not ASCII
armored) and mode 0644. apt refuses to use armored keys referenced via
`Signed-By=` on modern Debian.

Corresponding sources files:

    /etc/apt/sources.list.d/cloudflared.sources
    /etc/apt/sources.list.d/tailscale.sources

If you need to add a new third-party repo, follow the same pattern:
one Deb822 .sources file here, one fetched+verified keyring, one entry
in scripts/fetch-third-party-keys.sh with a pinned fingerprint.
