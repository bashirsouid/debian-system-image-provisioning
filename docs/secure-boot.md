# Secure Boot

This doc covers the current Secure Boot design, how to enroll keys
per host type, how to opt a host out when the hardware cannot
support SB, and how this interacts with QEMU testing.

## What SB protects against

`systemd-sysupdate` + `systemd-boot` provides versioned root images,
boot counting, automatic rollback, and an encrypted credstore. None
of that is rooted in hardware trust on its own: an attacker with
root on a running image can modify the UKI in the ESP, swap
`credential.secret`, or install a rogue retained-version slot, and
on next boot the firmware will cheerfully execute whatever it finds.

Secure Boot closes that gap. The firmware verifies the UKI's RSA
signature against a key enrolled in the UEFI variable `db` before
transferring control. Combined with the existing stack, a compromised
running system can still do damage while it runs, but it cannot plant
something that survives a reboot without breaking the signature chain.

## Opt-out model

Secure Boot is the default for every host-targeted build. When
`./build.sh --host X` runs, it requires one of:

* `hosts/X/mkosi.conf.d/30-secure-boot.conf` pointing mkosi at the
  signing key, plus `.secureboot/db.key` and `.secureboot/db.crt`
  present on disk — mkosi signs the UKI, the build proceeds normally.
* `hosts/X/secure-boot.disabled` — a text file whose contents
  document why SB is off. `build.sh` prints the reason on every
  build so the exception stays visible in logs.

A host with neither fails the build. There is no silent-fallback
path; silently producing an unsigned image was the bug the opt-out
model exists to prevent.

No-host builds (`./build.sh` with no `--host`) are exempt. These are
QEMU smoke tests that exercise image contents, not the boot-trust
chain, and never get flashed.

## What the repo does

* `scripts/generate-secureboot-keys.sh` generates a local RSA-4096
  signing key + self-signed X.509 cert in `.secureboot/`.
* `.secureboot/` is gitignored.
* `hosts/<n>/mkosi.conf.d/30-secure-boot.conf` points mkosi at the
  key/cert so it signs the UKI at build time.
* `build.sh` refuses to build a `--host X` target unless SB is
  configured (and the keys exist) or `hosts/X/secure-boot.disabled`
  is present.

The repo does NOT do:

* TPM2 sealing of the credstore. The design uses per-image random
  keys with `systemd-creds --host-key-path=`, which is appropriate
  for cross-machine builds. TPM binding would require building on
  the target or pre-computing a PCR policy per host; that's a lot
  of complexity for small marginal gain once the UKI is signed.
* shim + MOK. Keys go directly into UEFI `db`. This means no
  dependency on a Microsoft-signed pre-boot component and no shim
  revocation story.
* PK / KEK management. The key generator produces a `db`-level key
  only. On a machine in UEFI Setup Mode you can import it directly;
  on a machine with OEM PK/KEK still in place you'll need to put it
  into setup mode first (clear OEM keys) or chain-enroll via KEK.

## One-time build-host setup

```
apt-get install openssl sbsigntool efitools
./scripts/generate-secureboot-keys.sh
```

Files produced under `.secureboot/`:

```
db.key    # private key — mode 0600
db.crt    # X.509 self-signed cert
db.esl    # EFI Signature List (firmware-friendly)
db.auth   # authenticated EFI variable update blob
db.guid   # GUID used inside db.esl / db.auth
```

**Back up `db.key` offline.** If you lose it, every already-enrolled
machine needs re-enrollment and any image you have in the field can
no longer be updated by a rebuild. A USB stick in a drawer is fine.
A synced cloud folder is not.

## Per-host enrollment

### evox2 — Intel workstation

1. Reboot into UEFI setup.
2. Enter Setup Mode / Custom Secure Boot mode (varies by vendor —
   typically "Clear Secure Boot keys" or "Enroll custom keys").
3. Save `.secureboot/db.crt` or `.secureboot/db.auth` to a FAT32
   USB stick.
4. From the firmware's Secure Boot menu, enroll the db key from
   the USB stick ("Append key to db" / "Enroll signature from file").
