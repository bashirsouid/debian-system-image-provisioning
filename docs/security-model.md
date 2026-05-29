# Security model

This document describes the trust chain built into every image produced
by this project.

## Image integrity — Secure Boot signed UKIs

mkosi produces a single Unified Kernel Image (UKI) per build, which
bundles the kernel, initrd, and kernel command line into one signed
PE binary. When Secure Boot is enabled for a host, mkosi signs the
UKI with the RSA-4096 key in `.secureboot/db.key`. The firmware
refuses to execute a UKI whose signature does not match a key enrolled
in UEFI `db`, so an attacker with root on the running system cannot
replace the UKI and survive a reboot.

Secure Boot is required for every host-targeted build. A build with
`--host <name>` fails unless either:

* `hosts/<name>/mkosi.conf.d/30-secure-boot.conf` configures signing
  and `.secureboot/` contains the signing key and certificate, or
* `hosts/<name>/secure-boot.disabled` exists with a reason that is
  printed on every build of that host.

QEMU smoke tests (`./build.sh` without `--host`) do not require Secure
Boot — they exercise image contents, not the boot-trust chain, and are
never flashed. Host-built signed images also boot under `./run.sh`
without additional setup, because mkosi's VM firmware does not enforce
Secure Boot by default; the signature is carried but not verified. To
end-to-end test Secure Boot enforcement in QEMU (reject a tampered UKI),
add `SecureBootAutoEnroll=yes` and `[Runtime] Firmware=uefi-secure-boot`
to the host's drop-in — see `docs/secure-boot.md`.

UKI-only boot (no separate `vmlinuz` + `initrd` pair) keeps the
signature scope simple: the firmware verifies exactly one artifact per
version, and the kernel command line — which would otherwise be an
unauthenticated attack surface — is part of the signed blob.

See `docs/secure-boot.md` for enrollment steps and key rotation.

## Credential confidentiality — LUKS full disk encryption

The root partition is encrypted with LUKS2. During the build, you are
prompted to type a passphrase interactively — the passphrase is held
only in `/dev/shm/` (RAM-backed tmpfs) for the duration of the build
and is never written to persistent storage.

Per-host secrets (Tailscale auth keys, cloudflared tokens, PagerDuty
tokens, SSH authorized_keys) are placed as plaintext into
`/etc/credstore/` inside the encrypted root partition. Services load
them via systemd's `LoadCredential=` directive, which securely isolates
the credential into a hidden per-service tmpfs at runtime.

The security model:

* **At rest**: the entire root partition is LUKS2-encrypted. An attacker
  who steals the drive or USB stick gets ciphertext.
* **At runtime**: credentials are loaded into isolated per-service tmpfs
  mounts. A compromised web server process cannot read another service's
  credentials, even if it achieves arbitrary file read.
* **On baremetal (production)**: after the first passphrase-unlocked
  boot, run `sudo ab-enroll-tpm` to bind the LUKS volume to the hardware
  TPM. Subsequent boots auto-unlock without typing a password, and the
  drive becomes unreadable if moved to a different machine.
* **In QEMU (development)**: the VM prompts for the LUKS passphrase on
  every boot. If `swtpm` is available, `ab-enroll-tpm` can bind to the
  virtual TPM for auto-unlock during development too.

This design intentionally avoids using `systemd-creds encrypt` at build
time. The build host's `systemd-creds` binds encryption to the host's
own machine-id/TPM, making credentials unreadable inside the target VM
or baremetal host. LUKS encryption of the entire partition provides
strictly superior at-rest protection without portability issues.

## Rollback — boot counting

`systemd-boot` decrements a `tries` counter on each boot attempt of a
Boot Loader Specification entry. `ab-health-gate.service` runs before
`boot-complete.target`, and on success `systemd-bless-boot.service`
marks the entry good. If the health gate never succeeds, the counted
entry exhausts its tries and the firmware boots the older retained
version instead.

Retention is provided by `systemd-sysupdate`'s `InstancesMax=2`: one
currently booted known-good version, one newer trial version, with
automatic fallback when the trial fails to become healthy.

## Package trust

Every Debian package is verified by apt against the Debian archive
signing keys during install, regardless of cache state. Packages are
pulled from a pinned `snapshot.debian.org` timestamp in
`mkosi.conf.d/15-reproducibility.conf`, so "reproducible build" and
"up-to-date security patches" are controlled by a single deliberate
version bump of that timestamp rather than being in tension.

Third-party repositories (Liquorix for the `devbox` profile, t2linux
plus Apple Firmware for the `macbook` profile) are consumed with
explicit `signed-by` keyrings. Keyrings are fetched fresh by
`update-3rd-party-deps.sh` rather than committed.

## Identity — generated, not baked

Per-machine identity files must be generated at first boot.
`scripts/verify-no-baked-identity.sh` runs from `build.sh` and fails
the build if any of these are tracked under `mkosi.extra/` or
`hosts/*/mkosi.extra/`:

* `**/etc/ssh/ssh_host_*` (private or public)
* non-empty `**/etc/machine-id` or `**/var/lib/dbus/machine-id`
  (zero-byte is allowed; it is the documented systemd first-boot marker)
* `**/var/lib/systemd/random-seed`
* `**/etc/hostid`

This is enforced on every build, not just initial setup.

## What's committed vs. generated

Committed to the repository:

* `.users.json.sample` — reference only. `.users.json` with real
  credentials is gitignored. The preferred approach is to put users in
  the secrets file instead; see `docs/user-provisioning.md`.
* `secrets/mkosi-secrets.example.json` — example schema for the secrets
  vault. Real encrypted vault files are named `secrets/*.json.age`;
  plaintext `secrets/*.json` files are gitignored.
* `.mkosi-secrets.example/` — (if present) documents the expected
  directory layout. The actual `.mkosi-secrets/` is gitignored and
  validated by `scripts/verify-build-secrets.sh`, which also
  cross-checks with `git ls-files` to refuse if anything under
  `.mkosi-secrets/` ever gets tracked.

Generated locally and gitignored:

* `.secureboot/` — UKI signing key, certificate, and enrollment blobs
* `mkosi.pkgcache/`, `mkosi.cache/`, `mkosi.builddir/` — build caches
* `mkosi.output/` — build artifacts
* `.mkosi-secrets/` — build-time plaintext secret staging area
