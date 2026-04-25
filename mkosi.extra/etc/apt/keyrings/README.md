# /etc/apt/keyrings — owned by profiles, not the base image

This directory used to hold every fetched third-party signing key
(`tailscale-archive-keyring.gpg`, `cloudflare-main.gpg`). After the
profile-composition refactor, each profile owns its own keys at:

    mkosi.profiles/<profile>/mkosi.extra/etc/apt/keyrings/<key>.gpg

That way a key only ends up in the image when its profile is selected.
The key fetching itself is driven by per-profile manifests:

    mkosi.profiles/<profile>/apt-keys.conf

`scripts/fetch-third-party-keys.sh` reads each manifest, downloads the
key, verifies the pinned fingerprint, and writes the dearmored key to
the profile's `mkosi.extra/etc/apt/keyrings/` tree.

Keys are NOT committed because they rotate. To add a new third-party
apt repo:

1. Drop a `<repo>.sources` file under
   `mkosi.profiles/<profile>/mkosi.extra/etc/apt/sources.list.d/`
   with `Signed-By: /etc/apt/keyrings/<key>.gpg`.
2. Add a `KEY_n_*` block to `mkosi.profiles/<profile>/apt-keys.conf`
   with a freshly verified fingerprint (see `mkosi.profiles/tailscale/
   apt-keys.conf` for the format).
3. Run `scripts/fetch-third-party-keys.sh` (or
   `update-3rd-party-deps.sh --fresh`).

The signing key files must be dearmored (binary GPG format, not ASCII
armored) and mode 0644 — apt refuses armored keys referenced via
`Signed-By=` on modern Debian. The fetch script handles that.

Anything left in THIS base directory is documentation; image keys
live under their owning profile.
