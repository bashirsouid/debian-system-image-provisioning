# Hardware-test USB workflow

This repo can now turn a built image into a **bootable hardware-test USB** that
uses the same native retained-version stack as the real install.

That means the USB is **not** a separate installer ISO format. Instead, the USB
is bootstrapped with:

- `systemd-repart` for GPT layout
- `systemd-sysupdate` for the first installed version
- `systemd-boot` for boot management and trial/fallback behavior

## Why this is better than just copying `image.raw`

The USB now exercises the same model as the target machine:

- versioned root artifact
- versioned UKI and boot entry
- retained offline root slot
- boot assessment through `systemd-boot` + `boot-complete.target`

You can optionally embed the full `image.raw` into the USB bundle, but the
normal installer path does not require it.

## Create the USB from the build host

Build first as usual, for example:

```bash
./build.sh --profile macbook --host macbookpro13-2019-t2
```

Then write the test USB:

```bash
sudo ./bin/write-live-test-usb.sh --target /dev/sdX
```

Optional:

```bash
sudo ./bin/write-live-test-usb.sh --target /dev/sdX --embed-full-image
```

What this does:

1. destructively bootstraps the USB with the native retained-version layout
2. seeds the current built version onto the USB
3. copies an installer bundle into `/root/ab-installer`
4. creates `/root/INSTALL-TO-INTERNAL-DISK.sh` on the USB root filesystem

## What is on the USB

The bundle includes:

- the current versioned sysupdate source artifacts from `mkosi.output/`
- the sysupdate transfer definitions from `mkosi.sysupdate/`
- the repart templates from `deploy.repart/`
- helper scripts needed to bootstrap or update another disk from the running USB

## Install to the internal disk from the booted USB

After booting from the USB:

```bash
sudo /root/INSTALL-TO-INTERNAL-DISK.sh
```

The interactive helper lets you either:

- wipe the target and create a fresh retained-version layout
- or stage the bundled version onto an already-bootstrapped target disk

The default fresh layout is:

- `ESP` — 1G
- two retained root partitions — 8G each
- `/home` as a GPT `home` partition using the remaining space
- no `/mnt/data` partition unless you ask for one

If you add a `/mnt/data` partition, label it `DATA`. The image ships an
`/etc/fstab` entry that mounts `PARTLABEL=DATA` to `/mnt/data` with `nofail`,
so future retained versions keep mounting it without per-version edits.

## T2 Mac note

On Intel T2 Macs, use the macOS Startup Manager (hold Option at boot) and pick
the orange `EFI Boot` entry for the USB. If macOS reports that a software update
is required to use the startup disk, disable Secure Boot first.
