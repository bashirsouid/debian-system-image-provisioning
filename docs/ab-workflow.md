# A/B rootfs notes

This repository can now build a bootable whole-disk image reliably, provision
users on first boot, and deploy the built image into the inactive slot on a
UEFI + systemd-boot machine.

That gets you to a useful local A/B workflow, but it is still a bridge step.
A fuller long-term slot update design usually wants more than just "copy new
rootfs into the other partition and flip the boot entry".

## What the current tree already supports

- reproducible mkosi-built root filesystem image
- source-built AwesomeWM for the devbox profile
- first-boot user creation
- optional host UID/GID sync for the login user built on the same machine
- conservative inactive-slot flashing with one-shot systemd-boot trial boots
- slot deployment metadata stored inside the slot and on the shared ESP
- shared slot-health state stored on the shared ESP
- manual or automatic promotion after a successful trial boot
- ARM64 `cloudbox` server builds via `--profile server --host cloudbox`

## What a fuller A/B design still needs

1. Separate mutable state from the slot rootfs.
   - keep the rootfs slots mostly immutable
   - put `/home`, `/var`, and any application state on dedicated shared partitions or subvolumes
2. Keep numeric identities stable.
   - the first-boot user provisioning path now supports that for the build host's user
   - for any additional local users, pin `uid` and `gid` explicitly in `.users.json`
3. Make health policy application-aware.
   - the current health service checks for failed units and optional hook scripts
   - production systems usually add checks that reflect the real workload
4. Decide how `/etc` should behave.
   - keep it per-slot and regenerated from image content, or
   - move only selected local overrides into shared state
5. Decide when promotion should happen.
   - manual bless for workstation-style validation
   - automatic bless after service-level checks for more unattended systems
6. Add a more formal update transport and version model.
   - the natural next step is `mkosi.sysupdate/` plus `systemd-sysupdate`
   - that gives you explicit transfer metadata instead of a custom copy script alone

## Current bridge step now included

This tree includes `scripts/ab-flash.sh`. It is not the final
`systemd-sysupdate`-based solution, but it does let you:

- sync the built image into the inactive root slot
- keep the current slot as the saved fallback
- trial-boot the new slot once
- record health and deployment metadata
- bless the slot only after it proves healthy

## Practical next step

Keep testing with `mkosi vm` and spare-disk images first. Once you are happy with
user provisioning, desktop behavior, and your systemd-boot-based slot flow, the
next implementation step should be a `mkosi.sysupdate/` directory that targets
two rootfs slots plus the matching boot artifacts.
