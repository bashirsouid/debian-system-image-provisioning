# kopia-cloud-backup

Hourly encrypted cloud backups via Kopia. Ships `kopia-cloud-backup.service`
+ `.timer`; the actual work is done by `/usr/lib/kopia/kopia.backup.s3.bash`
(installed by the `kopia-base` profile, which this profile pulls in
automatically via `requires=kopia-base` — you don't need to select it yourself).

It backs up to every entry in the host's `kopia_cloud_targets` descriptor
list. For each target `<name>`:

- the **endpoint** comes from the descriptor (`<name>:<endpoint>`), and
- the **credentials** come from the age vault as
  `kopia-s3-creds-<name>.json` = `{"accessKeyId","secretAccessKey","bucket"}`.

The repository encryption passphrase is the shared `kopia-password` secret.

To trigger a run by hand: `sudo systemctl start kopia-cloud-backup.service`.
To browse/restore: `sudo -u kopia /usr/lib/kopia/kopia.backup.mount.bash <name>`.
The dedicated `kopia` system user, the credential model, and full run/restore
instructions are documented in
[`mkosi.profiles/kopia-base/README.md`](../kopia-base/README.md). See also
`mkosi.profiles/README.md` (Kopia backup stack).
