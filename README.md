# mkosi image provisioning

This tree builds Debian images with `mkosi`, keeps the desktop path on
source-built AwesomeWM, and uses the **native systemd update stack** for
retained-version / A-B-like updates:

- `systemd-repart` for the initial disk layout
- `systemd-sysupdate` for installing new root and boot artifacts
- `systemd-boot` boot counting + `systemd-bless-boot` for automatic rollback
- `mkosi` as the image builder and artifact producer

## Why the previous A/B script was only a bridge

The old `ab-flash.sh` path copied a built `image.raw` into an inactive
partition and kept its own slot state on the ESP. That worked as a
practical bring-up tool, but it duplicated three jobs that the current
systemd stack already solves natively:

- versioned boot artifacts and boot attempt counting
- health-gated promotion of a newly booted version
- versioned root-image installation into a retained offline slot

That is why it was a **bridge** rather than the golden path: it was a
custom copier wrapped around a problem that modern systemd already has
first-class primitives for.

The repo now treats the golden path as:

1. **Bootstrap once** onto a blank or offline target disk/image with
   `systemd-repart`
2. **Install the first version** with `systemd-sysupdate`
3. **Boot via systemd-boot**
4. On later updates, stage the next version with `systemd-sysupdate`
5. Let boot counting + `boot-complete.target` + `systemd-bless-boot`
   decide whether the new version stays or the older retained version
   wins

`scripts/ab-flash.sh` is still in the tree as a legacy/manual fallback,
but it is no longer the recommended design center of the repo.

## What "A/B" means in the new design

The new design is closer to "two retained versions" than to permanently
named `ROOT_A` and `ROOT_B` partitions.

That is intentional.

`systemd-sysupdate` is natively version-oriented. It installs a new
version into an empty root slot, keeps the currently booted version
protected, and retains up to `InstancesMax=2`. So the effective
behavior is still A/B:

- one currently booted known-good version
- one newer trial version
- automatic fallback when the new one does not become healthy

But the slots are managed by **version metadata**, not by a custom
"copy this raw image into ROOT_B" script.

## Current goals

- reproducible base images
- source-built AwesomeWM for the `devbox` and `macbook` profiles
- first-boot local user provisioning that works in rootless mkosi builds
- Liquorix kernel for the x86-64 `devbox` path
- a T2-oriented `macbook` desktop path for Intel 2019-era MacBook Pros
- native retained-version updates with `systemd-sysupdate`
- a server-only ARM64 `cloudbox` overlay
- an Ansible playbook that can build and bootstrap/update `cloudbox`
- a hardware-test USB workflow that boots the native retained-version
  stack on removable media

## Important assumptions and constraints

These are deliberate design constraints, not hidden gotchas:

- UEFI only
- `systemd-boot` is the supported boot loader for the native update path
- the **first** install onto a new disk is destructive and expects a
  blank or offline target
- later updates are in-place via `systemd-sysupdate`
- the initial bootstrap currently creates:
  - one ESP
  - two root partitions
  - a GPT `home` partition
- Secure Boot is **not** wired up yet in this repo's update flow
- host-specific kernel flags live in generated Boot Loader Specification
  entries, not GRUB config
- the `cloudbox` path is intentionally server-only: no desktop stack, no
  AwesomeWM, no Liquorix
- the `macbook` path uses third-party T2 support packages and firmware
  repos during the build
- hardware-test USBs are bootstrapped with the same native
  `systemd-repart` + `systemd-sysupdate` flow, not a separate installer
  format

## Host dependency auto-install

The repo scripts try to auto-install missing **host-side** tools on
Debian/Ubuntu build or deploy machines before they fail. The intent is
to make `./build.sh`, `./run.sh`, `./clean.sh`, and the scripts under
`scripts/` behave like project entrypoints rather than assume you
already curated the host.

- auto-install is **enabled by default**
- on Debian/Ubuntu hosts, scripts use
  `apt-get install --no-install-recommends` and `sudo` when needed
- set `AB_AUTO_INSTALL_DEPS=no` to disable this and get a manual install
  hint instead
- if the required commands already exist, the scripts do not try to
  install anything

