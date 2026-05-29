# Debian A/B Image Provisioning

Builds reproducible Debian images and deploys them with the native
systemd update stack. Every image is versioned, signed (optional), and
designed for fully automated A/B root updates with hardware-level
rollback — no package manager on the running system required.

## What you get

* **Reproducible images** — package set pinned to a `snapshot.debian.org`
  timestamp; identical inputs produce identical outputs
* **A/B retained-root updates** — two root slots, versioned with
  `systemd-sysupdate`; a failed update rolls back automatically on next
  boot via `systemd-boot` boot counting
* **LUKS-encrypted root** — the entire root partition is encrypted;
  credentials live inside it and are further isolated per-service at
  runtime via systemd `LoadCredential=`
* **Optional Secure Boot** — UKIs signed with a locally-generated
  RSA-4096 key; opt in per host
* **First-boot user provisioning** — user accounts defined in your
  secrets file are created on first boot and removed from the image
  after provisioning
* **Three included profiles** — `devbox` (AwesomeWM + Liquorix kernel),
  `server` (headless CLI baseline), `macbook` (Apple T2 hardware support)
* **Hardware-test USB workflow** — boot the same retained-version stack
  from a USB stick before flashing internal storage
* **Ansible playbook** for ARM64 server bootstrapping and updates

## Assumptions

* Target machines are UEFI-only; `systemd-boot` is the bootloader
* The initial install onto a target disk is destructive (blank or offline
  target)
* Later updates are in-place via `systemd-sysupdate`
* The bootstrap creates one ESP and two root partitions
* Host-specific kernel flags live in Boot Loader Specification entries

## Quick start

### 1. Set up your secrets and users

The recommended workflow keeps everything in one encrypted vault:

```sh
bin/mkosi-vault-init.sh          # one-time: create secrets/mkosi-secrets.json.age
bin/mkosi-vault-edit.sh          # add your SSH key, service tokens, and users
```

The secrets file schema is in `secrets/mkosi-secrets.example.json`.
Define your login user under the `"users.json"` key — see
`docs/user-provisioning.md` for all supported fields and the
`bin/hash-password.sh` helper to generate a `password_hash`.

If you prefer not to use the vault, copy `.users.json.sample` to
`.users.json`, edit it, and create `.mkosi-secrets/` manually with the
credential files documented in `docs/local-secret-vault.md`.

### 2. Smoke test in QEMU

```sh
./update-3rd-party-deps.sh
./build.sh --profile devbox
./run.sh
```

On first boot the image provisions your local users, then removes the
credential seed. Log in and run `startx` (or
`STARTX_RESOLUTION=1920x1080 startx`) to start the desktop.

### 3. Build for a specific host

```sh
./update-3rd-party-deps.sh        # fetch/pin third-party apt keys (devbox/macbook)
bin/mkosi-vault-build.sh -- --host <yourhost>
```

`bin/mkosi-vault-build.sh` decrypts the vault into `.mkosi-secrets/`
for the duration of the build, then removes it. See
`docs/local-secret-vault.md` for more options.

### 4. Flash to a target disk or USB

After a successful build:

```sh
# Write a hardware-test USB (recommended first step for new hardware):
sudo ./bin/ab-install.sh --target /dev/sdX --host <yourhost>

# Or bootstrap internal storage directly:
sudo ./bin/ab-install.sh --target /dev/sdX
```

## Host overlays

Each directory under `hosts/<name>/` represents a machine. A host
overlay sits on top of the base image and selected profiles. See
`hosts/README.md` for the files a host can provide.

Included example overlays:

| Host | Profile | Notes |
| --- | --- | --- |
| `evox2` | `devbox` | Intel workstation reference layout with fstab example |
| `cloudbox` | `server` | ARM64 server, serial-console-friendly kernel args |
| `macbookpro13-2019-t2` | `macbook` | Intel T2 Mac; T2 kernel, firmware, audio fix |
| `x1g13` | `devbox` | ThinkPad X1 Carbon Gen 13 (Lunar Lake) |
| `example-host` | — | Template to copy when adding a new machine |

To add your own machine: copy `hosts/example-host/`, set
`profile.default`, and add a `30-secure-boot.conf` or a
`secure-boot.disabled` file. See `hosts/README.md` for a step-by-step.

## User definitions

