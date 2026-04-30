# installer/

Scripts that are **copied into the hardware-test USB bundle by
`bin/write-live-test-usb.sh` and then executed from the booted USB**, not
from your build or admin host.

This directory exists so it is obvious at a glance which files leave the
build host and end up running somewhere else. User-facing commands for the
build host live in `bin/`. Build-pipeline internals live in `scripts/`. Code
that runs on the booted *target* image (not the USB) lives under
`mkosi.extra/usr/local/`.

## Contents

| Script                     | Runs where                                                    | What it does                                                                                                        |
| -------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `live-usb-install.sh`      | Booted hardware-test USB, via `/root/INSTALL-TO-INTERNAL-DISK.sh` | Thin interactive wrapper around `bin/write-live-test-usb.sh`. Asks for target disk + ESP / root / home / data sizing, defaults `--allow-fixed-disk` to `yes`, and forwards everything to the same partition + seed + bootloader code path that produced the USB you are booting from. |

## How it gets onto the USB

`bin/write-live-test-usb.sh` bootstraps a USB with the native
retained-version layout, then copies this directory plus a small subset of
`bin/` and `scripts/lib/` into the USB's bundle directory
(default: `/root/ab-installer/`). The bundle mirrors the layout of this
repo, so `installer/live-usb-install.sh` can reach
`bin/write-live-test-usb.sh` (the unified install script) at a stable
relative path inside the bundle and run it as the on-target installer.

After booting the USB you run:

```
sudo /root/INSTALL-TO-INTERNAL-DISK.sh
```

That wrapper `exec`s `/root/ab-installer/installer/live-usb-install.sh`.

## Adding a new script here

Put a script in `installer/` only if it is specifically intended to run
from a booted hardware-test USB. If it runs on the build host, it belongs
in `bin/` (user-facing) or `scripts/` (build-internal).