This especially matters for the sysupdate export path because on Debian
trixie the `sfdisk` tool comes from the `fdisk` package rather than
`util-linux`, and `jq` is its own package. The native update path also
depends on `systemd-repart`, `systemd-sysupdate`, and the systemd-boot
tooling on the host side. `./run.sh` additionally needs
`qemu-system-x86`, `ovmf`, `virtiofsd`, and `swtpm` for `mkosi vm`.

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
# optional: edit .users.json and set a real password for your login user
# the default sample ships demo / change-me-now so a first build
# produces a working login; change it before flashing anything real
./clean.sh --all
./build.sh --profile devbox
./run.sh
```

On first boot the image provisions local users from embedded data and
then removes the user seed file.

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
- uses Debian's stock `linux-image-arm64`
- stays server-only

### Intel T2 MacBook Pro build

```bash
./update-3rd-party-deps.sh
cp .users.json.sample .users.json
# edit .users.json
./clean.sh --all
./build.sh --profile macbook --host macbookpro13-2019-t2
```

This path is aimed at the 2019-era Intel 13-inch T2 MacBook Pro desktop
workflow. It swaps out Liquorix for the t2linux kernel, keeps PipeWire
on Debian's default stack, installs Apple Wi-Fi/Bluetooth firmware plus
the T2 kernel packages, builds and installs the `snd_hda_macbookpro`
CS8409 driver override into the image at build time, enables mkosi
build-script network access for that host so the installer can fetch
matching kernel sources, uses NetworkManager with Debian's
`network-manager-iwd` integration, and enables a suspend workaround
service for the Apple T2 / Broadcom module stack.

Important limits to understand up front:

- the current t2linux state page still describes Bluetooth as only
  partially working on some T2 models and notes BCM4377 interference
  issues on 2.4 GHz Wi-Fi
- the same state page says the trackpad works but is not as good as on
  macOS
- the current t2linux audio guide says experimental speaker DSP tuning
  is only available for the 16-inch 2019 MacBook Pro and should not be
  used on other models
- `apple-t2-audio-config` is not the primary speaker fix on this 13-inch
  CS8409 path; the image now builds the `snd_hda_macbookpro` override so
  sound does not depend on custom PipeWire tweaks
- hibernation is not fully configured by default in this repo's
  retained-version layout yet because that still needs swap + resume
  wiring

See `hosts/macbookpro13-2019-t2/README.md` for the host-specific notes
and service choices.

## Smoke testing in QEMU

`./run.sh` boots the most-recently-built image in a QEMU VM. It defaults
to an **ephemeral** snapshot so the test run cannot mutate the image you
might later flash.

Common cases:

```bash
./run.sh                                 # boot the last devbox build
./run.sh --profile server --host cloudbox
./run.sh --persistent                    # keep writes across restarts
```

When a VM will not boot, the diagnostic flags are the first thing to
reach for. They are not production options — they exist specifically to
make a broken build show you why:

```bash
./run.sh --boot-nspawn    # skip firmware + bootloader + kernel + initrd;
                          # boots the root tree in systemd-nspawn. If
                          # this works and the regular VM does not, the
                          # root FS is fine and the break is in the
                          # boot chain.

./run.sh --debug          # serial console + mkosi --debug + verbose
                          # systemd + verbose udev. The first flag to
                          # reach for when an image builds but silently
                          # fails to boot.

./run.sh --serial         # serial/interactive console instead of the
                          # default GUI, so boot output scrolls into
                          # your terminal instead of a window that
                          # flashes and dies.

./run.sh --serial --kernel-arg systemd.unit=rescue.target
                          # drop straight to a rescue shell before
                          # multi-user.target fails something.

./run.sh --kernel-arg ARG --mkosi-arg ARG
                          # ad-hoc passthroughs, both repeatable
```

`mkosi summary` prints the resolved mkosi config for the current
working directory; it is the second-most-useful diagnostic after
`--boot-nspawn` when an image does not boot — confirm a `linux-image-*`
package is actually in the resolved `Packages=`.

See `docs/qemu-smoke-testing.md` for a longer triage walkthrough.

### Hardware-test USB for real-machine bring-up

After any successful build, turn the current version into a bootable
hardware-test USB that uses the same native retained-version stack as
the real install:

```bash
sudo ./scripts/write-live-test-usb.sh --target /dev/sdX \
     --profile macbook --host macbookpro13-2019-t2
```

That USB will:

- bootstrap itself with `systemd-repart` + `systemd-sysupdate`
- boot the exact version you just built
- include `/root/INSTALL-TO-INTERNAL-DISK.sh` so you can install to the
  machine's internal disk after you have tested the actual hardware

By default the USB bundle copies the current sysupdate artifacts rather
than the full `image.raw`, because the native install path only needs
the versioned root artifact, UKI, and BLS entry. Use
`--embed-full-image` only if you explicitly want the raw whole-disk
image copied onto the USB as well. If the installer bundle does not fit
on the default USB root partition, rerun with a larger removable drive
or increase the USB slot size with `--usb-root-size`.

For the T2 MacBook workflow this is the recommended next step before
touching the internal SSD. Boot the USB via Startup Manager, verify
Wi-Fi/Bluetooth/audio/sleep on real hardware, and only then run the
bundled installer against the internal disk.

See `docs/live-test-usb.md` for the full flow.

## User management

Local login users are defined in `.users.json` at the repo root. A
sample lives at `.users.json.sample`. If `.users.json` is missing,
`./build.sh` copies the sample on first run and asks you to edit it
before retrying.

Each entry is an object with one required field (`username`) and several
optional ones; see the `_notes` entry at the top of `.users.json.sample`
for the full schema.

**The sample ships `"password": "change-me-now"`** as a plaintext
password on the `demo` user. `build.sh` hashes plaintext `password`
fields at build time so a first `./build.sh && ./run.sh` produces a
working login for smoke testing. Change this before you flash anything
real.

### Pre-hashed passwords

For anything beyond a smoke test, prefer `password_hash` over plaintext:

```bash
./scripts/hash-password.sh                      # prints just the hash
./scripts/hash-password.sh --json --username demo --uid 1000
                                                # prints a full JSON entry
