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
| `cloudflare-tunnel` | cloudflared connector for backup SSH |
| `devbox` | Liquorix kernel + spice-vdagent (QEMU/virt guest) |
| `dev-tools` | Baseline CLI: git, curl, vim, htop, tmux, rsync, less, jq |
| `digikam` | Photo manager |
| `flatpak` | Flatpak + first-boot Flathub remote setup |
| `ftp` | vsftpd FTP server |
| `healthchecksio` | Dead-man's-switch heartbeat to healthchecks.io |
| `incus` | System containers / VMs |
| `k3s` | *(stub)* single-node Kubernetes |
| `kopia` | *(apt-source wired, fingerprint not pinned)* backup |
| `macbook` | Apple T2 hardware: kernel, firmware, t2fanrd |
| `server` | Minimal headless CLI baseline |
| `signal` | *(apt-source wired, fingerprint not pinned)* Signal Desktop |
| `ssh-server` | openssh-server + hardening drop-ins |
| `steam` | *(stub)* Steam client |
| `tailscale` | Tailscale mesh VPN |
| `telegraf` | *(apt-source wired, fingerprint not pinned)* metrics agent |
| `vscode` | *(apt-source wired, fingerprint not pinned)* Microsoft VSCode |
| `wifi` | NetworkManager + iwd + wifi firmware |

Stubs come in two flavors:

* **fingerprint not pinned** — the apt source + key fetcher are wired
  up but the signing-key fingerprint in `apt-keys.conf` is a
  `REPLACE_*` placeholder. Verify and pin the fingerprint, then
  uncomment `Packages=` in `mkosi.conf` to enable.
* **stub** — the install path itself isn't decided yet (AppImage vs
  Flatpak vs vendor installer); see the profile's `mkosi.conf`
  header comment for what to figure out first.

Either way, `profile.manifest` is the permanent handle; the package
list is the work-in-progress piece.

---

## `profile.manifest` format

One-key-per-line, shell-sourceable (but never `source`d — the parser
is a defensive awk script). Keys:

| Key | Type | Purpose |
| --- | --- | --- |
| `description` | string | One-line human-readable summary |
| `uses_secrets` | space-separated | Which `.mkosi-secrets/` files this profile consumes. Names match the feature keys in `scripts/verify-build-secrets.sh`: `ssh tailscale cloudflared sendgrid pagerduty healthchecks`. |

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
