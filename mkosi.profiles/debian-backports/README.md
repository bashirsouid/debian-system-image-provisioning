# debian-backports

Repo-only base profile that enables the **`trixie-backports`** apt suite. It
ships just `etc/apt/sources.list.d/trixie-backports.sources` (signed by the
standard `debian-archive-keyring` already in the image) — no packages, no pins.

You don't select it directly: profiles that need backports declare
`requires=debian-backports` in their manifest and the resolver pulls it in
automatically (once, even if several profiles require it). Current consumers:

- `kernel-rolling` — pins the kernel stack to backports (`kernel-rolling.pref`).
- `thinkpad-x1g13` — pins firmware to backports (`firmware-from-backports`).

Each consumer keeps its own `preferences.d` pin for the specific packages it
wants from backports; this profile only makes the suite available.

> Do not add a bare `Packages=` here — an empty list assignment resets mkosi's
> whole package list. A repo-only profile needs no `[Content] Packages=`.

No secret values are required.
