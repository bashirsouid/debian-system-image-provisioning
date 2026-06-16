# kernel-rolling

The **newest Linux kernel from `trixie-backports`**, auto-tracked.

Use this when stable's kernel is too old for your hardware (recent
laptops — Lunar Lake, new Wi-Fi/GPU/NPU, etc.).

## How it works

Installs the `linux-image-<arch>` / `linux-headers-<arch>` *meta-package*
and pins the kernel stack to `trixie-backports`
(`preferences.d/kernel-rolling.pref`, priority 600). apt then resolves
the meta-package to whatever the newest backports kernel is **at build
time** — 7.0.x today, later 7.x tomorrow.

- **amd64** builds get `linux-image-amd64` (→ newest backports amd64 kernel).
- **arm64** builds get `linux-image-arm64` (→ newest backports arm64 kernel).

Architecture is chosen automatically from the build architecture via
`[Match]` drop-ins.

## Why not pin an exact version?

The previous `kernel-6-18` profile pinned `linux-image-6.18.15+deb13-amd64`
by exact name. Debian backports keeps only the latest kernel ABI and
drops old point-releases, so once backports moved to 7.0.x that package
disappeared, apt couldn't install it, and the build failed with *"A
bootable image was requested but no kernel was found"*. The meta-package
+ pin approach can't go stale.

## Reproducibility note

Unlike the rest of the image (pinned to the snapshot mirror in
`mkosi.conf.d/15-reproducibility.conf`), the kernel here floats against
**live** backports by design. If you need a reproducible or specific
kernel — e.g. a driver that regresses on newer releases — pin it in the
relevant hardware profile instead (see `mkosi.profiles/macbook/mkosi.conf`,
which pins the T2 kernel for the CS8409 audio driver).

## Secure Boot

Fully compatible. mkosi wraps the kernel in a UKI and signs it with the
host's `.secureboot` key (`25-native-uki.conf` + the generated
`30-secure-boot.conf`), and Debian-signed in-tree modules load under
Secure Boot lockdown — independent of kernel version.

No secret values are required.
