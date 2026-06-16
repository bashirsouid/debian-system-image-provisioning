# kopia-filesystem-backup

Hourly encrypted filesystem backups via Kopia, designed for rotating local /
USB drives. Ships `kopia-filesystem-backup.service` + `.timer`; the work is
done by `/usr/lib/kopia/kopia.backup.filesystem.bash` (installed by the
`kopia` profile, which this profile requires).

It backs up to every entry in the host's `kopia_filesystem_targets`
descriptor list (`<name>:<mountpoint>`). A target whose mountpoint is not
currently mounted is **silently skipped**, so you can rotate spare disks
freely — only attached drives are written. The Kopia repository lives at
`<mountpoint>/backup.kopia`.

All filesystem targets share the `kopia-password` passphrase. See
`mkosi.profiles/README.md` (Kopia backup stack) for the full picture.
