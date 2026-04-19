# mkosi image provisioning

Builds Debian images with `mkosi` and deploys them with the native
systemd update stack: `systemd-repart` for the initial disk layout,
`systemd-sysupdate` for versioned root and boot artifact installs,
`systemd-boot` with boot counting and `systemd-bless-boot` for
automatic rollback, signed Unified Kernel Images under Secure Boot
(per-host opt-in), and an encrypted credential store bound to
per-image key material.

## What this provides

* reproducible base images pinned to a `snapshot.debian.org` timestamp
* source-built AwesomeWM for the `devbox` and `macbook` profiles
* first-boot local user provisioning from a committed `.users.json`
* Liquorix kernel for the x86-64 `devbox` path
* a T2-oriented `macbook` profile for Intel 2019-era MacBook Pros
* retained-version root updates with `systemd-sysupdate`
* a server-only ARM64 `cloudbox` overlay
* an Ansible playbook that can bootstrap or update `cloudbox`
* a hardware-test USB workflow that boots the same retained-version
  stack on removable media
* Secure Boot UKI signing with a locally-generated key, opt-in per host
* preflight audits for baked-in identity, sample-password sentinel,
  and `.mkosi-secrets/` shape

## Assumptions

* UEFI only
* `systemd-boot` is the bootloader
* the first install onto a target disk is destructive and expects a
  blank or offline target
* later updates are in-place via `systemd-sysupdate`
* the initial bootstrap creates one ESP and two root partitions
* host-specific kernel flags live in Boot Loader Specification entries
* the `cloudbox` path is server-only — no desktop stack, no AwesomeWM,
  no Liquorix
* the `macbook` path uses third-party T2 support packages and firmware
  repos during the build

## Security architecture

The pieces compose into a single trust chain. Each piece below is the
current behavior; rationale explains why it is the way it is.

### Image integrity — Secure Boot signed UKIs

mkosi produces a single Unified Kernel Image (UKI) per build, which
bundles the kernel, initrd, and kernel command line into one signed
PE binary. When Secure Boot is enabled for a host, mkosi signs the
UKI with the RSA-4096 key in `.secureboot/db.key`. The firmware
refuses to execute a UKI whose signature does not match a key
enrolled in UEFI `db`, so an attacker with root on the running
system cannot replace the UKI and survive a reboot.

Secure Boot is the default for every host-targeted build. A build
with `--host X` fails unless either:

* `hosts/X/mkosi.conf.d/30-secure-boot.conf` configures signing and
  `.secureboot/` contains the signing key and certificate, or
* `hosts/X/secure-boot.disabled` exists with a reason that is
  printed during every build of that host.

Current state:

* `evox2` (Intel workstation): Secure Boot enabled. Enroll via UEFI
  Setup Mode.
* `cloudbox` (Oracle Ampere A1): Secure Boot enabled. Enroll via
  Shielded Instance options.
* `macbookpro13-2019-t2`: Secure Boot disabled via
  `hosts/macbookpro13-2019-t2/secure-boot.disabled`. The T2 chip's
  own boot verification sits ahead of UEFI and the community
  workaround for Linux on T2 requires disabling it, which removes
  the hardware root of trust. Standard UEFI SB on top of that path
  provides no meaningful protection.

QEMU smoke tests (`./build.sh` with no `--host`) do not require
Secure Boot — they exercise image contents, not the boot-trust
chain, and are never flashed. Host-built *signed* images also boot
under `./run.sh` without additional setup, because mkosi's VM
firmware does not enforce Secure Boot by default; the signature is
carried but not verified. To end-to-end test SB enforcement in QEMU
(reject a tampered UKI), add `SecureBootAutoEnroll=yes` and
`[Runtime] Firmware=uefi-secure-boot` to the host's drop-in — see
`docs/secure-boot.md`.

