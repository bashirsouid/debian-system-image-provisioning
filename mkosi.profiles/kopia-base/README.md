# kopia-base

Shared foundation of the Kopia backup stack. **You don't select this profile
directly** — `kopia-cloud-backup` and `kopia-filesystem-backup` declare
`requires=kopia-base` in their manifests, so the resolver pulls it in
automatically. Just put a backup profile (or the `backup` role) in your host
descriptor and the base comes along. It provides:

- the **`kopia` CLI** (+ `jq`, `curl`, `fuse3`) and its apt source/signing key;
- the **`kopia` system user** (see below);
- the backup/restore **helper scripts** in `/usr/lib/kopia/`;
- the non-secret config in `/etc/kopia/` (`targets.json`, `sources.conf`,
  `excludes.conf`), rendered from the host descriptor;
- runtime dirs (`/var/lib/kopia`, `/var/cache/kopia`, `/mnt/kopia`).

The `kopia-cloud-backup` / `kopia-filesystem-backup` profiles only add their
systemd `.service`/`.timer` units on top of this.

## The `kopia` user (dedicated system service account)

Backups run as a dedicated, locked-down **system account `kopia` (UID/GID
5000)**, not as your login user. It is created automatically at first boot by
**systemd-sysusers** from `usr/lib/sysusers.d/kopia.conf` — it is **not** a
human user and is **not** listed in the age vault's `users.json`. Its shell is
`/usr/sbin/nologin`; the only secret tied to it is the repository passphrase
(below), which lives in the vault.

Your login user has no direct access to the repositories, the credential
store, or mounted backups. To do anything by hand you step into the kopia
account with `sudo` — e.g. `sudo -u kopia …` or `sudo systemctl start …`. This
isolation is deliberate: a compromise of your desktop session doesn't hand over
the backup repos or their passphrase.

## Credentials (`/etc/credstore`)

Secrets are staged at build time by `scripts/package-credentials.sh` into
`/etc/credstore`, owned `root:kopia` mode `0640`. The `kopia` user reads them
via its group membership — no `LoadCredential=` is used (see the note in
`kopia-filesystem-backup.service` for why adding it breaks credential
resolution). The relevant files:

| credstore file | required? | vault key to set |
|---|---|---|
| `kopia-password` | **yes** | `kopia-password` (a long random passphrase, shared by all repos) |
| `kopia-s3-creds-<name>.json` | cloud only | `kopia-s3-creds-<name>.json` = `{"accessKeyId","secretAccessKey","bucket"}` |
| `kopia-cloud-healthcheck-url` / `kopia-filesystem-healthcheck-url` | optional | only with the `healthchecksio` profile |

Set them with `bin/mkosi-vault-edit.sh` (under `hosts.<host>` or global) and
rebuild. Without `kopia-password` the scripts refuse to run.

## How automated backups run

The timers (`kopia-filesystem-backup.timer`, `kopia-cloud-backup.timer`) fire
the matching `*.service` as `User=kopia`. Targets come from the host
descriptor:

- `kopia_filesystem_targets = name:/mountpoint …` → local/USB drives; a target
  whose drive isn't mounted is silently skipped. Repo lives at
  `<mount>/backup.kopia`.
- `kopia_cloud_targets = name:https://endpoint …` → S3-compatible buckets.
- `kopia_sources = …` (default `/home`), `kopia_extra_excludes = …`.

## Triggering a backup by hand

Run the unit (gives you the exact env, credentials, and hardening the timer
uses):

```bash
sudo systemctl start kopia-filesystem-backup.service      # or kopia-cloud-backup.service
journalctl -u kopia-filesystem-backup.service -f          # watch progress
```

Equivalent direct invocation (also as the kopia user):

```bash
sudo -u kopia /usr/lib/kopia/kopia.backup.filesystem.bash
```

## Restoring / browsing a backup

Use the mount helper **as the kopia user** — it reads `kopia-password` from
`/etc/credstore` automatically (no manual credential step):

```bash
# List configured targets (and whether each filesystem drive is attached):
sudo -u kopia /usr/lib/kopia/kopia.backup.mount.bash

# Mount ALL snapshots of one target read-only at /mnt/kopia/<name> and block:
sudo -u kopia /usr/lib/kopia/kopia.backup.mount.bash tgsdc1
```

The mount is read-only and browseable only by the kopia user (`/mnt/kopia/<name>`
is `0700 kopia`). In another terminal, copy files out as root (root bypasses the
mode):

```bash
sudo cp -a /mnt/kopia/tgsdc1/<snapshot-path>/wanted/file /home/you/restore/
```

Press **Ctrl-C** in the mount terminal to unmount and exit (cleanup is
automatic). For a filesystem target the drive must be mounted first; for a cloud
target it also reads `kopia-s3-creds-<name>.json`.

## Reading other users' home directories

The backup **services** carry `AmbientCapabilities=CAP_DAC_READ_SEARCH`, which
lets the kopia process read every source file regardless of its mode. That is
why backups capture all users' `/home` even though home directories are `0700`
(owner-only). This is deliberately the *only* mechanism: a group- or ACL-based
"archive readers" approach can't reliably reach files a user creates later with
a restrictive umask (new files wouldn't carry the group/ACL), whereas
`CAP_DAC_READ_SEARCH` always can. The capability is scoped to these two oneshot
units only — it is not granted to the kopia login shell, so an interactive
`sudo -u kopia` session cannot read other users' homes.

> An earlier design declared an `archivereaders` group for this; it was never
> wired up (nothing made homes group-readable) and is redundant with the
> capability, so it has been removed. The interactive mount/restore path doesn't
> need home access at all — it reads the backup repository, not `/home`.

No secret values are required by this profile itself beyond `kopia-password`
(see the table above).
