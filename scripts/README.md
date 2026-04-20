# scripts/

Build-pipeline internals. Nothing in here is a user-facing command — these
scripts are invoked by `build.sh`, `update-3rd-party-deps.sh`, CI, or by each
other. Their argument shapes are allowed to change whenever the build scripts
change, so don't build anything outside the repo around them.

User-facing commands live in `bin/`. Scripts that ship into the hardware-test
USB bundle and run from the booted USB live in `installer/`.

## Contents

### Build-time helpers (called by `build.sh` / `update-3rd-party-deps.sh`)

| Script                            | Called from                                  | What it does                                                          |
| --------------------------------- | -------------------------------------------- | --------------------------------------------------------------------- |
| `fetch-third-party-keys.sh`       | `update-3rd-party-deps.sh`, `build.sh`       | Fetch third-party apt keys and pin them by fingerprint.               |
| `package-credentials.sh`          | `build.sh`                                   | Encrypt per-host secrets into `mkosi.extra/etc/credstore.encrypted/`. |
| `package-alert-credentials.sh`    | `build.sh`                                   | Same, for the alerting-stack credentials.                             |
| `export-sysupdate-artifacts.sh`   | `build.sh` (post-build)                      | Export versioned root/UKI/BLS artifacts for `systemd-sysupdate`.      |
| `verify-build-secrets.sh`         | `build.sh` (preflight)                       | Audit `.mkosi-secrets/` shape and permissions.                        |
| `verify-no-baked-identity.sh`     | `build.sh` (preflight)                       | Refuse to build if per-machine identity files are tracked.            |
| `usb-write-and-verify.sh`         | `bin/write-live-test-usb.sh`                 | Raw-image write to a USB device with hash-back verification.          |
| `lint.sh`                         | `build.sh`, `.github/workflows/lint.yml`     | Run shellcheck across overlay-owned shell scripts.                    |

### Sourced libraries (not executables)

| File                            | Exposes                                                                                                    |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `lib/host-deps.sh`              | Debian/Ubuntu auto-install helpers (`AB_AUTO_INSTALL_DEPS`).                                               |
| `lib/build-meta.sh`             | Reader/writer for `mkosi.output/.latest-build.*.env`.                                                      |
| `lib/confirm-destructive.sh`    | Interactive/--yes confirmation prompts for scripts that wipe disks or USBs.                                |

Scripts in `bin/` and `installer/` reference `lib/` files through shellcheck
directives of the form `# shellcheck source=SCRIPTDIR/../scripts/lib/foo.sh`
so the lint can follow the source unambiguously regardless of which directory
the caller lives in.

## Adding a new script here

A script belongs in `scripts/` if it is only ever invoked by another script
in this repo (by `build.sh`, by CI, by another helper here). If a human is
expected to run it directly, promote it to `bin/` and give it a `Usage:`
block and a mention in the top-level `README.md` or `docs/`.
