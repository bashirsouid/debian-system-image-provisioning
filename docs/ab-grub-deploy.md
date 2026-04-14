# Safe A/B trial deployment with GRUB

This repository now includes `scripts/ab-flash.sh`, which is the first cut of a
host-side deployment tool for a **UEFI + GRUB + two-root-slot** machine.

What it does:

1. figures out which root slot is currently active
2. mounts the built `mkosi.output/image.raw` read-only
3. mounts the inactive root partition on the real machine
4. rsyncs the image rootfs into the inactive slot
5. copies the image's UKI from the image ESP into the shared machine ESP as a
   slot-specific file
6. regenerates GRUB with stable menuentry IDs `ab-slot-a` and `ab-slot-b`
7. sets the current slot as the **saved** fallback
8. sets the newly flashed slot for **the next boot only**

That gives you a safer trial-boot flow:

- current known-good slot stays the persistent default
- next reboot goes to the newly flashed slot once
- if the new slot fails and the machine reboots again, GRUB should return to
  the saved slot on the following boot
- after you verify the new slot is good, run `sudo ab-bless-boot`

## Current assumptions

This is intentionally conservative. It currently assumes:

- UEFI firmware
- GRUB on the host, with a writable GRUB environment block
- Secure Boot disabled
- two plain root partitions, not LVM root slots and not MD RAID root slots
- a shared ESP that GRUB already boots from
- a built and already-QEMU-tested `mkosi.output/image.raw`

## Why Secure Boot is disabled in this flow

The current image path produces a UKI. The GRUB slot entries chainload that UKI
and pass slot-specific `root=UUID=...` arguments at invocation time.

That is a practical fit for local development, but it means this flow is not the
right Secure Boot story yet. The next step for a stronger A/B design would be to
make the slot boot path fully explicit and signed from end to end.

## Example config

Start from:

```bash
cp ab-flash.conf.sample ab-flash.conf
```

Then edit `ab-flash.conf` to point at your real devices.

A reasonable first pass is to use stable symlinks like:

```bash
ESP_PART=/dev/disk/by-partlabel/ESP
SLOT_A_ROOT=/dev/disk/by-partlabel/ROOT_A
SLOT_B_ROOT=/dev/disk/by-partlabel/ROOT_B
```

## Example usage

```bash
sudo ./scripts/ab-flash.sh --config ./ab-flash.conf
```

Then reboot.

If the new slot looks good:

```bash
sudo ab-bless-boot
```

If it does **not** look good, just reboot again. Since the deployment script kept
`grub-set-default` pointed at the old slot and only used `grub-reboot` for the
new slot, the next boot should go back to the previously saved slot.

## Preserved machine-local files

By default the deployment script copies a small set of machine-local paths from
the currently running system into the newly flashed slot:

- `/etc/fstab`
- `/etc/machine-id`
- `/etc/hostname`
- `/etc/ssh/ssh_host_*`

That is there to reduce the amount of accidental machine identity churn between
slot switches. The root entry in the copied `/etc/fstab` is then rewritten to
point at the target slot's UUID.

## What this does **not** solve yet

This is a deployment helper, not the finished whole update system.

It still does **not** provide:

- boot-complete health reporting before automatic bless
- signed slot artifacts for Secure Boot
- shared `/var` layout design
- transactional app/data migrations
- automated remote rollback policies

Those are the next-stage pieces for a fuller A/B system.