Define users in your secrets file (preferred):

```json
"users.json": [
  {
    "username": "you",
    "can_login": true,
    "uid": 1000,
    "gid": 1000,
    "primary_group": "you",
    "groups": ["sudo", "audio", "video", "render", "input", "plugdev"],
    "shell": "/bin/bash",
    "password_hash": "$y$..."
  }
]
```

Per-host overrides go under `hosts.<hostname>.users.json` in the same
file — same format, replaces the top-level array for that host. Use
`bin/hash-password.sh` to generate a `password_hash` without touching
disk.

See `docs/user-provisioning.md` for the full field reference, dotfiles
bootstrap, host UID/GID sync, and why the design uses a first-boot
script rather than `systemd-sysusers`.

## Profiles and roles

A build is defined by a host plus a list of profiles. Profiles are
composable and last-writer-wins (host overlay beats profile, profile
beats base). See `mkosi.profiles/README.md` for the full profile table.

Role files in `mkosi.roles/` expand to profile lists as a shorthand:

```sh
# Production server (ssh + Tailscale + Cloudflare Tunnel + health check)
./build.sh --profile server-stack --host myserver

# Desktop workstation (AwesomeWM + audio + Bluetooth + dev-tools + wifi)
./build.sh --profile "devbox desktop" --host mymachine

# Add heavy dev tooling on top
./build.sh --profile "devbox desktop group_dev" --host mymachine
```

See `mkosi.roles/README.md` for the full role table and common compositions.

## Configuration

### UID/GID stability across updates

`build.sh` copies the invoking user's numeric uid/gid/group into any
user entry whose `username` matches the build host user. This keeps
file ownership stable when `/home` is on a separate persistent
partition and survives A/B root updates.

Pin IDs explicitly in the user definition to prevent this:

```json
{ "username": "you", "uid": 1000, "gid": 1000, "primary_group": "you" }
```

Or disable the sync entirely:

```sh
./build.sh --sync-host-ids=no
```

### /home strategy

Mutable user data lives outside the root image. The supported layout is
a GPT `home` partition on the same disk (auto-mounted by
`systemd-gpt-auto-generator`) plus an optional `DATA` partition mounted
at `/mnt/data`. Both survive A/B root updates without per-slot edits.

See `docs/home-storage.md` for trade-offs and the fstab pattern.

### Host-specific kernel arguments

Host overlays supply kernel arguments via `hosts/<name>/kernel-cmdline.extra`.
These render into the versioned Boot Loader Specification entry installed
by `systemd-sysupdate`.

### QEMU sample home seed

`run.sh` mounts `runtime-seeds/qemu-home/` into the guest for the
`devbox` profile. On first boot the guest copies sample AwesomeWM/picom
config into the login user's home only if those paths do not already
exist. Share your real config instead:

```sh
./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"
```

## Build output

`build.sh` writes versioned sysupdate source artifacts:

```
deb-ab_<VERSION>_<ARCH>.root.raw
deb-ab_<VERSION>_<ARCH>.efi
deb-ab_<VERSION>_<ARCH>.conf
```

`run.sh` reads the metadata written by the last `build.sh`, so
`./build.sh` followed by `./run.sh` always boots the image just built.

## Caching

Three gitignored cache layers live under the repo root:

* `mkosi.pkgcache/` — downloaded `.deb` files, partitioned by arch/release
* `mkosi.cache/` — incremental rootfs snapshots after package unpack
* `mkosi.builddir/` — persistent scratch for ccache, meson, cmake

`./build.sh --clean` clears the incremental cache (`mkosi -f -f`). Drop
`mkosi.pkgcache/` manually for a fully cold rebuild.

## Verifying a built image

```sh
./bin/verify-image-raw.sh                              # newest *.raw in mkosi.output/
./bin/verify-image-raw.sh --image path/to/image.raw   # specific file
```

After booting in QEMU or on hardware:

```sh
sudo ab-verify      # LUKS, TPM enrollment, credentials, SSH, VPN, failed units
```

Then on baremetal, bind the LUKS volume to the TPM for auto-unlock:

```sh
sudo ab-enroll-tpm
```

## Install and update flow

### One-time destructive bootstrap

```sh
./build.sh --host <yourhost>
sudo ./bin/ab-install.sh --target /dev/sdX
```

