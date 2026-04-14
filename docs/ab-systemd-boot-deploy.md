# Safe A/B trial deployment with systemd-boot

This repository now recommends `scripts/ab-flash.sh` for a **UEFI + systemd-boot
+ two-root-slot** machine.

## What it does

1. detects which root slot is currently active
2. mounts `mkosi.output/image.raw` read-only
3. mounts the inactive root partition on the real machine
4. `rsync`s the image rootfs into that inactive slot
5. copies the current-slot UKI and newly built slot UKI into the shared ESP as
   slot-specific files
6. installs or updates systemd-boot on the shared ESP
7. writes Boot Loader Specification entries for slot A and slot B
8. keeps the current slot as the **persistent** fallback
9. sets the newly flashed slot for **the next boot only**
10. writes per-slot deployment metadata and a shared A/B status file onto the ESP

That gives you a conservative trial-boot flow:

- the current known-good slot stays the persistent default
- the next reboot goes to the newly flashed slot once
- if the new slot fails and the machine reboots again, systemd-boot returns to the
  saved slot on the following boot
- after a successful trial boot, either `ab-bless-boot` promotes the slot
  manually or the slot promotes itself automatically if `AB_AUTO_BLESS=yes`

## Current assumptions

This flow is intentionally conservative. It assumes:

- UEFI firmware
- systemd-boot on the host (the script can install/update it on the ESP)
- Secure Boot disabled for this current flow
- two plain root partitions, not LVM root slots and not MD RAID root slots
- a shared ESP that the host can boot from
- a built and already-QEMU-tested `mkosi.output/image.raw`
- the currently running slot has a UKI available under `/boot/EFI/Linux`,
  `/efi/EFI/Linux`, or `/boot/efi/EFI/Linux` so it can be preserved as the
  fallback slot during the first migration away from GRUB

## Why Secure Boot is disabled in this flow

The current slot entries use Boot Loader Specification entries with a `uki`
reference plus an `options` line to inject slot-specific `root=UUID=...` and
any host-specific extra kernel flags. That is practical for local development,
but it is not the final Secure Boot story yet.

## Config file

Start from:

```bash
cp ab-flash.conf.sample ab-flash.conf
```

Then edit `ab-flash.conf` to point at your real devices.

A reasonable first pass is to use stable symlinks such as:

```bash
ESP_PART=/dev/disk/by-partlabel/ESP
SLOT_A_ROOT=/dev/disk/by-partlabel/ROOT_A
SLOT_B_ROOT=/dev/disk/by-partlabel/ROOT_B
```

## Custom kernel flags

The deploy script writes one Boot Loader Specification entry per slot and uses
its `options` line to set both `root=UUID=...` and any extra host-specific flags.

Example:

```bash
EXTRA_KERNEL_ARGS="quiet amdgpu.gttsize=3072"
```

For an OCI ARM host, the serial console is often useful:

```bash
EXTRA_KERNEL_ARGS="quiet console=ttyAMA0,115200 console=tty1"
```

## Deployment metadata and health state

The deploy script writes two kinds of metadata:

### 1. Per-slot metadata

Each flashed slot receives:

- `/usr/local/share/ab-image-meta/build-info.env`
- `/usr/local/share/ab-image-meta/deploy-info.env`
- `/etc/ab-slot.conf`

The shared ESP also gets `slot-a.env` and `slot-b.env` under
`AB_STATE_ESP_DIR` (default: `/EFI/Linux/ab-state`).

### 2. Shared trial / health state

The shared ESP also keeps a `status.env` file that records:

- the saved slot and saved entry id
- the currently pending trial slot and entry id
- the pending image sha256 and deploy time
- the last healthy boot
- the last unhealthy boot and its reason
- the last fallback event
- the last promotion event
- whether the current successful trial still needs a manual bless

Use `sudo ab-status` to inspect the current slot plus this shared state.

## Health checks

Flashed slots enable `ab-slot-health.service` automatically.

That service:

- waits `AB_HEALTH_DELAY_SECS` after boot
- fails the slot if there are failed systemd units
- optionally runs extra executable hook scripts from `AB_HEALTH_HOOK_DIR`
- records the result in the shared `status.env`
- auto-promotes the slot only if `AB_AUTO_BLESS=yes`
- can optionally force a reboot on failure with `AB_REBOOT_ON_HEALTH_FAILURE=yes`

The default workstation path is conservative:

```bash
AB_AUTO_BLESS=no
AB_REBOOT_ON_HEALTH_FAILURE=no
```

For unattended servers, a more typical setting is:

```bash
AB_AUTO_BLESS=yes
AB_REBOOT_ON_HEALTH_FAILURE=yes
```

## Typical workflow

From the currently-good slot:

```bash
sudo ./scripts/ab-flash.sh --config ./ab-flash.conf
sudo reboot
```

After the trial slot boots:

```bash
sudo ab-status
```

If auto bless is disabled, commit the slot manually after verification:

```bash
sudo ab-bless-boot
```

If health fails and `AB_REBOOT_ON_HEALTH_FAILURE=yes`, the slot records the
failure and reboots so the saved fallback slot becomes active on the following
boot.