UKI-only boot (no separate `vmlinuz` + `initrd` pair) keeps the
signature scope simple: the firmware verifies exactly one artifact
per version, and the kernel command line — which would otherwise be
an unauthenticated attack surface — is part of the signed blob.

See `docs/secure-boot.md` for enrollment steps and key rotation.

### Credential confidentiality — per-image key

Per-host secrets (Tailscale auth keys, cloudflared tokens, PagerDuty
tokens, SSH authorized_keys) are encrypted at build time with
`systemd-creds` against a random 32-byte `credential.secret` that is
unique to each built image and stored under `/var/lib/systemd/`
inside that image. Encrypted blobs land in `/etc/credstore.encrypted/`
and services load them via `LoadCredentialEncrypted=`.

The security property: an encrypted blob is only useful inside the
specific image it was built with. Extracting the blob without the
image yields nothing; the image and the blob must travel together.

This intentionally does not use TPM2 sealing (`systemd-creds
--with-key=tpm2`). TPM sealing binds decryption to specific PCR
values on specific hardware, which forces building on each target
machine or precomputing a PCR policy per host. For a cross-built
image shipped to three different machines (Intel workstation, T2
MacBook, ARM cloud), the per-image-key scheme gives equivalent
protection because Secure Boot already prevents tampering with the
image between build and first boot. Once the UKI is verified, the
image's own `credential.secret` is as trustworthy as the signed root
it lives in.

### Rollback — boot counting

`systemd-boot` decrements a `tries` counter on each boot attempt of
a Boot Loader Specification entry. `ab-health-gate.service` runs
before `boot-complete.target`, and on success
`systemd-bless-boot.service` marks the entry good. If the health
gate never succeeds, the counted entry exhausts its tries and the
firmware boots the older retained version instead.

Retention is provided by `systemd-sysupdate`'s `InstancesMax=2`:
one currently booted known-good version, one newer trial version,
automatic fallback when the trial fails to become healthy.

### Package trust

Every Debian package is verified by apt against the Debian archive
signing keys during install, regardless of cache state. Packages
are pulled from a pinned `snapshot.debian.org` timestamp in
`mkosi.conf.d/15-reproducibility.conf`, so "reproducible build"
and "up-to-date security patches" are controlled by a single
deliberate version bump of that timestamp rather than being in
tension.

Third-party repositories (Liquorix for `devbox`, t2linux plus Apple
Firmware for `macbook`) are consumed with explicit `signed-by`
keyrings. Keyrings are fetched fresh by `update-3rd-party-deps.sh`
rather than committed.

### Identity — generated, not baked

Per-machine identity files must be generated at first boot.
`scripts/verify-no-baked-identity.sh` runs from `build.sh` and
fails the build if any of these are tracked under `mkosi.extra/`
or `hosts/*/mkosi.extra/`:

* `**/etc/ssh/ssh_host_*` (private or public)
* non-empty `**/etc/machine-id` or `**/var/lib/dbus/machine-id`
  (zero-byte is allowed; it is the documented systemd first-boot
  marker)
* `**/var/lib/systemd/random-seed`
* `**/etc/hostid`

This is enforced on every build, not just initial setup.

### What's committed vs generated

Committed:

* `.users.json.sample` — reference only. `.users.json` with real
  passwords is gitignored. The build refuses if the sample
  `change-me-now` sentinel password is still present (override
  with `AB_ALLOW_SAMPLE_PASSWORD=yes` for throwaway tests).
* `.mkosi-secrets.example/` — documentation of the expected layout.
  `.mkosi-secrets/` itself is gitignored and validated by
  `scripts/verify-build-secrets.sh`, which also cross-checks with
  `git ls-files` to refuse if anything under `.mkosi-secrets/` ever
  gets tracked.

Generated locally and gitignored:

* `.secureboot/` — UKI signing key, certificate, and enrollment blobs
* `mkosi.pkgcache/`, `mkosi.cache/`, `mkosi.builddir/` — build caches
* `mkosi.output/` — build artifacts

