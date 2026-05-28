# Host-specific configuration

Each subdirectory represents a physical or virtual machine with
settings unique to that box. A host overlay sits on top of the base
image + selected profiles; see `mkosi.profiles/README.md` for how
profiles and roles compose.

## Files a host can provide

| File | Purpose |
| --- | --- |
| `profile.default` | Default profile list when `./build.sh --host <host>` runs without `--profile`. Space-separated profile and/or role names. |
| `mkosi.conf.d/*.conf` | Extra mkosi config scoped by `[Match] Profiles=X` to only apply when `X` is in the resolved profile list. |
| `mkosi.extra/` | Files overlaid into the image. Applied LAST by mkosi, so host files win over any profile's equivalent path. |
| `mkosi.extra/etc/s3-backup-paths.conf` | List of file/directory paths to upload (one per line) when `s3-unencrypted-backup` profile is selected. Supports glob patterns. |
| `image-id-suffix` | Short alias used in place of the host name in GPT partition labels (labels cap at 36 chars). |
| `kernel-cmdline.extra` | Extra kernel command-line args appended to the boot entry. |
| `secure-boot.disabled` | One-line reason — opt out of Secure Boot for this host. |
| `users.json` | Per-host override of the repo-root `.users.json`. |

Everything except `profile.default` is optional.

## Creating a new host

1. `mkdir hosts/<name>/`
2. `echo "macbook awesomewm dev-tools wifi ssh-server" > hosts/<name>/profile.default` (whatever composition fits)
3. `touch hosts/<name>/secure-boot.disabled` with a reason, OR add a `hosts/<name>/mkosi.conf.d/30-secure-boot.conf` — every host-targeted build must do one or the other.
4. Drop any host-specific files under `hosts/<name>/mkosi.extra/`. Common ones:
    * `etc/fstab` — host's disk layout
    * `etc/hostname` — optional explicit hostname. If omitted, `./build.sh --host <name>` writes `<name>` as the image hostname automatically. Use `./build.sh --host <name> --hostname <other-name>` when the runtime hostname should differ from both.
    * `etc/s3-backup-paths.conf` — list of file paths to upload when using the `s3-unencrypted-backup` profile. See `.mkosi-secrets.example/s3-backup-paths.conf.example` for format details.
5. Build: `./build.sh --host <name>`

## Config layering

mkosi applies files in this order — later files overwrite earlier
ones:

```
1. Base           mkosi.extra/
2. Each profile   mkosi.profiles/<name>/mkosi.extra/    (in profile-list order)
3. Host           hosts/<name>/mkosi.extra/
4. Generated      build metadata, including /etc/hostname when needed
```

So if you want a host-specific `/etc/fstab` (e.g. a particular SSD's
PARTLABEL mount), drop it at `hosts/<name>/mkosi.extra/etc/fstab` —
that wins over the global fallback in `mkosi.extra/etc/fstab`
automatically; no special build flag needed.

## Example host

`example-host/` is a starting-point template. Copy its layout and
customize `profile.default` / `mkosi.conf.d/` for a new machine.
