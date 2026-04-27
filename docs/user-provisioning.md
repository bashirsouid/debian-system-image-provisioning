# User provisioning

How local login users are defined, hashed, and applied on first boot.

## The pipeline

```
.users.json  ──┐                                   build.sh
(or            │   render_users_conf()             ─────────►
hosts/<n>/   │   (hashes plaintext passwords,                                    image
 users.json)   │    resolves host UID sync)                                      build
               ▼
           /usr/local/etc/users.conf        (mode 0600, one line per user,
           inside the image                  colon-separated fields)
                │
                │                                   first boot
                ▼
           provision-local-users.service    ────────────────►
                │   (oneshot, runs before                     running
                │    multi-user.target,                       system
                │    removes users.conf after                 with accounts
                │    applying)                                created
                ▼
           /etc/passwd, /etc/shadow, /etc/group
```

The implementation:

- `build.sh` `render_users_conf()` — reads `.users.json`, produces
  `/usr/local/etc/users.conf` inside the image
- `mkosi.extra/usr/lib/systemd/system/provision-local-users.service` —
  the systemd unit
- `mkosi.extra/usr/local/libexec/provision-local-users` — the first-boot
  script that consumes `users.conf` and calls `useradd` / `usermod`

## Shape of `.users.json`

```json
[
  {
    "username": "demo",
    "comment": "Primary login user",
    "can_login": true,
    "uid": 1000,
    "gid": 1000,
    "primary_group": "demo",
    "groups": ["sudo", "audio", "video", "render", "input", "plugdev", "dialout"],
    "shell": "/bin/bash",
    "password": "change-me-now"
  }
]
```

