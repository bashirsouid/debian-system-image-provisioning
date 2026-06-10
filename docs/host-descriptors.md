# Host instance descriptors (prototype)

A **host instance descriptor** is the small, plaintext, **non-secret**
file that describes one physical machine. It is the third layer of the
project's separation of concerns:

| Layer | Generic? | Where | Examples |
|-------|----------|-------|----------|
| Core | generic, public | `mkosi.conf`, `build.sh`, hardening | base image |
| Model profiles | generic, public | `mkosi.profiles/*` | drivers/firmware keyed by hardware |
| **Host instances** | **personal** | `hosts.local/*.conf` + age vault | which profiles, hostname, backup paths |

The goal: the committed repo contains nothing unique to you. Adopting it
for your own machine means dropping in your own descriptor plus your own
age vault — nothing else.

## Secret vs. config

- **Secrets** (passwords, tokens, PSKs, S3 keys) → the age vault
  (`secrets/*.json.age`), which is already per-host. Never put these in a
  descriptor.
- **Config** that merely happens to describe *your* machine (profile
  list, hostname, backup paths, Secure Boot on/off) → the descriptor,
  in **plaintext** so it stays diffable, reviewable, and lintable.

Encrypting non-secret config would blind you to your own setup (no
`git diff`, no CI validation, re-encrypt on every tweak) for no security
gain — so config stays plaintext, and descriptors are gitignored rather
than encrypted.

## Location

- `hosts.local/<name>.conf` — your real descriptors. **Gitignored.**
- `hosts.local.example/<name>.conf` — committed templates.

## Format

`key = value`, one per line, `#` starts a comment. Keys:

| Key | Replaces | Notes |
|-----|----------|-------|
| `profiles` | `hosts/<name>/profile.default` | space-separated profiles/roles |
| `hostname` | `…/etc/hostname` **and** `…/etc/hosts` | also writes a matching `127.0.1.1` line |
| `image_id_suffix` | `hosts/<name>/image-id-suffix` | short GPT-label alias |
| `kernel_cmdline` | `hosts/<name>/kernel-cmdline.extra` | |
| `architecture` | `[Distribution] Architecture=` drop-in | e.g. `arm64`; omit for x86-64 |
| `secure_boot` | `30-secure-boot.conf` / `secure-boot.disabled` | `yes` or `no` |
| `persistent_home` | `hosts/<name>/mkosi.extra/etc/fstab` | `<source> [fstype]` |
| `packages` | `[Content] Packages=` drop-in | space-separated; prefer a profile |
| `backup_paths` | `…/etc/s3-backup-paths.conf` | optional; space-separated |

Anything that cannot be a `key = value` scalar — firmware blobs, quirk
systemd units, driver configs — is **not** a descriptor key. It belongs
in a **model profile** (`mkosi.profiles/<model>/`), selected via
`profiles =`. That is why a machine is two files: hardware is shared
infrastructure, not per-machine data.

## How it works

When `--host <name>` is built and `hosts.local/<name>.conf` exists,
`build.sh` renders a synthetic overlay under `.mkosi-host/<name>/` (also
gitignored) that is byte-for-byte the layout it already consumes
(`profile.default`, `image-id-suffix`, `kernel-cmdline.extra`,
`mkosi.conf.d/30-secure-boot.conf` or `secure-boot.disabled`,
`mkosi.extra/...`). All of `build.sh`'s existing host-overlay logic then
points at that directory via `$HOST_BASE`. The descriptor is purely an
input adapter; no consumption logic changed.

If no descriptor exists, `$HOST_BASE` is the legacy `hosts/<name>/` path
and behavior is unchanged — so migration is host-by-host.

## Status: all hosts migrated

Every host now has a descriptor template in `hosts.local.example/` and a
live (gitignored) copy in `hosts.local/`:

| Host | Hardware moved to | Notes |
|------|-------------------|-------|
| evox2 | — | scalars only |
| cloudbox | — | `architecture = arm64` |
| macbookpro13-2019-t2 | `mkosi.profiles/macbook` | T2 quirks; `secure_boot = no` |
| x1g13 | `mkosi.profiles/thinkpad-x1g13` (new) | 48 firmware blobs + LNL configs |
| example-host | — | template demonstrating `packages` |

The legacy `hosts/<name>/` dirs are left in place as a working fallback
(the descriptor takes precedence). The moved hardware now lives in
profiles that **both** paths select, so a fallback build still gets it.
Once you've built and verified each machine, delete the `hosts/<name>/`
dirs.

### Build to verify (per your two-machine workflow)

```bash
./build.sh --host evox2          # safe: scalars only
./build.sh --host cloudbox       # safe: scalars + arch
./build.sh --host macbookpro13-2019-t2   # verify: T2 quirks now via macbook profile
./build.sh --host x1g13          # verify: firmware/initramfs/backports now via thinkpad-x1g13
```

macbook and x1g13 move real hardware between trees; mkosi stages a
profile's `mkosi.extra/` the same way it staged the host overlay (sandbox
tree during build + ExtraTree into the image), so the move is faithful —
but a build is the real confirmation for firmware/initramfs/DKMS ordering.

## Not yet migrated (smaller follow-ups)

`run.sh` and the live-test/rollback tools read a few host files directly
(`ab-flash.conf.example` deploy config, fstab for `/home` detection). The
default-profile resolver is already descriptor-aware; the rest is
mechanical. Note `ab-flash.conf` is **deploy-time** config (device paths,
boot policy), a separate concern from the build-time descriptor.
