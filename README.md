# mkosi image provisioning

This version keeps the fixes for account provisioning and bootability **without** dropping your source-built AwesomeWM workflow.

What changed:
- user provisioning happens at build time in `mkosi.finalize` using mkosi-compatible host-side account tools
- the devbox profile still installs Debian's `awesome` package for runtime dependency coverage, then `mkosi.build` overlays the latest AwesomeWM built from `third-party/awesome`
- the AwesomeWM build now runs inside `mkosi-chroot`, so `BuildPackages=` are available from mkosi instead of depending on random host libraries
- `run.sh` passes QEMU arguments to `mkosi vm` correctly
- the image is explicitly configured as a bootable disk image using `systemd-boot`

## Quick start

```bash
./update-3rd-party-deps.sh
cp .users.json.sample .users.json
# edit .users.json and set a real password for your login user
./build.sh --profile devbox
./run.sh --profile devbox
```

Console login should work with the username/password from `.users.json`.
For the devbox profile, log in on the text console and then run:

```bash
startx
```

## How the AwesomeWM source build works

The devbox profile intentionally keeps the distro `awesome` package installed so Debian resolves the runtime dependency set for you. During `mkosi.build`, the current Git checkout in `third-party/awesome` is compiled and installed into the image's `DESTDIR` overlay, replacing the older packaged AwesomeWM files in the final image.

That keeps the image reproducible while still tracking upstream AwesomeWM development from Git.

## Bare-metal testing

This project currently emits a whole-disk image (`Format=disk`).
That is ideal for:
- `mkosi vm`
- `mkosi burn /dev/<disk>`
- `dd` to a spare whole disk or USB device

It is **not** the right long-term format for writing directly to an already-existing
single root partition in an A/B setup, because the image contains its own partition
layout and EFI system partition.

Get the image booting first in QEMU and on a spare disk. After that, move the A/B
rollout layer to `systemd-sysupdate` / `mkosi sysupdate` with explicit transfer
files.