## Per-host defaults

Each directory under `hosts/<n>/` may contain a `profile.default`
file with a single profile name (`server`, `devbox`, `macbook`).
When `./build.sh --host <n>` runs without `--profile`, this file
determines which profile builds. `--profile` on the command line
always overrides.

Current defaults:

* `hosts/cloudbox/profile.default` → `server`
* `hosts/evox2/profile.default` → `devbox`
* `hosts/macbookpro13-2019-t2/profile.default` → `macbook`

## Caching

Three cache layers live under the repo root and are gitignored:

* `mkosi.pkgcache/` — downloaded `.deb` files. Partitioned internally
  by (distribution, release, architecture), so amd64 `devbox` builds
  and arm64 `cloudbox` builds coexist without interfering. Avoids
  re-downloading packages on every build.
* `mkosi.cache/` — incremental rootfs snapshots after package unpack,
  keyed on the package list. Bypasses the unpack step on rebuild.
* `mkosi.builddir/` — persistent scratch for `mkosi.build` (ccache,
  meson, cmake for AwesomeWM and the T2 audio driver).

`./build.sh --clean` maps to `mkosi -f -f` and clears the incremental
cache. Drop `mkosi.pkgcache/` manually for a fully cold rebuild.

Every cache is safe to keep between builds: packages are
cryptographically verified on install regardless of cache state,
and the incremental cache's key includes all relevant inputs.

## Build output

`build.sh` pins `mkosi` to a single `ImageId` + `ImageVersion` per
invocation and writes `mkosi.output/.latest-build.env` plus
per-profile/per-host metadata files. `run.sh` reuses that metadata,
so `./build.sh` followed by `./run.sh` boots the image just built.

When the config checksum is unchanged from the previous build,
`IMAGE_VERSION` is reused from `.config-version`. This stops
`mkosi.output/` from accumulating a fresh `.raw`/`.efi`/`.conf`
set on every invocation. Override with `AB_FORCE_NEW_VERSION=yes`
or `AB_IMAGE_VERSION=<string>`.

Exported sysupdate source artifacts per build:

    debian-provisioning_<VERSION>_<ARCH>.root.raw
    debian-provisioning_<VERSION>_<ARCH>.efi
    debian-provisioning_<VERSION>_<ARCH>.conf

The `.conf` is a Boot Loader Specification entry referencing the
matching UKI and supplying the root partition label plus
host-specific extra kernel arguments. When Secure Boot is enabled
for the host, the `.efi` is signed with `.secureboot/db.key`.

## Host dependency auto-install

The repo scripts auto-install missing host-side tools on Debian and
Ubuntu build or deploy machines before they fail, so `./build.sh`,
`./run.sh`, `./clean.sh`, `./scripts/bootstrap-ab-disk.sh`, and
`./scripts/sysupdate-local-update.sh` behave like project
entrypoints.

* auto-install is enabled by default
* scripts use `apt-get install --no-install-recommends` and `sudo`
  when needed
* set `AB_AUTO_INSTALL_DEPS=no` for a manual install hint instead
* if the required commands already exist, nothing is installed

On Debian trixie `sfdisk` comes from the `fdisk` package, `jq` is
its own package, and the native update path requires
`systemd-repart`, `systemd-sysupdate`, and the systemd-boot tooling.

    ./build.sh --profile devbox
    AB_AUTO_INSTALL_DEPS=no ./build.sh --host cloudbox

## Quick start

### Desktop/devbox smoke test in QEMU

    ./update-3rd-party-deps.sh
    cp .users.json.sample .users.json
    $EDITOR .users.json                 # set a real password
    ./clean.sh --all
    ./build.sh --profile devbox
    ./run.sh

On first boot the image provisions local users from embedded data
and removes the user seed file. Log in and run `startx`, or
`STARTX_RESOLUTION=1920x1080 startx` for a different X resolution.

