# mkosi image provisioning

This revision keeps the source-built AwesomeWM workflow, provisions regular users on
**first boot**, fixes the `run.sh` regression, fixes the `clean.sh --all` path, and
adds host UID/GID syncing for the build user's matching login account.

That combination is the right shape for a rootless mkosi workflow:
- image contents stay reproducible
- regular users are created inside the booted system where real ownership changes work
- your primary login account can keep the same numeric uid/gid as the machine doing the build
- the devbox profile still overlays AwesomeWM from source

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

If you want a different X resolution, set `STARTX_RESOLUTION` before launching X:

```bash
STARTX_RESOLUTION=1920x1080 startx
```

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
