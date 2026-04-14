# mkosi image provisioning

This tree builds Debian OS images with mkosi so you can rebuild the base system
regularly instead of converging long-lived machines forever with Ansible.

Current goals:
- reproducible base images
- source-built AwesomeWM for the `devbox` profile
- first-boot local user provisioning that works in rootless mkosi builds
- Liquorix kernel for the desktop/devbox path on x86-64
- conservative UEFI + systemd-boot A/B deployment for local testing
- an ARM64 server path for a `cloudbox` host
- an Ansible playbook that can build and deploy the ARM server path on the target host

## Why the current shape looks like this

A few decisions here are deliberate because they were the least fragile path:

- regular users are created on **first boot**, not during `mkosi.finalize`
  - that avoids rootless-build ownership problems when mkosi runs inside a user namespace
- `run.sh` uses plain `mkosi vm`
  - that keeps VM startup on the mkosi-supported path instead of depending on version-sensitive raw QEMU argument forwarding
- the `devbox` profile still builds AwesomeWM from source
  - Debian's packaged AwesomeWM is too stale for the intended workflow here
- the `devbox` profile uses Liquorix again
  - but only through mkosi's package-manager sandbox path, not by copying ad hoc apt config into the image late in the build
- QEMU testing seeds a tiny sample home config at runtime
  - so you get a quick smoke test without baking machine-specific personal config into flashed images
- host-side A/B flashing is treated as a **bridge step**, not the final updater design
  - it is useful for local testing now, while the longer-term slot-aware update path should move toward `systemd-sysupdate`
- the recommended bootloader for the A/B flow is now **systemd-boot**, not GRUB
  - the images already build with `Bootloader=systemd-boot`, and `bootctl` makes one-shot vs persistent slot selection much simpler than the old GRUB-specific path
- the ARM `cloudbox` path is intentionally **server-only**
  - no desktop environment, no AwesomeWM, no Liquorix; it stays on Debian's stock `linux-image-arm64`
- the included Ansible path builds **natively on the ARM target**
  - that avoids cross-architecture build surprises when testing on an OCI Ampere box

## Quick start

### Desktop/devbox smoke test in QEMU

```bash
./update-3rd-party-deps.sh
cp .users.json.sample .users.json
# edit .users.json and set a real password for your login user
./clean.sh --all
./build.sh --profile devbox
./run.sh --profile devbox
```

On the first boot, the image provisions users from the embedded data and then
removes that embedded user file from the root filesystem.

For the devbox profile, start X manually after login:

```bash
startx
```

If you want a different X resolution, set `STARTX_RESOLUTION` before launching X:

```bash
STARTX_RESOLUTION=1920x1080 startx
```

### ARM64 cloudbox server build

Use the dedicated host overlay:

```bash
cp .users.json.sample .users.json
# edit .users.json
./clean.sh --all
./build.sh --profile server --host cloudbox
```

That overlay:
- forces `Architecture=arm64`
- uses Debian's `linux-image-arm64`
- stays server-only

## QEMU sample home seed

For normal `./run.sh` use, the default path is intentionally simple: `run.sh`
mounts `runtime-seeds/qemu-home/` into the guest and first boot copies that
sample data into the login user's home only when the target paths do not already
exist.

Current sample seed:
- `~/.config/awesome/rc.lua`
- `~/.config/picom/picom.conf`

Because `run.sh` defaults to an **ephemeral** VM snapshot, those sample-home
changes are discarded when the VM exits unless you opt into `--persistent`.

## Liquorix notes

The `devbox` profile uses Liquorix on `x86-64`.

The `server` profile keeps Debian's stock kernel path. The ARM64 `cloudbox`
overlay uses `linux-image-arm64`.

For the `devbox` profile we also keep `dpkg` and `kmod` in the image and disable
mkosi package-metadata cleanup. That avoids a Debian/apt cleanup edge case where
purging `dpkg` causes `kmod` auto-removal to fail because `kmod` maintainer
scripts call `dpkg-maintscript-helper`.

## User IDs for shared mutable state

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
   persistent partition or subvolume.
2. For QEMU compatibility testing on the build host, use runtime sharing rather
   than baking the host's live `/home` into the image design.

This tree supports host-specific overlays through `--host NAME`, so you can
build a machine-specific image that mounts external `/home` only on that machine:

```bash
./build.sh --profile devbox --host evox2
```

For temporary VM testing against your real host config, `run.sh` also exposes
mkosi's native runtime mount features:

```bash
./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"
./run.sh --runtime-home
```

Use `--runtime-tree` when you want to compare against specific host config.
Use `--runtime-home` only for disposable compatibility testing.

See `docs/home-storage.md` for the trade-offs.

## Host-side A/B flashing

