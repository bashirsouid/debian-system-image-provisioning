# bin/

User-facing commands you run by hand on a build or admin host. Each script
here has a `Usage:` help block (`--help`), is referenced from the top-level
`README.md` and `docs/`, and is part of the supported public surface of this
repo.

These commands are distinct from the helpers under `scripts/`, which are
build-pipeline internals that `build.sh` / CI orchestrate on your behalf.
The single install script in this directory is *also* the script that ends
up at `/root/ab-install.sh` on a freshly seeded disk, so the same code
runs whether you are creating the test USB on the build host or
re-imaging another disk after booting from that USB.

## Contents

| Script                              | What it does                                                                                         |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `ab-install.sh`                     | Single self-contained install script. Partitions ESP + 2 retained root slots + optional /home + /mnt/data on a target disk (USB or internal), dd's the .root.raw into one slot, installs systemd-boot + writes a Type 1 BLS entry, and copies itself + the image artifacts into `/root/` on the seeded disk so that disk can re-image others without the repo. |
| `sysupdate-local-update.sh`         | In-place `systemd-sysupdate` run on an already bootstrapped machine.                                 |
| `verify-image-raw.sh`               | Sanity-check a built `image.raw` (GPT layout, ESP bootloader, rootfs identity, credential perms) before you flash it. Safe to run without root for partition-level checks; `sudo` unlocks the filesystem-level checks via `systemd-dissect`. |
| `generate-secureboot-keys.sh`       | Generate the local Secure Boot signing key + cert that mkosi uses to sign the UKI.                   |
| `hash-password.sh`                  | Interactive helper that prints a yescrypt hash or a ready-to-paste `.users.json` entry.              |
| `test-rollback.sh`                  | QEMU smoke test of the retained-version rollback state machine.                                      |
| `ab-flash.sh`                       | **Legacy** manual A/B flasher. Kept only as a fallback; use `ab-install.sh` instead.                 |

## Adding a new script here

Promote a script to `bin/` only if **all** of the following are true:

1. A human is expected to invoke it directly (not `build.sh` or CI).
2. It has a `Usage:` help block and is documented in the top-level `README.md`
   or in `docs/`.
3. Its command-line interface is part of the repo's supported surface
   (breaking it requires a deliberate migration note).

Otherwise the script belongs in `scripts/` (build-internal).
