# Native retained-version deployment with systemd-boot

The repository no longer treats `scripts/ab-flash.sh` as the preferred updater.

The recommended path is now:

1. `systemd-repart` for the initial disk layout
2. `systemd-sysupdate` for installing new root/boot artifacts
3. `systemd-boot` boot counting for rollback
4. `boot-complete.target` + `systemd-bless-boot` for marking the new version good

## The first install

Use `scripts/bootstrap-ab-disk.sh` against a blank or offline target disk or raw image.
That script:

- destroys the target partition table
- creates an ESP and two empty root partitions
- installs `systemd-boot`
- seeds the first retained version from `mkosi.output/` using `systemd-sysupdate`

## Later updates

Use `scripts/sysupdate-local-update.sh` on an already bootstrapped machine.
That stages a new retained version with `systemd-sysupdate`. The next boot becomes a trial boot.

## Why this is preferred

This path keeps versioning, boot attempts, and rollback inside the native systemd stack instead of
maintaining a separate custom slot-state model on the ESP.
