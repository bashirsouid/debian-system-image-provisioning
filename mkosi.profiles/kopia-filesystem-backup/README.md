# kopia-filesystem-backup

Hourly encrypted filesystem backups via Kopia, designed for rotating local /
USB drives. Ships `kopia-filesystem-backup.service` + `.timer`; the work is
done by `/usr/lib/kopia/kopia.backup.filesystem.bash` (installed by the
`kopia-base` profile, which this profile pulls in automatically via
`requires=kopia-base` — you don't need to select it yourself).

It backs up to every entry in the host's `kopia_filesystem_targets`
descriptor list (`<name>:<mountpoint>`). A target whose mountpoint is not
currently mounted is **silently skipped**, so you can rotate spare disks
freely — only attached drives are written. The Kopia repository lives at
`<mountpoint>/backup.kopia`.

All filesystem targets share the `kopia-password` passphrase.

To trigger a run by hand: `sudo systemctl start kopia-filesystem-backup.service`.
To browse/restore: `sudo -u kopia /usr/lib/kopia/kopia.backup.mount.bash <name>`.
The dedicated `kopia` system user, the credential model, and full
run/restore instructions are documented in
[`mkosi.profiles/kopia-base/README.md`](../kopia-base/README.md). See also
`mkosi.profiles/README.md` (Kopia backup stack).