### ARM64 cloudbox build

    cp .users.json.sample .users.json
    $EDITOR .users.json
    ./clean.sh --all
    ./build.sh --host cloudbox

The cloudbox host overlay forces `Architecture=arm64`, uses Debian's
stock `linux-image-arm64`, and stays server-only. Its
`profile.default` selects the `server` profile.

### Intel T2 MacBook Pro build

    ./update-3rd-party-deps.sh
    cp .users.json.sample .users.json
    $EDITOR .users.json
    ./clean.sh --all
    ./build.sh --host macbookpro13-2019-t2

This path uses the t2linux kernel, keeps PipeWire on Debian's default
stack, installs Apple Wi-Fi/Bluetooth firmware and the T2 kernel
packages, builds and installs the `snd_hda_macbookpro` CS8409 driver
override into the image at build time, uses NetworkManager with
Debian's `network-manager-iwd` integration, and enables a suspend
workaround for the Apple T2 / Broadcom module stack.

Current limits:

* Bluetooth is partially working on some T2 models; BCM4377 has
  interference issues on 2.4 GHz Wi-Fi
* the trackpad works but is not as good as on macOS
* experimental speaker DSP tuning is only available for the 16-inch
  2019 MacBook Pro
* hibernation is not configured in this retained-version layout
  (swap + resume wiring is pending)

See `hosts/macbookpro13-2019-t2/README.md` for host-specific notes.

### Hardware-test USB

After a successful build, turn the current version into a bootable
hardware-test USB:

    sudo ./scripts/write-live-test-usb.sh --target /dev/sdX --host macbookpro13-2019-t2

The USB bootstraps itself with `systemd-repart` +
`systemd-sysupdate`, boots the exact version just built, and
includes `/root/INSTALL-TO-INTERNAL-DISK.sh` for installing to the
machine's internal disk after hardware verification.

By default the USB bundle copies the current sysupdate artifacts
rather than the full `image.raw`. Use `--embed-full-image` to copy
the raw whole-disk image as well. Use a larger drive or pass
`--usb-root-size` if the bundle does not fit.

See `docs/live-test-usb.md` for the full flow.

## Configuration

### User IDs for shared mutable state

`build.sh` copies the invoking host user's numeric uid/gid/group
into any `.users.json` entry whose `username` matches the build
host user, which keeps ownership stable across retained-root
updates when mounting personal home data.

Pin IDs explicitly:

    [
      {
        "username": "demo",
        "password_hash": "...",
        "can_login": true,
        "uid": 1000,
        "gid": 1000,
        "primary_group": "demo"
      }
    ]

Disable automatic host-ID syncing:

    ./build.sh --profile devbox --sync-host-ids=no

### /home strategy

Mutable workstation data lives outside the root image. The supported
layout is a GPT `home` partition on the same disk as the retained
root partitions (auto-mounted by `systemd-gpt-auto-generator`) plus
an optional partition labeled `DATA` mounted at `/mnt/data` via the
image's `fstab` with `nofail`, so the data partition is optional and
survives retained-version updates without per-slot edits.

For QEMU testing, the repo does not mount the host home by default —
instead it seeds a tiny sample AwesomeWM setup. To compare with host
config, use runtime sharing explicitly:

    ./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"
    ./run.sh --runtime-home    # disposable tests only

See `docs/home-storage.md` for the storage trade-offs.

### Host-specific kernel arguments

Host overlays supply kernel arguments through
`hosts/<n>/kernel-cmdline.extra`. These render into the versioned
Boot Loader Specification entry installed by `systemd-sysupdate`.
Examples: `hosts/evox2/kernel-cmdline.extra`,
`hosts/cloudbox/kernel-cmdline.extra`.

### QEMU sample home seed

`run.sh` defaults to an ephemeral VM and mounts
`runtime-seeds/qemu-home/` into the guest for the `devbox` profile.
On first boot the guest copies the sample files into the login
user's home only if the target paths do not already exist.