For an actual UEFI workstation or server with two root partitions, this tree now
recommends `scripts/ab-flash.sh` plus `ab-flash.conf.sample` in **systemd-boot**
mode.

That script:
- mounts the built `image.raw`
- syncs it into the **inactive** root slot
- copies the current slot's UKI and the image UKI into the shared ESP
- installs or updates systemd-boot on the shared ESP
- writes Boot Loader Specification entries for slot A and slot B
- keeps the current slot as the saved fallback
- schedules the newly flashed slot for the **next boot only**
- writes shared deployment metadata and slot-health state into the ESP

### Assumptions and constraints for the A/B flow

These are not hidden assumptions; they are part of the design:

- UEFI firmware only
- systemd-boot on the real host, or willingness to let `bootctl install` switch the host to systemd-boot
- on the first migration away from GRUB, you may need to verify that firmware boot order now points at systemd-boot if your firmware ignores the new NVRAM entry
- two plain root partitions as slots
- no LVM root slots and no MD RAID root slots in this first cut
- a shared ESP that the machine firmware can boot from
- Secure Boot disabled for this current flow
- the image should already have been tested in QEMU before you flash a real slot
- for the **first migration away from GRUB**, the currently running slot must already have a UKI available under `/boot/EFI/Linux`, `/efi/EFI/Linux`, or `/boot/efi/EFI/Linux` so the script can preserve it as the fallback slot

### Why Secure Boot is out of scope in the current A/B script

The current slot entries use Boot Loader Specification entries with a `uki`
reference plus an `options` line to inject slot-specific `root=UUID=...` and
host-specific extra kernel flags. That is practical for local development, but
it is not the final signed Secure Boot story.

### Custom kernel flags

The systemd-boot path still supports host-specific kernel arguments. Put them in
`EXTRA_KERNEL_ARGS` inside `ab-flash.conf`.

For a Ryzen AI Max desktop example:

```bash
EXTRA_KERNEL_ARGS="quiet amdgpu.gttsize=3072"
```

For an OCI ARM serial-console friendly server example:

```bash
EXTRA_KERNEL_ARGS="quiet console=ttyAMA0,115200 console=tty1"
```

### Slot health reporting and promotion model

This repo implements a shared-state model on the ESP under
`/EFI/Linux/ab-state` by default.

It records:
- which slot is the saved default
- which slot is pending as the current trial boot
- the image sha256 and deploy time for the pending slot
- the last healthy boot
- the last unhealthy boot and reason
- the last observed fallback
- the last promotion event
- whether a slot still needs a manual `ab-bless-boot`

Each flashed slot also gets deployment metadata inside the root filesystem and as
`slot-a.env` / `slot-b.env` files on the shared ESP.

The flashed system enables `ab-slot-health.service`, which:
- waits a configurable grace period after boot
- fails the slot if there are failed systemd units
- optionally runs extra executable hook scripts from `AB_HEALTH_HOOK_DIR`
- records the result into the shared ESP state
- optionally auto-promotes the new slot if `AB_AUTO_BLESS=yes`
- can optionally reboot on failure so the saved fallback slot becomes active on the following boot

A conservative desktop setting is:

```bash
AB_AUTO_BLESS=no
AB_REBOOT_ON_HEALTH_FAILURE=no
```

A more unattended server-style setting is:

```bash
AB_AUTO_BLESS=yes
AB_REBOOT_ON_HEALTH_FAILURE=yes
```

### Typical deploy flow

```bash
cp ab-flash.conf.sample ab-flash.conf
# edit devices and policy
sudo ./scripts/ab-flash.sh --config ./ab-flash.conf
sudo reboot
```

After the new slot boots:

```bash
sudo ab-status
sudo ab-bless-boot   # only needed when AB_AUTO_BLESS=no
```

See `docs/ab-systemd-boot-deploy.md` for the detailed workflow.

## Ansible cloudbox deploy path

There is now an Ansible playbook for the ARM64 server path under `ansible/`.
It is intentionally opinionated:

- it targets a machine called `cloudbox`
- it expects an ARM64 Debian-style host
- it builds the image **on the target host itself** with `--profile server --host cloudbox`
- it deploys the inactive slot with `scripts/ab-flash.sh`
- it reboots and then checks `ab-status`
- it can optionally bless the new slot automatically after the post-reboot health check

Start with:

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
cp ansible/group_vars/cloudbox.yml.example ansible/group_vars/cloudbox.yml
# edit inventory + variables
ansible-playbook -i ansible/inventory.ini ansible/playbooks/cloudbox-ab-deploy.yml
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

Get the image booting first in QEMU and on a spare disk. Then move the longer-term
A/B rollout layer toward `systemd-sysupdate` / `mkosi sysupdate` with explicit
transfer files.

See `docs/ab-workflow.md` for the longer-term direction.
