# kopia-cloud-backup

Hourly encrypted cloud backups via Kopia. Ships `kopia-cloud-backup.service`
+ `.timer`; the actual work is done by `/usr/lib/kopia/kopia.backup.s3.bash`
(installed by the `kopia` profile, which this profile requires).

It backs up to every entry in the host's `kopia_cloud_targets` descriptor
list. For each target `<name>`:

- the **endpoint** comes from the descriptor (`<name>:<endpoint>`), and
- the **credentials** come from the age vault as
  `kopia-s3-creds-<name>.json` = `{"accessKeyId","secretAccessKey","bucket"}`.

The repository encryption passphrase is the shared `kopia-password` secret.
See `mkosi.profiles/README.md` (Kopia backup stack) for the full picture.
