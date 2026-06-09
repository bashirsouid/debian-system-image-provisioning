# Profiles and roles

Each build of this repo is defined by:

1. One **host** (optional; omit for QEMU smoke tests) under `hosts/<name>/`.
2. A **list of profiles** that compose what goes into the image.
3. Optional **roles** that expand to profile lists before mkosi runs.

Composition rules are last-writer-wins: global `mkosi.extra/` →
selected-profile `mkosi.extra/` → host `mkosi.extra/`. So a host can
override anything a profile drops in; a profile can override anything
the base drops in.

---

## Atomic profiles

Each directory under `mkosi.profiles/` is one profile. Minimum layout:

```
mkosi.profiles/<name>/
    mkosi.conf            # [Content] Packages= etc.
    profile.manifest      # metadata this repo consumes (see below)
    mkosi.extra/          # optional: files dropped into the image
```

mkosi activates a profile when `--profile=<name>` is passed. `build.sh`
expands the comma-free, space-separated profile list from
`--profile`/`profile.default` into one `--profile=` flag per name.

Profile directories currently in the tree:

| Profile | Purpose |
| --- | --- |
| `ab-diagnostics` | Stream current-boot journal to `/root/last-boot.log` |
| `antigravity` | *(stub)* Google Antigravity IDE |
| `audio-pipewire` | PipeWire + bluez audio stack |
| `awesomewm` | awesome window manager + xorg (with xorg-legacy) |
| `joystickwake` | Prevents DPMS timeout on controller input |
| `bluetooth` | Bluetooth support with bluez stack |
| `cloudflare-tunnel` | cloudflared connector for backup SSH |
| `devbox` | Liquorix kernel + spice-vdagent (QEMU/virt guest) |
| `dev-tools` | Baseline CLI: git, curl, vim, htop, tmux, rsync, less, jq |
| `digikam` | Photo manager |
| `flatpak` | Flatpak + first-boot Flathub remote setup |
| `ftp` | SFTP-only server with sftponly user (SSH-key auth, no shell) |
| `healthchecksio` | Dead-man's-switch heartbeat to healthchecks.io |
| `incus` | System containers / VMs |
| `k3s` | *(stub)* single-node Kubernetes |
| `kopia` | Kopia backup CLI + `kopia` system user (UID 5000) + `archivereaders` group (see [Kopia backup stack](#kopia-backup-stack) below) |
| `cloud-backup` | Hourly S3 cloud backup service — requires `kopia` profile (see [Kopia backup stack](#kopia-backup-stack)) |
| `home-server-backup` | Hourly local/onsite filesystem backup service — requires `kopia` profile (see [Kopia backup stack](#kopia-backup-stack)) |
| `kernel-6-18` | Linux 6.18.x kernel from trixie-backports |
| `macbook` | Apple T2 hardware: kernel, firmware, t2fanrd |
| `s3-unencrypted-backup` | Hourly upload of configured files to S3-compatible storage (no encryption) |
| `server` | Minimal headless CLI baseline |
| `signal` | *(apt-source wired)* Signal Desktop — uncomment Packages= to enable |
| `ssh-server` | openssh-server + hardening drop-ins |
| `steam` | *(stub)* Steam client |
| `symlink-docker` | Symlink `/var/lib/docker` -> `/mnt/data/docker` for persistent container storage |
| `symlink-k3s` | Symlink K3s + container storage to `/mnt/data/` for persistent K8s state |
| `tailscale` | Tailscale mesh VPN |
| `telegraf` | *(apt-source wired)* InfluxData Telegraf — uncomment Packages= to enable |
| `vscode` | *(apt-source wired)* Microsoft VSCode — uncomment Packages= to enable |
| `wifi` | NetworkManager + iwd + wifi firmware |
| `swap` | Creates a 2 GiB swap file on first boot |

Stubs come in two flavors:

* **apt-source wired** — the apt source + signing-key fingerprint are
  already pinned in `apt-keys.conf`. Uncomment `Packages=` in
  `mkosi.conf` to enable. `update-3rd-party-deps.sh` (or the build
  itself) will fetch + verify the key on next run.
* **stub** — the install path itself isn't decided yet (AppImage vs
  Flatpak vs vendor installer); see the profile's `mkosi.conf`
  header comment for what to figure out first. Their `apt-keys.conf`
  (if present) carries a `REPLACE_*` placeholder fingerprint that
  `fetch-third-party-keys.sh` logs and skips, so the un-decided
  state never breaks `update-3rd-party-deps.sh`.

Either way, `profile.manifest` is the permanent handle; the package
list is the work-in-progress piece.

---

## Kopia backup stack

Three profiles work together to provide encrypted, deduplicated backups
with automatic repository initialization, comprehensive exclude patterns,
and failure alerting.

| Profile | What it provides |
| --- | --- |
| `kopia` | Installs the Kopia CLI binary (third-party apt source), creates the `kopia` system user/group (UID/GID 5000) and the `archivereaders` supplemental group, and drops in `kopia-backup-trigger` — the main backup execution script. |
| `cloud-backup` | Adds `cloud-backup.service` + `cloud-backup.timer` (hourly) for backing up to an S3-compatible endpoint. |
| `home-server-backup` | Adds `home-server-backup.service` + `home-server-backup.timer` (hourly) for backing up to one or more local filesystem destinations (USB drives, SD cards, external disks). |

`cloud-backup` and `home-server-backup` both depend on the `kopia`
profile. Include all three in a host's `profile.default`, or use the
`backup` role which bundles them.

### Dedicated backup user

Backups run as `User=kopia` / `Group=kopia`, never as root. The unit
files grant `AmbientCapabilities=CAP_DAC_READ_SEARCH` so the kopia
process can read all files on the system (including other users' home
directories) without write or administrative privileges. The user is
provisioned via `systemd-sysusers` at image build time through
`/usr/lib/sysusers.d/kopia.conf`.

### Repository auto-initialization

`kopia-backup-trigger` checks repository connectivity on every run.
If Kopia is not connected to the target repository, the script
automatically attempts `kopia repository connect`. If that fails
(first-ever run), it falls back to `kopia repository create`. This
means a freshly provisioned host will self-bootstrap its backup
repositories on the first timer tick — no manual `kopia repository
create` step required.

### Global policies and excludes

On every run, `kopia-backup-trigger` applies a global policy set that
mirrors the Ansible `kopia_backup_excludes` defaults:

* **Compression**: `zstd`
* **Retention**: 90 daily snapshots, no hourly/weekly/monthly/annual
* **Dot-ignore**: `nobackup` (any directory containing a file named
  `nobackup` is skipped)
* **80+ ignore patterns** including:
  * Build artifacts: `node_modules/`, `snap/`, `models/`, `bin/`
  * Caches and history: `*.cache`, `*.bak`, `*.db`, `.bash_history`,
    `.zsh_history`, `.viminfo`, `.python_history`
  * Desktop state: `.local/`, `.config/`, `.var/`, `.gnome/`, `.mozilla/`
  * Credentials: `.ssh/`, `.gnupg/`, `.cloudflared`, `.netrc`, `*.cert`,
    `*.key`
  * Large/irrelevant: `.docker/`, `.rustup/`, `.nvm/`, `anaconda3/`,
    `VirtualBox VMs/`, `SteamLibrary/`, `GOG Games/`

The full list is defined in the `set_global_policies()` function inside
`kopia-backup-trigger`.

### Filesystem destinations (`kopia-backup-destinations.json`)

For `home-server-backup`, the script reads a JSON array from
`/etc/kopia-backup-destinations.json`. Each entry describes one backup
target:

```json
{
  "name": "tgsdc1",
  "description": "Personal onsite backup to Team Group SD card",
  "path": "/mnt/tgsdc1/backup.kopia/",
  "cache": "/var/cache/kopia/tgsdc1",
  "config": "/var/lib/kopia/repository.tgsdc1.config",
  "precondition": "mountpoint -q /mnt/tgsdc1/",
  "additionalExcludes": ["/mnt/data/Pictures/"]
}
```

| Field | Required | Purpose |
| --- | --- | --- |
| `name` | yes | Unique identifier; also used to locate per-destination passwords (`kopia-password-<name>`) |
| `path` | yes | Filesystem path where the Kopia repository lives |
| `precondition` | no | Shell command evaluated before backup. If it exits non-zero, the destination is silently skipped. Useful for removable media: `mountpoint -q /mnt/…` |
| `config` | no | Override for the Kopia config file path (default: `/var/lib/kopia/repository.<name>.config`) |
| `cache` | no | Override for the Kopia cache directory (default: `/var/cache/kopia/<name>`) |
| `additionalExcludes` | no | JSON array of extra ignore patterns added on top of the global excludes (e.g. raw photo formats on a small drive) |

The `home-server-backup` profile ships a default empty `[]` at
`mkosi.profiles/home-server-backup/mkosi.extra/etc/kopia-backup-destinations.json`.
Hosts override this file with their own destinations under
`hosts/<host>/mkosi.extra/etc/kopia-backup-destinations.json`.

### Credentials

Passwords and API keys are packaged into `/etc/credstore/` at build
time by `scripts/package-credentials.sh` and loaded at runtime via
systemd `LoadCredential=`:

| Secret file | Used by | Purpose |
| --- | --- | --- |
| `kopia-cloud-password` | `cloud-backup` | Repository encryption password for the S3 backend |
| `kopia-cloud-s3-creds.json` | `cloud-backup` | S3 endpoint, bucket, access key, secret key (validated at build time) |
| `kopia-password` | `home-server-backup` | Default repository password for all filesystem destinations |
| `kopia-password-<name>` | `home-server-backup` | Per-destination password override (falls back to `kopia-password`) |
| `kopia-cloud-healthcheck-url` | `cloud-backup` | Healthchecks.io ping URL (only staged if `healthchecksio` profile is active) |
| `kopia-home-healthcheck-url` | `home-server-backup` | Healthchecks.io ping URL (only staged if `healthchecksio` profile is active) |

Place secrets in `.mkosi-secrets/` (global) or
`.mkosi-secrets/hosts/<hostname>/` (host-specific, takes precedence).
All Kopia credentials are owned `root:kopia` (0:5000) with mode `0640`.

### Alerting

`kopia-backup-trigger` integrates with the project's `ab-monitor`
alerting stack:

* **On success**: calls `notify.sh --event resolve` to clear any
  prior `kopia_backup_*` failure alert, then pings the Healthchecks.io
  success URL (if configured).
* **On failure**: calls `ad-hoc-alert.sh` to fire a new incident
  through the host's configured `AB_MONITOR_CHANNELS` (Mailjet,
  PagerDuty, journal), then pings the Healthchecks.io `/fail` URL.
* Both systemd units also set `OnFailure=ab-monitor-alert@%n.service`
  as a safety net for crashes that bypass the script's own alerting.

### Systemd hardening

Both `cloud-backup.service` and `home-server-backup.service` run with
a strict security sandbox:

```ini
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
```

`StateDirectory=kopia` and `CacheDirectory=kopia` automatically create
and manage `/var/lib/kopia` and `/var/cache/kopia` with correct
ownership.

### Environment configuration

Each backup unit sources an `EnvironmentFile` from `/etc/default/`:

* `/etc/default/cloud-backup` — sets `KOPIA_BACKUP_TYPE=s3`,
  `KOPIA_CONFIG_PATH`, `KOPIA_CACHE_DIR`, upload/parallelism defaults.
* `/etc/default/home-server-backup` — sets
  `KOPIA_BACKUP_TYPE=filesystem`, 50 GiB upload limit default.

Override these files in `hosts/<host>/mkosi.extra/etc/default/` for
per-host tuning.

### Host configuration example

To enable the full Kopia stack on a host:

1. Add `kopia`, `cloud-backup`, and `home-server-backup` to
   `hosts/<host>/profile.default`.
2. Create `hosts/<host>/mkosi.extra/etc/kopia-backup-destinations.json`
   listing the host's filesystem backup targets.
3. Place the required secrets in `.mkosi-secrets/hosts/<host>/`
   (or globally in `.mkosi-secrets/`).

See `hosts/x1g13/mkosi.extra/etc/kopia-backup-destinations.json` for
a working example with six filesystem destinations including
precondition checks and per-destination additional excludes.

---

## `profile.manifest` format

One-key-per-line, shell-sourceable (but never `source`d — the parser
is a defensive awk script). Keys:

| Key | Type | Purpose |
| --- | --- | --- |
| `description` | string | One-line human-readable summary |
| `uses_secrets` | space-separated | Which `.mkosi-secrets/` files this profile consumes. Names match the feature keys in `scripts/verify-build-secrets.sh`: `ssh tailscale cloudflared mailjet pagerduty healthchecks s3-backup`. |

Example (`mkosi.profiles/tailscale/profile.manifest`):

```
description="Tailscale mesh VPN. Reads tailscale-authkey at first boot."
uses_secrets="tailscale"
```

`scripts/verify-build-secrets.sh` reads the manifests of the selected
profiles and only warns about secrets that at least one of them
declares — secrets you haven't opted into are silently skipped, so
builds on a fresh machine don't scold you about features you never
intended to use.

---

## Third-party apt repos: `apt-keys.conf`

A profile that needs a third-party Debian apt repo declares its
signing keys in `mkosi.profiles/<name>/apt-keys.conf`. Format is
shell-sourceable, one block per key, indexed `KEY_1_*`, `KEY_2_*`,
etc.

```
# mkosi.profiles/tailscale/apt-keys.conf
KEY_1_NAME="tailscale-archive-keyring"
KEY_1_URL="https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg"
KEY_1_FINGERPRINT="2596A99EAAB33821893C0A79458CA832957F5868"
KEY_1_OUT="etc/apt/keyrings/tailscale-archive-keyring.gpg"
```

`scripts/fetch-third-party-keys.sh` walks every `apt-keys.conf` under
`mkosi.profiles/`, fetches each declared URL, verifies the pinned
fingerprint, and dearmors the key into the profile's
`mkosi.extra/etc/apt/keyrings/` so the key only ends up in the image
when its profile is selected. Fingerprint mismatch fails closed —
key rotation requires editing the conf with a freshly verified
fingerprint and committing.

`build.sh` calls the fetch script with `--profile "<resolved list>"`
so a build that doesn't include the tailscale profile won't even
attempt to download Tailscale's signing key.

The matching `<repo>.sources` file lives at
`mkosi.profiles/<name>/mkosi.extra/etc/apt/sources.list.d/<repo>.sources`
with `Signed-By: /etc/apt/keyrings/<key>.gpg` matching `KEY_n_OUT`.

---

## Roles

A role is a named bundle of profiles. Format is plain text, one
profile per line (or whitespace-separated), `#` comments supported.
Files live at `mkosi.roles/<name>.role`.

Example (`mkosi.roles/group_dev.role`):

```
dev-tools
vscode
antigravity
incus
k3s
```

Roles are resolved by `scripts/lib/profile-resolver.sh` into their
atomic profile members before mkosi is invoked. **Nesting is not
supported**: a role file can reference profiles, never other roles.
One level is enough; deeper trees are hard to reason about when a
build goes wrong.

Pre-defined roles:

| Role | Members |
| --- | --- |
| `group_dev` | `dev-tools vscode antigravity incus k3s` |
| `group_photo` | `digikam kopia` |
| `group_game` | `flatpak steam` |
| `symlinks` | `symlink-docker symlink-k3s` |
| `backup` | `kopia cloud-backup home-server-backup` |

You can use role names anywhere a profile name is accepted:
`--profile "macbook awesomewm group_dev wifi ssh-server"` or in
`hosts/<name>/profile.default`.

---

## Host overrides

`hosts/<host>/mkosi.extra/` is applied last by mkosi, so a host's
`etc/fstab` wins over any profile's `etc/fstab`.

`hosts/<host>/mkosi.conf.d/*.conf` can scope settings with a `[Match]
Profiles=<X>` block — that matches when `X` is in the selected
profile list, so a match-block written before profile composition
existed still works.

---

## Adding a new profile

1. `mkdir mkosi.profiles/<new>/`
2. Write `mkosi.profiles/<new>/mkosi.conf` with a `[Content]` +
   `Packages=` section (and any `[Build]` / `[Runtime]` you need).
3. Drop any files to copy in under `mkosi.profiles/<new>/mkosi.extra/`.
4. If your unit files need a preset-all pass, add
   `mkosi.profiles/<new>/mkosi.extra/etc/systemd/system-preset/NN-<new>.preset`.
   Prefix `NN` anywhere between 80 and 99; the base preset is `90-ab.preset`.
5. Write `mkosi.profiles/<new>/profile.manifest` declaring any secrets
   the profile reads at build time via `uses_secrets`.
6. If the profile needs a third-party apt repo, add an
   `apt-keys.conf` (see "Third-party apt repos" above) and a
   `<repo>.sources` file under `mkosi.extra/etc/apt/sources.list.d/`.
7. Add it to `hosts/<host>/profile.default` where wanted, or include
   it in a role under `mkosi.roles/`.

That's it — `./build.sh --host <host>` picks up the new profile
automatically via the resolver.
