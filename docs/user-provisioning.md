# User provisioning

## Shape of `.users.json`

```
[
  {
    "username": "demo",
    "comment": "Primary login user",
    "can_login": true,
    "uid": 1000,
    "gid": 1000,
    "primary_group": "demo",
    "groups": ["sudo", "audio", "video", "render", "input"],
    "shell": "/bin/bash",

    "password_hash": "$y$j9T$...salt...$...hash...",
    "force_password_change_on_first_login": false
  }
]
```

`password_hash` is strongly preferred. `password` (plaintext) is still
accepted but will be refused by the first-boot provisioner on any image
with `VARIANT_ID=prod` in `/etc/os-release` (the default for non-dev
builds).

## How to generate a `password_hash` without ever writing the password
to disk

```
./scripts/hash-password.sh
```

The script prompts twice (no echo), uses `mkpasswd` from the `whois`
package, prefers yescrypt, and prints only the hash to stdout. Copy
the entire `$y$...` (or `$6$...`) string into the `password_hash`
field.

## What happens on first boot

`ab-user-provision.service` runs once before `multi-user.target`. It:

1. Reads `/etc/ab-users.json` (which mkosi copies from your
   `.users.json`).
2. Creates each user account (primary group, supplementary groups,
   shell, comment).
3. Applies authentication material:
   * if `password_hash` is set and not `"!"`, applies it with `usermod -p`
   * else if `password` is set AND this is a dev image, applies it
     via `chpasswd -c YESCRYPT`
   * else if neither, locks the account to password auth (pubkey auth
     via `/etc/ssh/authorized_keys.d/<user>` still works)
4. Optionally runs `chage -d 0 <user>` to force a password change on
   first interactive login.
5. Shreds `/etc/ab-users.json` and writes
   `/var/lib/ab-user-provision/done`.

If the service fails, the A/B health gate flags the slot bad and the
system rolls back on the next boot.

## Migrating existing hosts

On a host already running the old provisioning path:

1. On your laptop: `./scripts/hash-password.sh`, paste the hash into
   `.users.json` replacing `"password"`.
2. Rebuild the image: `./build.sh --profile <p> --host <h>`.
3. Deploy via the normal sysupdate path.
4. On the host (first login after update), run `passwd` to confirm the
   hash round-trips correctly. The account should unlock cleanly with
   the same password.

## Why not `systemd-sysusers` instead

`systemd-sysusers.conf` is great for system accounts but does not
handle:
* Supplementary group membership
* Shell selection per user
* `chage` policies
* Idempotent re-run with state marker

It is also awkward to feed structured data into. `.users.json` driven
by a small shell script is more transparent and keeps the existing
convention in this repo.

If you later want to converge on sysusers for system accounts
(e.g. `tss`, `cloudflared`), keep this script for the human login
user and let the respective package install the sysusers fragments.