## Install and update flow

### One-time destructive bootstrap

Build:

    ./build.sh --host cloudbox

Bootstrap a target disk or raw disk image:

    sudo ./scripts/bootstrap-ab-disk.sh --target /dev/sdX

This destroys the target partition table, creates the ESP and two
empty root partitions with `systemd-repart`, installs `systemd-boot`
into the target ESP, and seeds the first retained version using
`systemd-sysupdate` from `mkosi.output/`.

### Later in-place updates

On a machine already running this layout:

    sudo ./scripts/sysupdate-local-update.sh --source-dir ./mkosi.output --reboot

This stages the next version with `systemd-sysupdate` and reboots
into the new trial entry.

### Health checks

The boot health gate waits `AB_HEALTH_DELAY_SECS` seconds after
boot, fails if there are failed systemd units, and runs any
executable hooks in `/usr/local/libexec/ab-health-check.d`. Status
is recorded in `/var/lib/ab-health/status.env`.

Installed system commands:

* `ab-status` — current root partition label, build metadata,
  health result, `bootctl` state, installed sysupdate versions
* `ab-bless-boot` — requests `boot-complete.target` so
  `systemd-bless-boot` marks the current entry good
* `ab-mark-bad` — marks the current counted entry bad immediately

## Cloudbox / Oracle ARM

The `cloudbox` overlay targets ARM64 server-style machines and uses
serial-console-friendly kernel flags via
`hosts/cloudbox/kernel-cmdline.extra`. Because it has no desktop
stack it's the fastest loop for validating the retained-version
flow before migrating a workstation.

## Ansible

`ansible/playbooks/cloudbox-ab-deploy.yml` supports two modes:

1. **bootstrap** — destructively prepare a blank/offline target disk
2. **update** — build a new version and stage it with
   `systemd-sysupdate`

Bootstrap mode is for the first install only. Update mode is for
all later deployments. See `ansible/README.md` and
`ansible/group_vars/cloudbox.yml.example`.

## Liquorix

The `devbox` profile uses Liquorix on x86-64. The `server` profile
keeps Debian's stock kernel. The ARM64 `cloudbox` overlay uses
`linux-image-arm64`.

For the `devbox` profile `dpkg` and `kmod` stay in the image and
mkosi package-metadata cleanup is disabled, because purging `dpkg`
can cause `kmod` auto-removal to fail: `kmod` maintainer scripts
call `dpkg-maintscript-helper`.

## Repo layout

* `mkosi.sysupdate/` — sysupdate transfer definitions
* `deploy.repart/` — one-time disk layout for bootstrap
* `scripts/bootstrap-ab-disk.sh` — destructive first install
* `scripts/sysupdate-local-update.sh` — in-place updates
* `scripts/write-live-test-usb.sh` — hardware-test USB bootstrap
* `scripts/live-usb-install.sh` — interactive installer run from USB
* `scripts/export-sysupdate-artifacts.sh` — exports versioned
  root/UKI/BLS artifacts after build
* `scripts/generate-secureboot-keys.sh` — local SB key + cert
  generator
* `scripts/verify-no-baked-identity.sh` — preflight audit for
  baked-in per-machine files
* `scripts/verify-build-secrets.sh` — preflight audit for
  `.mkosi-secrets/` shape and permissions
* `scripts/package-credentials.sh` — encrypt per-host secrets into
  the image's credstore
* `hosts/cloudbox/` — ARM64 server overlay
* `hosts/evox2/` — Intel workstation overlay
* `hosts/macbookpro13-2019-t2/` — Intel T2 MacBook Pro overlay
* `hosts/example-host/` — host overlay template
* `docs/secure-boot.md` — Secure Boot enrollment per host
* `docs/live-test-usb.md` — hardware-test USB workflow
* `docs/home-storage.md` — /home layout trade-offs
