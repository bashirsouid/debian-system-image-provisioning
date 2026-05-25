# Agent Instructions

## Exclude `mkosi.cache/` from exploration

- Agents **must never** explore, search, or read files inside the `mkosi.cache/` directory.
- This folder contains temporary build artifacts and does not contain any relevant source code or answers.
- All code searches (`grep`, `rg`, tool exploration, etc.) should explicitly skip this directory.

## Additional exclusions

- `mkosi.pkgcache/` – cached Debian package files.
- `mkosi.builddir/` – persistent mkosi build scratch directory (ccache, meson, cmake).
- `mkosi.tmp/` – temporary build space used via the `TMPDIR` environment variable.
- `mkosi.workspace/` – mkosi workspace directory.
- `mkosi.output/` – generated build output artifacts (raw images, EFI files, etc.).
- `.mkosi-metadata/` – generated metadata for first‑boot provisioning.
- `.mkosi-thirdparty/` – third‑party source checkouts managed by the build scripts.
- `.live-usb-stage/` – temporary staging area for hardware‑test USB builds.
- `.shellcheck-cache/` – local linting cache.

*End of instructions.*