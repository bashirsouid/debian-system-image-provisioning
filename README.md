# mkosi image provisioning

This version keeps the source-built AwesomeWM workflow, but moves regular-user creation back to **first boot** instead of trying to create login users during the mkosi build.

That change is deliberate: with modern mkosi, unprivileged builds run in a single-user namespace, and account creation that needs `chown` to arbitrary UIDs can fail during build scripts. First-boot provisioning avoids that entire class of failure while still giving you a deterministic image.

What changed:
- `mkosi.build` still builds AwesomeWM from `third-party/awesome`
- user data from `.users.json` is converted on the host into `/usr/local/etc/users.tsv`
- a first-boot systemd unit provisions users before normal login services open up
- the root account stays locked by image configuration
- `run.sh` still passes QEMU arguments correctly to `mkosi vm`
- the image is still explicitly configured as a bootable disk image using `systemd-boot`

## Quick start

```bash
./update-3rd-party-deps.sh
cp .users.json.sample .users.json
# edit .users.json and set a real password for your login user
./clean.sh --all
./build.sh --profile devbox
./run.sh --profile devbox
```

On the first boot, the image will provision users from the embedded data and then remove that data from the root filesystem. After the console login appears, log in with the username and password from `.users.json`.

For the devbox profile, start X manually after login:

```bash
startx
```

## Why this is the right shape

The original repository README already said users should be provisioned during first boot. That turns out to be the safer design for rootless mkosi builds as well.

Build-time account creation is still possible when mkosi is run with enough privileges to `chown` files to arbitrary UIDs, but that is not the path this repo now depends on.

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
