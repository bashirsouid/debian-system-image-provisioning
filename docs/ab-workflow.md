# A/B rootfs notes

This repository can now build a bootable whole-disk image reliably and provision
users on first boot. That gets you to a repeatable base image, but a real dual-root
workflow needs a few more pieces.

## What the current tree already supports

- reproducible mkosi-built root filesystem image
- source-built AwesomeWM for the devbox profile
- first-boot user creation
- optional host UID/GID sync for the login user built on the same machine

## What a real A/B design still needs

1. Separate mutable state from the slot rootfs.
   - keep the rootfs slots mostly immutable
   - put `/home`, `/var`, and any application state on dedicated shared partitions
2. Keep numeric identities stable.
   - the first-boot user provisioning path now supports that for the build host's user
   - for any additional local users, pin `uid` and `gid` explicitly in `.users.json`
3. Add slot-aware update metadata.
   - use `mkosi.sysupdate/` plus `systemd-sysupdate`
   - keep at least two installable versions/slots available
4. Add rollback and health checking.
   - boot the new slot
   - mark it good only after a successful boot/health check
   - otherwise fall back to the previous slot
5. Decide how `/etc` should behave.
   - keep it per-slot and regenerated from image content, or
   - move only selected local overrides into shared state

## Practical next step

Keep testing with `mkosi vm` and spare-disk images first. Once you are happy with
user provisioning and desktop behavior, the next implementation step should be a
`mkosi.sysupdate/` directory that targets two rootfs slots plus the matching boot
artifacts.

## Current bridge step now included

This tree now also includes a conservative host-side bridge for local A/B testing: `scripts/ab-flash.sh`.
It is not the final `systemd-sysupdate`-based solution, but it does let you sync the built image into the inactive root slot on a UEFI + GRUB machine, keep the current slot as the saved fallback, and trial-boot the new slot once before blessing it with `ab-bless-boot`.
