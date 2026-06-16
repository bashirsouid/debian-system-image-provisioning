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
| `kopia` | Kopia backup CLI + `kopia` system user (UID 5000) + `archivereaders` group + the `/usr/lib/kopia/*.bash` scripts and `/etc/kopia` config (see [Kopia backup stack](#kopia-backup-stack) below) |
| `kopia-cloud-backup` | Hourly encrypted S3 cloud backup service — requires `kopia` profile (see [Kopia backup stack](#kopia-backup-stack)) |
| `kopia-filesystem-backup` | Hourly encrypted filesystem backup service for rotating local/USB drives — requires `kopia` profile (see [Kopia backup stack](#kopia-backup-stack)) |
| `kernel-lts` | Stable Debian kernel (meta-package; amd64/arm64 auto-selected) |
| `kernel-rolling` | Newest kernel from trixie-backports, auto-tracked (amd64/arm64 auto-selected) |
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
with automatic repository initialization, config-driven excludes, bounded
cache, and failure alerting. Everything non-secret is **config**, everything
secret is in the **age vault** — so a machine's backup setup is just its
descriptor plus its vault entries.

| Profile | What it provides |
| --- | --- |
| `kopia` | Installs the Kopia CLI (third-party apt source) plus `jq`, `curl`, `fuse3`; creates the `kopia` system user/group (UID/GID 5000) and the `archivereaders` group; ships the backup scripts under `/usr/lib/kopia/` and the config under `/etc/kopia/`. |
| `kopia-cloud-backup` | Adds `kopia-cloud-backup.service` + `.timer` (hourly), running `/usr/lib/kopia/kopia.backup.s3.bash` over the host's cloud targets. |
| `kopia-filesystem-backup` | Adds `kopia-filesystem-backup.service` + `.timer` (hourly), running `/usr/lib/kopia/kopia.backup.filesystem.bash` over the host's filesystem targets (rotating local/USB drives), skipping any drive that is not currently mounted. |

Both backup profiles depend on `kopia`. Use the `backup` role to bundle all
three.

### Scripts (`/usr/lib/kopia/`, image-managed)

| Script | Role |
| --- | --- |
| `kopia-common.bash` | Sourced library: user assertion, target/secret/excludes/sources loading, connect-or-create, cache caps, policies, alerting, snapshot. |
| `kopia.backup.filesystem.bash` | Snapshot every mounted filesystem target. `ExecStart` of `kopia-filesystem-backup.service`. |
| `kopia.backup.s3.bash` | Snapshot every cloud target. `ExecStart` of `kopia-cloud-backup.service`. |
| `kopia.backup.mount.bash [name]` | Restore helper. No arg → list targets; with a name → mount that repository's **whole snapshot tree** read-only at `/mnt/kopia/<name>` and block until Ctrl-C (then auto-unmount), so you can browse every snapshot to find the exact file. Run as `sudo -u kopia /usr/lib/kopia/kopia.backup.mount.bash <name>`. |

### Dedicated backup user (fails if absent)

Backups run as `User=kopia` / `Group=kopia`, never as root, and the scripts
call `assert_kopia_user` so a missing user fails the run loudly. The units
grant `AmbientCapabilities=CAP_DAC_READ_SEARCH` so the process can read all
source files without write/admin privileges. The user is provisioned via
`systemd-sysusers` at build time through `/usr/lib/sysusers.d/kopia.conf`.

### Targets (config, per host)

Targets are declared in the host descriptor (`hosts.local/<name>.conf`) and
rendered by `scripts/lib/host-descriptor.sh` into `/etc/kopia/targets.json`:

```
kopia_filesystem_targets = tgsd1:/mnt/tgsd1 usb2:/mnt/usb2
kopia_cloud_targets      = wasabi:https://s3.us-west-1.wasabisys.com
```

* **Filesystem** entry is `name:mountpoint`. The repository lives at
  `<mountpoint>/backup.kopia`. Before each run the mountpoint is checked
  (`mountpoint -q`); an unmounted drive is **silently skipped**, so rotating
  spare disks just works.
* **Cloud** entry is `name:endpoint` (endpoint split on the first colon, so
  `https://…` survives). The endpoint is non-secret; the bucket and keys are
  in the vault (see below).

The `kopia` profile ships a default empty `/etc/kopia/targets.json`
(`{"filesystem":[],"cloud":[]}`); the descriptor render overrides it.

### Sources and excludes (config)

* **Sources** — what gets snapshotted, from `/etc/kopia/sources.conf` (one
  path per line; default `/home`). Override per host with `kopia_sources`.
* **Excludes** — `/etc/kopia/excludes.conf` ships the default ignore list
  (build artifacts, caches/history, desktop state, credentials, large dirs;
  ~68 patterns). Add per-host patterns with `kopia_extra_excludes`, rendered
  to `/etc/kopia/excludes.local.conf` and merged on top. Any directory
  containing a file named `nobackup` is also skipped (`--add-dot-ignore`).
* **Policies** — `zstd` compression and 90 daily snapshots (no
  hourly/weekly/monthly/annual), applied on every run.

### Bounded cache

To stop a large restore/verify from filling the disk, every connect applies
`kopia cache set --content-cache-size-mb=1000 --metadata-cache-size-mb=500`
(per repository). Override via `KOPIA_CONTENT_CACHE_MB` /
`KOPIA_METADATA_CACHE_MB` in the unit's `/etc/default/` file.

### Repository auto-initialization

On every run the scripts check repository connectivity. If not connected
they try `kopia repository connect`; on first-ever use that fails and they
fall back to `kopia repository create`. A freshly provisioned host therefore
self-bootstraps its repositories on the first timer tick.

For **filesystem** targets a hidden `.initialized` marker is written into the
repository directory the first time our infra creates (or adopts) it. The
marker is the single source of truth that the repo is ours, and it guards the
create step: if the marker is present but the repo cannot be opened (wrong
passphrase, I/O error), the run **fails** rather than laying a new empty repo
over a drive that already holds backups. The filesystem repository always
lives at `<mountpoint>/backup.kopia` — i.e. at the root of the drive — and the
mountpoint is verified with `mountpoint -q` before each run.

Timers run **hourly with no catch-up** (`Persistent=false`): a run missed
while the machine was off or the drive detached is simply skipped, since the
next tick is at most an hour away.

### Credentials (age vault → `/etc/credstore`)

`scripts/package-credentials.sh` stages these from the vault at build time as
`root:kopia 0640`. The scripts read them **directly** from `/etc/credstore`
(the `kopia` user is in group `kopia`, so they are readable even under
`ProtectSystem=strict`); per-file `LoadCredential=` is not used because the
set of cloud targets is dynamic.

| Secret | Used by | Purpose |
| --- | --- | --- |
| `kopia-password` | both | Shared repository passphrase for **all** targets. Required — a missing/empty passphrase fails the run. |
| `kopia-password-<name>` | both | Optional per-target passphrase override. |
| `kopia-s3-creds-<name>.json` | cloud | `{accessKeyId, secretAccessKey, bucket}` for cloud target `<name>` (validated at build time). |
| `kopia-cloud-healthcheck-url` | cloud | Healthchecks.io ping URL (only if `healthchecksio` profile active). |
| `kopia-filesystem-healthcheck-url` | filesystem | Healthchecks.io ping URL (only if `healthchecksio` profile active). |

Place secrets at the vault top level (global) or under
`hosts.<hostname>` (host-specific, takes precedence). Edit with
`bin/mkosi-vault-edit.sh`.

### Alerting

The scripts integrate with the project's `ab-monitor` stack: on success they
clear any prior `kopia_backup_*` alert and ping the Healthchecks.io success
URL; on failure they fire `ad-hoc-alert.sh` and ping the `/fail` URL. Both
units also set `OnFailure=ab-monitor-alert@%n.service` as a safety net.

### Systemd hardening

Both services run `Type=oneshot` under a strict sandbox (`ProtectSystem=strict`,
`ProtectHome=read-only`, `PrivateTmp/Devices=yes`, `NoNewPrivileges=yes`, kernel
and cgroup protections, `RestrictSUIDSGID/Realtime`, `LockPersonality`).
`StateDirectory=kopia` / `CacheDirectory=kopia` manage `/var/lib/kopia` and
`/var/cache/kopia`; the filesystem unit adds `ReadWritePaths=/mnt` so it can
write repositories on mounted drives.

### Enabling the stack on a host

1. Add `kopia kopia-cloud-backup kopia-filesystem-backup` (or the `backup`
   role) to the host descriptor's `profiles =`.
2. Declare `kopia_filesystem_targets` / `kopia_cloud_targets` (and optionally
   `kopia_sources` / `kopia_extra_excludes`) in the same descriptor.
3. Add `kopia-password` and a `kopia-s3-creds-<name>.json` per cloud target to
   the vault (`bin/mkosi-vault-edit.sh`).

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
| `backup` | `kopia kopia-cloud-backup kopia-filesystem-backup` |

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