5. Exit Setup Mode, enable Secure Boot, save, reboot.
6. Rebuild with `./build.sh --host evox2` and deploy via sysupdate.

If the firmware refuses to boot after enrollment, the symptom is a
"Security Policy Violation" or similar before the bootloader appears.
Fallback: boot a hardware-test USB, roll back via sysupdate, debug.

### cloudbox — Oracle Ampere A1 / similar ARM cloud

Oracle's "Shielded Instance" flow is the enrollment path.

1. OCI console, Launch page → Show advanced options → Security →
   enable Shielded Instance → Secure Boot.
2. Upload the contents of `.secureboot/db.crt` converted to DER:
   `openssl x509 -in .secureboot/db.crt -outform der -out db.der`.
3. Launch or reconfigure an existing instance's shielded config.
4. Rebuild+deploy with `./build.sh --host cloudbox`.

For other ARM clouds / bare-metal boards, check the vendor docs
before assuming Secure Boot works at all — a fair number of ARM
firmwares either don't implement the UEFI SB chain or implement it
with vendor-pinned keys you can't replace.

### macbookpro13-2019-t2 — T2 Intel MacBook

Secure Boot is disabled via `hosts/macbookpro13-2019-t2/secure-boot.disabled`.
The T2 chip runs its own boot verification before UEFI, and the
community workaround for Linux on T2 requires disabling it, which
removes the real hardware root of trust. Standard UEFI SB on top
provides no meaningful protection.

When T2 support matures, remove the opt-out file, add a SB drop-in
under `hosts/macbookpro13-2019-t2/mkosi.conf.d/`, and rebuild.

### Adding a new host

A new host entry under `hosts/<n>/` must include either the SB
drop-in or `secure-boot.disabled` at creation time — otherwise the
first build for that host fails with a clear error pointing at
both options. See `hosts/example-host/` as a starting template.

## Verifying a signed UKI

```
sbverify --cert .secureboot/db.crt \
  mkosi.output/debian-provisioning_<VERSION>_<ARCH>.efi
```

`Signature verification OK` means the UKI is properly signed and
will be accepted by any firmware with the matching key in db.

## QEMU and signed images

Signed images produced by `./build.sh --host <enabled-host>` boot
under `./run.sh` without any extra steps. This is intentional: mkosi
launches QEMU with non-SB-enforcing OVMF firmware by default, so the
UKI signature is just metadata that the firmware carries but doesn't
verify. The image is the same bits as the one flashed to hardware.

You do **not** need to:

* temporarily disable Secure Boot in the drop-in to debug in QEMU
* generate QEMU-specific images
* enroll the signing key into an OVMF variables file for normal runs

### Testing SB enforcement end-to-end in QEMU

If you want to verify that a tampered UKI actually gets rejected —
the full chain, not just "it boots" — enable SB enforcement in the
VM. Add to the host's SB drop-in:

```ini
[Validation]
SecureBootAutoEnroll=yes

[Runtime]
Firmware=uefi-secure-boot
FirmwareVariables=custom
```

`SecureBootAutoEnroll=yes` makes systemd-boot auto-enroll the
signing key when it detects UEFI Setup Mode on first boot (which is
how QEMU comes up by default). `FirmwareVariables=custom` tells
mkosi to hand QEMU an OVMF variables file with the certificate
pre-enrolled. `Firmware=uefi-secure-boot` selects the SB-enforcing
OVMF binary.

After that, `./run.sh --host <host>` boots with full SB enforcement
and rejects a UKI that fails signature verification. Revert by
removing those three lines; there's no reason to leave them on for
routine use.

## Key rotation

1. `./scripts/generate-secureboot-keys.sh --force` (copy
   `.secureboot/` to `.secureboot-old/` first if you want both keys
   active during the transition).
2. Rebuild and deploy new images to every host while the OLD key is
   still enrolled — these still boot, because the old key also
   signed them.
3. Enroll the new key on every host while keeping the old key
   enrolled.
4. Once every host boots the new-key images, remove the old key from
   each host's db.

`--force` currently overwrites in place. A first-class `rotate`
verb that manages the `.secureboot-old/` staging would be a
reasonable next improvement.