Any top-level object without a `username` field is silently skipped
(used by the sample file's `_notes` entry to self-document the schema).

## Supported fields

| Field | Required | Default | Notes |
| --- | --- | --- | --- |
| `username` | yes | — | Cannot be `root`. `root` is always locked. |
| `can_login` | no | `true` | `false` => no home dir, shell defaults to nologin, account is locked. |
| `uid`, `gid` | no | auto | May be the literal string `"host"` to copy the build host's value. Useful for the user whose host files get mounted via `RuntimeHome`. |
| `primary_group` | no | same as `username` | May also be `"host"`. |
| `groups` | no | `[]` | Supplementary groups, array of names. Missing groups are created. |
| `shell` | no | `/bin/bash` (login) or nologin (service) | Falls back to `/bin/sh` at first boot if the requested shell isn't installed. |
| `home` | no | `/home/<username>` (login) or `/nonexistent` (service) | |
| `password` | no | — | Plaintext. `build.sh` hashes it at build time via `hash_password()`. |
| `password_hash` | no | — | Pre-hashed crypt string. Wins over `password` when both are set. |
| `ssh_authorized_keys_file` | no | — | Path (relative to repo root) whose contents go into `~/.ssh/authorized_keys` on first boot. |
| `dotfiles_repo` | no | — | Git URL or path (relative to repo root, or absolute) of a dotfiles repo. Cloned with submodules at build time and copied into `~/.dotfiles` on first boot. See **Dotfiles bootstrap** below. |
| `dotfiles_install` | no | `./install` | Shell command run from inside `~/.dotfiles` on first boot. Override when your repo's bootstrap script is named differently or needs flags. |
| `force_password_change_on_first_login` | no | `false` | Currently informational; enforcement is not yet wired into the first-boot script. |

A `password_hash` of `"!"` or `"*"` is a lock marker in `/etc/shadow`,
not a real hash. Setting it disables password login (pubkey still
works). That is the right thing for service accounts; it is *not* what
you want for your primary login user. This was the pre-overlay sample's
default and caused "I can't log in" confusion — that's why the current
sample ships a usable plaintext default instead.

## Generating `password_hash` without touching disk

```bash
./bin/hash-password.sh
# or, with a ready-to-paste JSON entry:
./bin/hash-password.sh --json --username demo --uid 1000
```

The script:

- prompts twice (no echo)
- requires at least 12 characters
- uses `mkpasswd` from the `whois` package
- prefers yescrypt; falls back to sha512crypt if the host's `mkpasswd`
  doesn't support yescrypt
- prints the hash (or the JSON entry) to stdout; prompts and hints go
  to stderr, so `--json > entry.json` works cleanly

## Per-host users

If `hosts/<HOST>/users.json` exists, `./build.sh --host HOST` uses it
instead of the global `.users.json`. The per-host file has the same
shape. Common patterns:

- same login user on every machine, different passwords per host
  (copy-paste the user entry into each host file with a different
  `password_hash`)
- a server host with only service accounts and no login user
- a workstation with several extra dev accounts that never ship on the
  server

There is no merge semantics — per-host entirely replaces global for
that target. If you want to share most of the global list, copy-paste.

## Host UID / GID sync

By default, any `.users.json` entry whose `username` matches the build
host user inherits that user's numeric uid/gid/primary group. This is
the safe default for retained-root updates where `/home` persists
across versions — files in `/home` keep their owner even though the
root image is replaced.

You can:

- opt out entirely: `./build.sh --sync-host-ids=no`
- override per user: set `uid`, `gid`, `primary_group` explicitly in
  the JSON entry
- request it per field: set any of those three to the literal string
  `"host"`

## What the first-boot service actually does

`provision-local-users.service` is a `Type=oneshot` unit that runs
before `multi-user.target`. The script:

1. Locks the root account and sets its shell to nologin. (Only the
   locally-provisioned users should be able to log in; root password
   auth stays off regardless of what `.users.json` says.)
2. If `/usr/local/etc/users.conf` is empty or missing, logs a message
   and exits clean.
3. For each line in `users.conf`:
   - Creates (or updates) the primary group, respecting a requested GID.
   - Calls `useradd` or `usermod` with the resolved shell, primary
     group, home, and optional UID.
   - Creates any supplementary groups that don't exist yet.
   - Runs `usermod -G <csv>` to set supplementary group membership.
   - If the account can log in and has a non-empty hash, applies it
     with `usermod -p <hash>`; otherwise runs `usermod -L` to lock.
   - Seeds a minimal `~/.xinitrc` and copies `~/.config/awesome` and
     `~/.config/picom` from `/run/qemu-home-seed/` if those paths don't
     already exist in the new home directory. (That seed directory is
     mounted by `./run.sh` for devbox/macbook VM runs. On real hardware
     it isn't mounted, so the seeding is a no-op.)
4. Removes `/usr/local/etc/users.conf` so the hashed credentials don't
   stay on the root image after provisioning.

If the service fails, the A/B health gate flags the slot bad and the
system rolls back on the next boot.

## Dotfiles bootstrap

Setting `dotfiles_repo` on a user causes `build.sh` to bake a working
clone of that repo into the image at
`/usr/local/share/dotfiles-seed/<username>/`. On first boot,
`provision-local-users` copies that seed into `~/.dotfiles`, `chown`s
it to the user, and runs `dotfiles_install` (default `./install`) via
`runuser`.

### Why bake the seed instead of cloning at first boot

First boot frequently happens on a fresh laptop that's still on
captive-portal Wi-Fi or has no network at all. Cloning during
provisioning would either fail or hang the boot. The image ships a
sealed working tree with submodules already initialized so the
bootstrap script has everything it needs locally.

### Build-host cache

`build.sh` keeps a long-lived clone per dotfiles repo at
`$MKOSI_DOTFILES_CACHE/<sanitized-key>` (default
`~/.cache/mkosi-dotfiles`). On the warm path, every build does:

```
git fetch --recurse-submodules origin
git reset --hard origin/HEAD
git submodule update --init --recursive
cp -a <cache> <metadata>/usr/local/share/dotfiles-seed/<username>/
```

That's typically a fraction of a second on top of an existing clone.
The cache survives across `--force-rebuild`; if you want to nuke it,
delete `~/.cache/mkosi-dotfiles` by hand.

To use a snapshot of the cache as-is (no `git fetch` — handy when
working offline or when the dotfiles remote is unreachable), set
`MKOSI_DOTFILES_OFFLINE=1`. That errors out if the cache is empty
rather than silently shipping an image without dotfiles.

To skip the whole step, pass `--skip-dotfiles` to `build.sh`. The
seed dir won't exist, so first-boot provisioning leaves `~/.dotfiles`
alone for any user whose entry has `dotfiles_repo` set.

### When the install command runs vs. when it's skipped

`apply_dotfiles_for_user` skips the entire step if `~/.dotfiles`
already exists in the user's home. That keeps the bootstrap
idempotent across A/B image updates: retained homes already have
whatever the user did last time, and re-running dotbot on top of a
live home would overwrite hand edits.

If you want to re-run the bootstrap on an existing user, delete
`~/.dotfiles` (and any symlinks dotbot created) before the next
boot.

### Picking the right `dotfiles_install`

- **Vanilla dotbot:** the default `./install` works — that's the
  shell wrapper dotbot's `init-dotfiles` template ships.
- **Custom bootstrap script:** set `dotfiles_install` to the script
  name plus any flags. If your script normally fetches the dotbot
  submodule from the network, pass whatever flag tells it to skip
  that — first boot is offline. The build-host clone already
  initialized submodules, so the dotbot binary is present locally.
- **No bootstrap, just files:** leave `dotfiles_install` unset and
  don't ship an `install` script. The seed still lands at
  `~/.dotfiles`, but nothing runs against it. Useful for users who
  manage symlinks via some other tool, or who only want a working
  tree they can `cd` into.

## Why not `systemd-sysusers`

`systemd-sysusers.conf` is great for system accounts but does not
handle:

- supplementary group membership
- shell selection per user
- `chage` policies
- idempotent re-run with a state marker
- seeding from a runtime-mounted directory for QEMU smoke tests

It's also awkward to feed structured data into. `.users.json` driven by
a small shell script is more transparent and keeps the existing
convention in this repo.

If you later want to converge on sysusers for system accounts (e.g.
`tss`, service users installed by packages), keep this script for the
human login user and let the respective package install its own
sysusers fragments.
