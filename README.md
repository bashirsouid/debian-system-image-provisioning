# mkosi image provisioning

This tree builds Debian images with `mkosi`, keeps the desktop path on source-built
AwesomeWM, and now uses the **native systemd update stack** for retained-version / A-B-like
updates:

- `systemd-repart` for the initial disk layout
- `systemd-sysupdate` for installing new root and boot artifacts
- `systemd-boot` boot counting + `systemd-bless-boot` for automatic rollback
- `mkosi` as the image builder and artifact producer

## Why the previous A/B script was only a bridge

The old `ab-flash.sh` path copied a built `image.raw` into an inactive partition and kept
its own slot state on the ESP. That worked as a practical bring-up tool, but it duplicated
three jobs that the current systemd stack already solves natively:

- versioned boot artifacts and boot attempt counting
- health-gated promotion of a newly booted version
- versioned root-image installation into a retained offline slot

That is why it was a **bridge** rather than the golden path: it was a custom copier wrapped
around a problem that modern systemd already has first-class primitives for.

The repo now treats the golden path as:

1. **Bootstrap once** onto a blank or offline target disk/image with `systemd-repart`
2. **Install the first version** with `systemd-sysupdate`
3. **Boot via systemd-boot**
4. On later updates, stage the next version with `systemd-sysupdate`
5. Let boot counting + `boot-complete.target` + `systemd-bless-boot` decide whether the new
   version stays or the older retained version wins

## What “A/B” means in the new design

The new design is closer to “two retained versions” than to permanently named `ROOT_A` and
`ROOT_B` partitions.

That is intentional.

`systemd-sysupdate` is natively version-oriented. It installs a new version into an empty
root slot, keeps the currently booted version protected, and retains up to `InstancesMax=2`.
So the effective behavior is still A/B:

- one currently booted known-good version
- one newer trial version
- automatic fallback when the new one does not become healthy

But the slots are now managed by **version metadata**, not by a custom “copy this raw image
into ROOT_B” script.

## Current goals

- reproducible base images
- source-built AwesomeWM for the `devbox` profile
- first-boot local user provisioning that works in rootless mkosi builds
- Liquorix kernel for the x86-64 `devbox` path
- native retained-version updates with `systemd-sysupdate`
- a server-only ARM64 `cloudbox` overlay
- an Ansible playbook that can build and bootstrap/update `cloudbox`

## Important assumptions and constraints

These are deliberate design constraints, not hidden gotchas:

- UEFI only
- `systemd-boot` is the supported boot loader for the native update path
- the **first** install onto a new disk is destructive and expects a blank or offline target
- later updates are in-place via `systemd-sysupdate`
- the initial bootstrap currently creates:
  - one ESP
  - two root partitions
- Secure Boot is **not** wired up yet in this repo’s update flow
- host-specific kernel flags are still supported, but they now live in generated Boot Loader
  Specification entries instead of GRUB config
- the `cloudbox` path is intentionally server-only: no desktop stack, no AwesomeWM, no
  Liquorix

## Host dependency auto-install

The repo scripts now try to auto-install missing **host-side** tools on Debian/Ubuntu
build or deploy machines before they fail. The intent is to make commands like
`./build.sh`, `./run.sh`, `./clean.sh`, `./scripts/bootstrap-ab-disk.sh`, and
`./scripts/sysupdate-local-update.sh` behave like project entrypoints rather than
assuming you already curated the host manually.

Current behavior:

- auto-install is **enabled by default**
- on Debian/Ubuntu hosts, scripts use `apt-get install --no-install-recommends`
  and `sudo` when needed
- set `AB_AUTO_INSTALL_DEPS=no` to disable this and get a manual install hint instead
- if the required commands already exist, the scripts do not try to install anything

This especially matters for the sysupdate export path because on Debian trixie the
`sfdisk` tool comes from the `fdisk` package rather than from the `util-linux` package,
and `jq` is its own package. The native update path also depends on `systemd-repart`,
`systemd-sysupdate`, and the systemd-boot tooling on the host side.

Examples:

```bash
./build.sh --profile devbox
AB_AUTO_INSTALL_DEPS=no ./build.sh --profile server --host cloudbox
```