This destroys the target partition table, creates the ESP and two empty
root partitions with `systemd-repart`, installs `systemd-boot`, and
seeds the first retained version.

### Later in-place updates

On a machine already running this layout:

```sh
bin/mkosi-vault-build.sh -- --host <yourhost>
sudo ./bin/sysupdate-local-update.sh --source-dir ./mkosi.output --reboot
```

## Health checks

The boot health gate waits `AB_HEALTH_DELAY_SECS` seconds after boot,
fails if there are failed systemd units, and runs any hooks in
`/usr/local/libexec/ab-health-check.d/`. Installed commands:

* `ab-status` — root partition label, build metadata, health result,
  bootctl state, installed sysupdate versions
* `ab-bless-boot` — request `boot-complete.target` manually
* `ab-mark-bad` — mark the current counted entry bad immediately

## ARM64 server and Ansible

The `cloudbox` overlay targets ARM64 server-style machines and uses
serial-console-friendly kernel flags. It is server-only — no desktop
stack, no AwesomeWM, no Liquorix — which makes it the fastest loop for
validating the A/B update flow before migrating a workstation.

`ansible/playbooks/cloudbox-ab-deploy.yml` supports two modes:

1. **bootstrap** — destructively prepare a blank/offline target disk
2. **update** — build a new version and stage it with `systemd-sysupdate`

See `ansible/README.md` and `ansible/group_vars/cloudbox.yml.example`.

## Host dependency auto-install

On Debian/Ubuntu build hosts, missing tools are installed automatically
before a build fails. Disable with `AB_AUTO_INSTALL_DEPS=no` for a
manual hint instead.

## Repo layout

```
bin/         User-facing commands (each has a Usage: block)
scripts/     Build-pipeline internals (called by build.sh / CI)
installer/   Scripts embedded in live-USB bundles; run from the booted USB
mkosi.profiles/    Composable image profiles
mkosi.roles/       Convenience role files (expand to profile lists)
hosts/             Per-machine overlays
docs/              Extended documentation
secrets/           Age-encrypted vault and example schema
mkosi.extra/       Global image content
mkosi.finalize.d/  Post-package-install hooks
deploy.repart/     Partition layout for first bootstrap
mkosi.sysupdate/   Version update definitions baked into the image
ansible/           ARM64 server deploy playbook
```

Key `bin/` commands:

| Command | Purpose |
| --- | --- |
| `bin/ab-install.sh` | Write to a target disk (USB or internal). Auto-detects mode: repartition a blank disk, or reflash an existing A/B layout |
| `bin/sysupdate-local-update.sh` | In-place `systemd-sysupdate` run on an already-bootstrapped machine |
| `bin/verify-image-raw.sh` | Sanity-check a built image before flashing |
| `bin/generate-secureboot-keys.sh` | Create Secure Boot signing key + cert |
| `bin/hash-password.sh` | Generate a yescrypt `password_hash` for the secrets file |
| `bin/mkosi-vault-init.sh` | First-run setup for the age secret vault |
| `bin/mkosi-vault-edit.sh` | Edit the age-encrypted vault |
| `bin/mkosi-vault-build.sh` | Decrypt vault, build, then clean up staging |
| `bin/test-rollback.sh` | Smoke test the A/B rollback path in QEMU |

## Further reading

* `docs/user-provisioning.md` — user definitions, dotfiles bootstrap, UID sync
* `docs/security-model.md` — full security architecture (Secure Boot, LUKS, identity)
* `docs/credential-encryption.md` — three-layer secret protection model
* `docs/local-secret-vault.md` — age vault setup and schema
* `docs/ab-workflow.md` — A/B update flow, dual-boot, persistent container storage
* `docs/remote-access.md` — Tailscale + Cloudflare Tunnel + FIDO2 SSH
* `docs/live-test-usb.md` — hardware-test USB creation and usage
* `docs/secure-boot.md` — Secure Boot enrollment per host
* `docs/home-storage.md` — /home layout trade-offs
* `docs/cloud-vm.md` — OCI ARM cloud VM: LUKS, serial console, vTPM, bootstrap workflow
* `mkosi.profiles/README.md` — full profile and role table
* `mkosi.roles/README.md` — role compositions and common build combinations
* `hosts/README.md` — host overlay format and how to add a new machine
