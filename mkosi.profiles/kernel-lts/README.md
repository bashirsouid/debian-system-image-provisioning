# kernel-lts

The **stable Debian kernel** for the current release (trixie).

Installs the `linux-image-<arch>` / `linux-headers-<arch>` *meta-package*
for the build architecture, so it always tracks the newest kernel in the
pinned stable archive (see `mkosi.conf.d/15-reproducibility.conf`) and
never needs a version bump.

- **amd64** builds get `linux-image-amd64` / `linux-headers-amd64`.
- **arm64** builds get `linux-image-arm64` / `linux-headers-arm64`.

Architecture is chosen automatically from the build architecture (host
descriptor `architecture =`, default `x86-64`) via `[Match]` drop-ins —
one profile name covers both. This replaces the old per-arch
`kernel-amd64` / `kernel-arm64` profiles.

This is the **signed** Debian kernel, so it boots cleanly under Secure
Boot and its in-tree modules load under lockdown.

For a newer kernel than stable ships (e.g. recent laptop hardware), use
[`kernel-rolling`](../kernel-rolling/README.md) instead.

No secret values are required.
