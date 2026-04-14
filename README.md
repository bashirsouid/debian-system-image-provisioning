# mkosi image provisioning (stabilized)

This version is focused on getting you a reproducible, testable image first.

What changed:
- user provisioning happens at build time in `mkosi.finalize` using host-side `useradd/usermod/groupadd -R`, not a plain `chroot` block
- the fragile AwesomeWM source build step was removed; the `devbox` profile now uses Debian packages only
- the broken Liquorix repository hook was removed for now
- the custom `nsswitch.conf` override was removed so Debian defaults apply
- `run.sh` now passes QEMU arguments to `mkosi vm` correctly
- the image is explicitly configured as a bootable disk image using `systemd-boot`

## Quick start

```bash
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
