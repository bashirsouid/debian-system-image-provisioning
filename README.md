# mkosi image provisioning

This revision keeps the source-built AwesomeWM workflow, provisions regular users on
**first boot**, fixes the `run.sh` regression, fixes the `clean.sh --all` path,
adds host UID/GID syncing for the build user's matching login account, restores
Liquorix for the `devbox` profile, and adds a repo-owned sample Awesome config
that is seeded only for QEMU test runs.

That combination is the right shape for a rootless mkosi workflow:
- image contents stay reproducible
- regular users are created inside the booted system where real ownership changes work
- your primary login account can keep the same numeric uid/gid as the machine doing the build
- the devbox profile still overlays AwesomeWM from source
- the devbox profile now pulls the Liquorix kernel from its upstream Debian repository

## What changed

- `mkosi.build` still builds AwesomeWM from `third-party/awesome`
- user data from `.users.json` is converted on the host into `/usr/local/etc/users.conf`
- a first-boot systemd unit provisions users before normal login services open up
- the root account stays locked by image configuration
- `run.sh` now uses plain `mkosi vm`, which matches the mkosi invocation that already worked manually
- `clean.sh --all` and `clean.sh --deep` are both accepted explicitly
- `Bootable=` and `Bootloader=` are configured in `[Content]`, matching current mkosi docs
- if a login user in `.users.json` matches the build host's current username, its uid/gid/group are copied into the image data by default
- the devbox `.xinitrc` now tries to set a sensible X resolution before launching AwesomeWM
- `run.sh` now defaults to an ephemeral VM snapshot so test boots do not mutate the raw image you may later flash
- `run.sh` mounts `runtime-seeds/qemu-home/` into the VM for `devbox` runs and first boot seeds it only when `~/.config/awesome` or `~/.config/picom` is missing
- the devbox profile now installs `linux-image-liquorix-amd64` and `linux-headers-liquorix-amd64`
- `build.sh` fetches the official Liquorix keyring and injects the repo into mkosi's package-manager sandbox for the build
- the server profile keeps the stock Debian `linux-image-amd64` kernel path

## Quick start

```bash
./update-3rd-party-deps.sh
cp .users.json.sample .users.json
# edit .users.json and set a real password for your login user
./clean.sh --all
./build.sh --profile devbox
./run.sh --profile devbox
```

On the first boot, the image will provision users from the embedded data and then
remove that data from the root filesystem. After the console login appears, log in
with the username and password from `.users.json`.

For the devbox profile, start X manually after login:

```bash
startx
```

For the `devbox` profile, `run.sh` now also mounts a tiny repo-owned QEMU home seed by default. On first boot inside the VM, the guest will copy that sample data into the login user's home **only if** the target config paths do not already exist. Right now that seed includes:

- `~/.config/awesome/rc.lua` that loads the system Awesome config, then starts `xterm` and `picom`
- `~/.config/picom/picom.conf` for a minimal compositor smoke test

Because `run.sh` defaults to an **ephemeral** VM snapshot, those temporary test-home changes do not modify the built `image.raw` that you may later flash. Use `./run.sh --persistent` only when you intentionally want writes kept in the VM disk image.

If you want a different X resolution, set `STARTX_RESOLUTION` before launching X:

```bash
STARTX_RESOLUTION=1920x1080 startx
```

## Liquorix notes

The `devbox` profile now uses Liquorix again, while the `server` profile keeps Debian's
stock kernel. The build script pulls the Liquorix keyring from the official upstream URL,
renders a DEB822 source for the current Debian suite from `mkosi.conf`, and passes it to
mkosi using `--sandbox-tree` so package installation works during the build.

If you later test this image on bare metal, remember that Liquorix is a third-party kernel
track meant for interactive desktops rather than conservative server deployments.

## User IDs for A/B-style local state

By default, `build.sh` copies the invoking host user's numeric uid/gid/group into
any `.users.json` entry whose `username` matches that host username. That is the
safest default for preserving ownership on a shared `/home` or other mutable data
when switching between root slots built on the same machine.

You can also pin ids explicitly per user in `.users.json`:

```json
[
  {
    "username": "demo",
    "password": "change-me-now",
    "can_login": true,
    "uid": 1000,
    "gid": 1000,
    "primary_group": "demo"
  }
]
```

To disable automatic host-id syncing for the matching host username:

```bash
./build.sh --profile devbox --sync-host-ids=no
```

## Persistent `/home` and host-home testing

There are two sane modes here:

1. For real A/B-style machines, keep `/home` outside the image on its own
   persistent partition or subvolume and mount it only on the machines that need it.
2. For QEMU compatibility testing on the build host, use runtime sharing rather
   than baking the host's live `/home` into the image design.

This tree already supports host-specific overlays through `--host NAME`, so you can
build a machine-specific image that mounts external `/home` only on that machine:

```bash
./build.sh --profile devbox --host evox2
```

The example overlay in `hosts/evox2/` mounts a partition labeled `HOME` on `/home`
with `nofail,x-systemd.automount`. Edit that overlay to use the real `UUID=`,
`PARTUUID=`, `LABEL=`, or filesystem type for the target machine.

For temporary VM testing against your real host config, `run.sh` still exposes mkosi's
native runtime mount features when you want them:

```bash
# share only the Awesome config
./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"

# or mount the whole current home at /root for a disposable test VM
./run.sh --runtime-home
```

The first option is useful when you specifically want to compare against your real AwesomeWM config. Because mkosi maps the invoking host user to `root` inside runtime trees, use that mode for copying config into the guest rather than symlinking directly to the shared path. `--runtime-home` is the broader whole-home option, but it mounts the host home at `/root` in the guest rather than replacing your login user's real home directly.

See `docs/home-storage.md` for the trade-offs.

## Bare-metal testing

This project still emits a whole-disk image (`Format=disk`).
That is ideal for:
- `mkosi vm`
- `mkosi burn /dev/<disk>`
- `dd` to a spare whole disk or USB device

It is **not** the long-term update format for writing directly into an already-existing
single root partition in an A/B setup, because the image contains its own partition
layout and EFI system partition.

Get the image booting first in QEMU and on a spare disk. Then move the A/B rollout
layer to `systemd-sysupdate` / `mkosi sysupdate` with explicit transfer files.

See `docs/ab-workflow.md` for the next-stage requirements.


For the `devbox` profile we keep `dpkg` and `kmod` in the image and disable mkosi package-metadata cleanup. This avoids a Debian/apt cleanup edge case where purging `dpkg` causes `kmod` auto-removal to fail because `kmod` maintainer scripts call `dpkg-maintscript-helper`.