```

The script prompts twice (no echo), uses `mkpasswd` from the `whois`
package, prefers yescrypt, and never writes the password or the hash to
disk. Paste the result into `.users.json`.

A `password_hash` of `"!"` or `"*"` is a **lock marker** in
`/etc/shadow`, not a real hash. Setting it means the account cannot be
logged into with a password (pubkey SSH still works). That is the
correct thing for service accounts; it is not what you want for your
login user.

### Per-host users

If `hosts/<NAME>/users.json` exists, `./build.sh --host NAME` uses it
instead of the global `.users.json`. That lets a workstation and a
server share the same repo while keeping host-specific user sets — or a
different password for the shared login user — out of the global file.

### User IDs for shared mutable state

By default, `build.sh` copies the invoking host user's numeric
uid/gid/group into any `.users.json` entry whose `username` matches the
build host user. That is the safest default when you want ownership to
stay stable across retained-root updates.

You can also pin ids explicitly:

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

See `docs/user-provisioning.md` for the full first-boot behavior.

## QEMU sample home seed

`run.sh` defaults to an **ephemeral** VM and mounts
`runtime-seeds/qemu-home/` into the guest for the `devbox` and `macbook`
profiles.

On first boot the guest copies the sample files into the login user's
home only if the target paths do not already exist.

That gives you a smoke-test config in QEMU without baking personal host
config into the image that you would later flash or deploy.

## `/home` strategy

For real retained-root machines, keep mutable workstation data
**outside** the root image. That means `/home` should live on a separate
persistent partition or subvolume.

The preferred native layout is:

- a GPT `home` partition on the same disk as the retained root
  partitions for `/home`
- an optional partition labeled `DATA` for `/mnt/data`

The GPT `home` partition is auto-mounted by
`systemd-gpt-auto-generator`, and the image ships an `fstab` entry that
mounts `PARTLABEL=DATA` at `/mnt/data` with `nofail`, so the extra data
partition is optional and survives future retained-version updates
without per-slot manual edits.

For QEMU testing, the repo intentionally does **not** mount your real
host home by default. Instead it seeds a tiny sample AwesomeWM setup.
When you want to compare with host config, use runtime sharing
explicitly:

```bash
./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"
./run.sh --runtime-home
```

Use `--runtime-home` only for disposable tests.

See `docs/home-storage.md` for the storage trade-offs.

## Build output and sysupdate artifacts

`build.sh` pins `mkosi` to a single `ImageId` + `ImageVersion` for each
invocation and writes `mkosi.output/.latest-build.env` plus
per-profile/per-host metadata files such as
`mkosi.output/.latest-build.devbox.none.env`. `run.sh` reuses that
metadata, so `./build.sh` followed by `./run.sh` boots the image that
was just built instead of recalculating a fresh timestamped version. If
you pass `--profile` or `--host`, `run.sh` looks for the matching saved
build metadata for that specific combination.

`build.sh` produces two layers of output in `mkosi.output/`:

1. the usual `mkosi` build outputs such as
   `debian-provisioning_<VERSION>.raw`
2. versioned **sysupdate source artifacts** used by the golden-path
   updater

Current exported artifact names look like this:

```text
debian-provisioning_<VERSION>_<ARCH>.root.raw
debian-provisioning_<VERSION>_<ARCH>.efi
debian-provisioning_<VERSION>_<ARCH>.conf
```

The generated `.conf` file is a Boot Loader Specification entry that
references the matching UKI and supplies the root partition label plus
host-specific extra kernel arguments.

## Host-specific kernel arguments

GRUB-specific kernel flags are not required for this design.

Instead, host overlays can supply kernel arguments through
`hosts/<NAME>/kernel-cmdline.extra`. Those arguments are rendered into
the versioned Boot Loader Specification entry that gets installed by
`systemd-sysupdate`.

Current examples:

- `hosts/evox2/kernel-cmdline.extra`
- `hosts/cloudbox/kernel-cmdline.extra`

For the Ryzen AI Max desktop path this is where `amdgpu.gttsize=`
belongs.

## The native install/update flow

### One-time destructive bootstrap onto a blank or offline target

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
4. seeds the first retained version using `systemd-sysupdate` from
   `mkosi.output/`

### Hardware-test USB on a removable drive

For a real-machine smoke test before touching the internal disk, create
a removable USB install using the same native stack:

```bash
sudo ./scripts/write-live-test-usb.sh --target /dev/sdX
```

This is intentionally **not** a separate ad-hoc installer image. The USB
itself is bootstrapped with the same retained-version layout, and then
a self-contained installer bundle is copied into `/root/ab-installer`.
After booting from the USB you can run:

```bash
sudo /root/INSTALL-TO-INTERNAL-DISK.sh
```

The interactive helper can either:

- wipe a target disk and create a fresh retained-version layout
- or stage the bundled version onto an already bootstrapped target disk

By default, a fresh install from the USB creates:

- a 512M ESP
- two retained root partitions of 8G each
- a GPT `home` partition that takes the remaining space
- no `DATA` partition unless you ask for one

If you create a `DATA` partition, keep the partition label set to
`DATA` so the built-in `/mnt/data` mount entry continues to work on
later updates.

### Later in-place updates on an already bootstrapped machine

On a machine that is already running this layout:

```bash
sudo ./scripts/sysupdate-local-update.sh --source-dir ./mkosi.output --reboot
```

That stages the next version with `systemd-sysupdate` and reboots into
the new trial entry.

### Boot success and fallback

The image uses the native boot-complete path:

- a generated BLS entry is created with boot counters
- `systemd-boot` decrements tries on each boot attempt
- `ab-health-gate.service` runs before `boot-complete.target`
- if the health gate succeeds, `systemd-bless-boot.service` marks the
  entry good
- if the health gate never succeeds, the counted entry eventually falls
  behind the older good one and the system falls back to the older
  retained version

This is the key difference from the old bridge path: promotion/rollback
is done by the boot loader + systemd boot-complete pipeline, not by
custom ESP state files.

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

- `ab-status` shows the current root partition label, build metadata,
  health result, bootctl state, and installed sysupdate versions
- `ab-bless-boot` requests `boot-complete.target` so
  `systemd-bless-boot` can mark the current entry good
- `ab-mark-bad` marks the current counted entry bad immediately

## Cloudbox / Oracle ARM testing

The `cloudbox` overlay is intended for an ARM64 server-style machine
and uses serial-console-friendly kernel flags through
`hosts/cloudbox/kernel-cmdline.extra`.

This is the cleanest place to validate the modern path because:

- it removes the desktop stack from the equation
- you can rebuild and redeploy repeatedly
- you can test the retained-version flow before migrating a workstation

## Ansible

The playbook under `ansible/playbooks/cloudbox-ab-deploy.yml` follows
the native model. It can do either of two things:

1. **bootstrap mode** — destructively prepare a blank/offline target
   disk
2. **update mode** — build a new version and stage it with
   `systemd-sysupdate`

Bootstrap mode is for the first install only. Update mode is for all
later deployments.

See `ansible/README.md` and `ansible/group_vars/cloudbox.yml.example`.

## Liquorix notes

The `devbox` profile uses Liquorix on x86-64.

The `server` profile keeps Debian's stock kernel path. The ARM64
`cloudbox` overlay uses `linux-image-arm64`.

For the `devbox` profile we keep `dpkg` and `kmod` in the image and
disable mkosi package-metadata cleanup. That avoids a Debian/apt cleanup
edge case where purging `dpkg` can cause `kmod` auto-removal to fail
because `kmod` maintainer scripts call `dpkg-maintscript-helper`.

## Repo layout

- `mkosi.conf`, `mkosi.conf.d/`, `mkosi.profiles/` — base image
  definition and per-profile overrides
- `mkosi.sysupdate/` — native sysupdate transfer definitions
- `deploy.repart/` — one-time disk layout for bootstrap
- `hosts/<name>/` — per-machine overlays (`cloudbox`, `evox2`,
  `example-host`, `macbookpro13-2019-t2`)
- `scripts/bootstrap-ab-disk.sh` — destructive first install to a
  blank/offline target
- `scripts/sysupdate-local-update.sh` — later in-place updates on an
  installed system
- `scripts/write-live-test-usb.sh` — bootstraps a removable
  hardware-test USB and copies an installer bundle onto it
- `scripts/live-usb-install.sh` — interactive installer used from the
  booted hardware-test USB
- `scripts/export-sysupdate-artifacts.sh` — exports versioned
  root/UKI/BLS artifacts after build
- `scripts/hash-password.sh` — password hash helper for `.users.json`
- `scripts/ab-flash.sh` — legacy manual fallback, not the recommended
  path
- `docs/` — deeper dives referenced throughout this README