## Quick start

### Desktop/devbox smoke test in QEMU

```bash
./update-3rd-party-deps.sh
cp .users.json.sample .users.json
# edit .users.json and set a real password for your login user
./clean.sh --all
./build.sh --profile devbox
./run.sh
```

On first boot the image provisions local users from embedded data and then removes the user
seed file.

For the devbox profile, log in and run:

```bash
startx
```

For a different X resolution:

```bash
STARTX_RESOLUTION=1920x1080 startx
```

### ARM64 cloudbox build

```bash
cp .users.json.sample .users.json
# edit .users.json
./clean.sh --all
./build.sh --profile server --host cloudbox
```

That overlay:

- forces `Architecture=arm64`
- uses Debian’s stock `linux-image-arm64`
- stays server-only

## QEMU sample home seed

`run.sh` defaults to an **ephemeral** VM and mounts `runtime-seeds/qemu-home/` into the guest
for the `devbox` profile.

On first boot the guest copies the sample files into the login user’s home only if the target
paths do not already exist.

That gives you a smoke-test config in QEMU without baking personal host config into the image
that you would later flash or deploy.

## User IDs for shared mutable state

By default, `build.sh` copies the invoking host user’s numeric uid/gid/group into any
`.users.json` entry whose `username` matches the build host user. That is the safest default
when you want ownership to stay stable across retained-root updates.

You can also pin ids explicitly in `.users.json`:

```json
[
  {
    "username": "demo",
    "password": "change-me-now",
    "can_login": true,
    "uid": 1000,
    "gid": 1000,
    "primary_group": "demo"
  }
]
```

To disable automatic host-id syncing for the matching host username:

```bash
./build.sh --profile devbox --sync-host-ids=no
```

## `/home` strategy

For real retained-root machines, keep mutable workstation data **outside** the root image.
That means `/home` should live on a separate persistent partition or subvolume.

For QEMU testing, the repo intentionally does **not** mount your real host home by default.
Instead it seeds a tiny sample AwesomeWM setup. When you want to compare with host config,
use runtime sharing explicitly:

```bash
./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"
./run.sh --runtime-home
```

Use `--runtime-home` only for disposable tests.

See `docs/home-storage.md` for the storage trade-offs.

## Build output and sysupdate artifacts

`build.sh` now pins `mkosi` to a single `ImageId` + `ImageVersion` for that invocation and
writes `mkosi.output/.latest-build.env` plus per-profile/per-host metadata files such as
`mkosi.output/.latest-build.devbox.none.env`. `run.sh` reuses that metadata, so `./build.sh`
followed by `./run.sh` boots the image that was just built instead of recalculating a fresh
timestamped output name. If you pass `--profile` or `--host`, `run.sh` looks for the matching
saved build metadata for that specific combination. `mkosi` history is also enabled in
`mkosi.conf.d/10-caching.conf` so a plain `mkosi vm` can reuse the last build configuration as well.

`build.sh` produces two layers of output in `mkosi.output/`:

1. the usual `mkosi` build outputs such as `debian-provisioning_<VERSION>.raw`
2. versioned **sysupdate source artifacts** used by the golden-path updater

Current exported artifact names look like this:

```text
debian-provisioning_<VERSION>_<ARCH>.root.raw
debian-provisioning_<VERSION>_<ARCH>.efi
debian-provisioning_<VERSION>_<ARCH>.conf
```

The generated `.conf` file is a Boot Loader Specification entry that references the matching
UKI and supplies the root partition label plus host-specific extra kernel arguments.

## Host-specific kernel arguments

GRUB-specific kernel flags are not required for this design.

Instead, host overlays can supply kernel arguments through `hosts/<name>/kernel-cmdline.extra`.
Those arguments are rendered into the versioned Boot Loader Specification entry that gets
installed by `systemd-sysupdate`.

Current examples:

- `hosts/evox2/kernel-cmdline.extra`
- `hosts/cloudbox/kernel-cmdline.extra`

For the Ryzen AI Max desktop path this is where `amdgpu.gttsize=` now belongs.

## The native install/update flow

### One-time destructive bootstrap onto a blank or offline target disk/image

Build first:

```bash
./build.sh --profile server --host cloudbox
```

Then bootstrap a target disk or raw disk image:

```bash
sudo ./scripts/bootstrap-ab-disk.sh --target /dev/sdX
```

What that script does:

1. destroys the target partition table
2. creates the ESP + two empty root partitions with `systemd-repart`
3. installs `systemd-boot` into the target ESP
4. seeds the first retained version using `systemd-sysupdate` from `mkosi.output/`

### Later in-place updates on an already bootstrapped machine

On a machine that is already running this layout:

```bash
sudo ./scripts/sysupdate-local-update.sh --source-dir ./mkosi.output --reboot
```

That stages the next version with `systemd-sysupdate` and reboots into the new trial entry.

### Boot success and fallback

The image now uses the native boot-complete path:

- a generated BLS entry is created with boot counters
- `systemd-boot` decrements tries on each boot attempt
- `ab-health-gate.service` runs before `boot-complete.target`
- if the health gate succeeds, `systemd-bless-boot.service` marks the entry good
- if the health gate never succeeds, the counted entry eventually falls behind the older good
  one and the system falls back to the older retained version

This is the key difference from the old bridge path: promotion/rollback is now done by the
boot loader + systemd boot-complete pipeline, not by custom ESP state files.

## Health checks

The current boot health gate does three things:

- waits `AB_HEALTH_DELAY_SECS` seconds after boot
- fails if there are failed systemd units
- runs any executable hooks in `/usr/local/libexec/ab-health-check.d`

Health status is recorded locally in:

```text
/var/lib/ab-health/status.env
```

Useful commands on the installed system:

```bash
ab-status
ab-bless-boot
ab-mark-bad
```

- `ab-status` shows the current root partition label, build metadata, health result, bootctl
  state, and installed sysupdate versions
- `ab-bless-boot` requests `boot-complete.target` so `systemd-bless-boot` can mark the
  current entry good
- `ab-mark-bad` marks the current counted entry bad immediately

## Cloudbox / Oracle ARM testing

The `cloudbox` overlay is intended for an ARM64 server-style machine and uses serial-console-
friendly kernel flags through `hosts/cloudbox/kernel-cmdline.extra`.

This is the cleanest place to validate the modern path because:

- it removes the desktop stack from the equation
- you can rebuild and redeploy repeatedly
- you can test the retained-version flow before migrating a workstation

## Ansible

The playbook under `ansible/playbooks/cloudbox-ab-deploy.yml` now follows the native model.
It can do either of two things:

1. **bootstrap mode** — destructively prepare a blank/offline target disk
2. **update mode** — build a new version and stage it with `systemd-sysupdate`

Bootstrap mode is for the first install only. Update mode is for all later deployments.

See `ansible/README.md` and `ansible/group_vars/cloudbox.yml.example`.

## Liquorix notes

The `devbox` profile uses Liquorix on x86-64.

The `server` profile keeps Debian’s stock kernel path. The ARM64 `cloudbox` overlay uses
`linux-image-arm64`.

For the `devbox` profile we keep `dpkg` and `kmod` in the image and disable mkosi package-
metadata cleanup. That avoids a Debian/apt cleanup edge case where purging `dpkg` can cause
`kmod` auto-removal to fail because `kmod` maintainer scripts call
`dpkg-maintscript-helper`.

## Legacy manual flashing

`scripts/ab-flash.sh` remains in the tree as a legacy/manual fallback path for local
experimentation, but it is no longer the recommended design center of the repo.

The recommended path is now:

- `build.sh`
- `bootstrap-ab-disk.sh` once
- `sysupdate-local-update.sh` thereafter

## Repo layout

- `mkosi.sysupdate/` — native sysupdate transfer definitions
- `deploy.repart/` — one-time disk layout for bootstrap
- `scripts/bootstrap-ab-disk.sh` — destructive first install to a blank/offline target
- `scripts/sysupdate-local-update.sh` — later in-place updates on an installed system
- `scripts/export-sysupdate-artifacts.sh` — exports versioned root/UKI/BLS artifacts after build
- `hosts/cloudbox/` — ARM64 server overlay
- `hosts/evox2/` — example workstation overlay
