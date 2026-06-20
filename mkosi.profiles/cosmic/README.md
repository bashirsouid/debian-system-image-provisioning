# cosmic

COSMIC desktop environment profile (System76). **Status: stub.**

COSMIC is a Wayland-native desktop environment written in Rust by
System76. It is the default DE on Pop!_OS 24.04+.

## Current state

This profile installs Wayland infrastructure and desktop utilities but
**does not yet install COSMIC itself** — the packages are commented out
in `mkosi.conf` because COSMIC is not available in Debian's official
repositories (Trixie or Sid).

The display manager is **GDM3** (provided by the separate
`display-manager-gdm3` profile). GDM3 will show a COSMIC session
option once `cosmic-session` is installed and registers its
`/usr/share/wayland-sessions/cosmic.desktop` entry.

## Enabling COSMIC packages

Once a Debian-compatible package source is available, do the following:

1. **Add the apt source** — create `apt-keys.conf` in this profile
   directory and drop a `.sources` file under
   `mkosi.extra/etc/apt/sources.list.d/`.
2. **Uncomment packages** — edit `mkosi.conf` and uncomment the
   `cosmic-*` package lines.
3. **Swap portal** — replace `xdg-desktop-portal-gtk` with
   `xdg-desktop-portal-cosmic` when it becomes available.

### Package source options

| Option | Pros | Cons |
| --- | --- | --- |
| Build from source ([cosmic-epoch](https://github.com/pop-os/cosmic-epoch)) | Latest code, full control | ~30 min build, heavy Rust toolchain, complex `mkosi.build` integration |
| Community PPA / OBS repo | Pre-built `.deb` packages | Depends on external maintainer, may lag upstream |
| Fedora RPM conversion | Some scripts exist on GitHub | Fragile, not recommended for production |

No secret values are required unless otherwise documented.
