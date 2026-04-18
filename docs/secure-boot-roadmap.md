# Secure Boot + RootVerity roadmap

The fixes and reliability bundles close the day-to-day security gaps.
What they do **not** do is stop a root-level attacker from planting
a persistent backdoor that survives rollback — because root can
modify the offline slot's rootfs image on disk, and on next boot
systemd-boot will load it.

Closing that gap is a three-part project. None of the parts can
land without physical access to each machine, so this bundle
ships the tooling but does not auto-enable anything.

## The target state

1. **Root image is hash-verified at every boot.** mkosi builds a
   dm-verity hash tree; the BLS entry passes the root hash to the
   kernel; initrd refuses to continue if the hash does not match.
   A tampered root partition fails boot.
2. **Kernel + initrd + cmdline are signed.** A tampered UKI fails
   signature verification in systemd-boot.
3. **systemd-boot itself is signed** by a key enrolled in the
   firmware's db, with the vendor-shipped Microsoft 3rd-party CA
   removed from db. A tampered bootloader fails firmware
   verification.
4. **/home and /mnt/data unlock via TPM** bound to the measured
   boot state. An attacker who replaces the kernel or initrd can
   no longer silently unlock the user's data, even with physical
   access.

Get all four working and "root can plant persistent malware" is no
longer cheap.

## Phase 1: RootVerity (rebuild time)

Add `mkosi.conf.d/90-verity.conf`:

```
[Output]
# Enables dm-verity hash partition generation during mkosi build.
Verity=signed

[Distribution]
# verity tools on the build host
Packages=
        systemd
        systemd-repart
        cryptsetup-bin
        veritysetup

[Content]
# Ensures fs is mounted read-only; verity requires it.
Bootable=yes
```

Add `mkosi.repart/05-verity-hash.conf`:

```
[Partition]
Type=root-verity
Format=verity
Minimize=guess
```

Modify the root partition to reference it:

```
# mkosi.repart/10-root.conf
[Partition]
Type=root
Format=ext4
Verity=hash
VerityMatchKey=root
# CopyFiles stays the same
```

mkosi writes the root hash into a BLS kernel cmdline variable
(`roothash=<hex>`) and the verity hash partition. The installer
(`systemd-sysupdate`) installs both partitions atomically.

**What breaks:** the root partition is read-only. Anything that
expected to write to `/etc` or `/usr/local` at runtime will fail.
The repo already puts mutable state under `/var` (tmpfs or
persistent) and `/home` (separate partition), so in practice most
things keep working. Double-check any first-boot scripts; the
`ab-user-provision.sh` we ship writes to `/var/lib` which is fine.

**What you give up:** hot-editing `/etc/ssh/sshd_config.d/foo.conf`
on a running host to fix a problem. That is already bad practice
and the mkosi + A/B model encourages you to do config changes via
rebuild + deploy, so in practice this is not a regression.

## Phase 2: UKI signing

Install `sbctl` on the build host:

```
apt-get install --no-install-recommends sbctl
```

One-time: generate a key for this project. Keep the private key on
a hardware token (YubiKey) if at all possible.

```
sudo sbctl create-keys
sudo sbctl enroll-keys --microsoft    # keeps MS CA for firmware compat
# --microsoft can be dropped on hosts where you are sure no firmware
# or option ROM needs MS-signed code (i.e. almost everything except
# server BMCs and some GPU option ROMs).
```

Tell mkosi to sign UKIs with your key. In `mkosi.conf.d/95-sb.conf`:

```
[Content]
SecureBoot=yes
SecureBootKey=/path/to/key
SecureBootCertificate=/path/to/cert

[Output]
UnifiedKernelImages=signed
```

The mkosi sysupdate artifacts will now contain signed UKIs. Until
the firmware has your key in db, they will fail verification — so
enroll first, flash second. See Phase 3.

## Phase 3: Firmware enrollment (physical access required)

This is per-machine, in firmware setup:

1. Boot once into firmware setup (F2 / F10 / Del at POST).
2. Set a firmware admin password. Without one, Secure Boot is
   advisory; an attacker who reaches the keyboard can disable it.
3. Clear the Secure Boot key database (the menu name varies:
   "Restore Factory Keys" → "Delete All" → "Custom Mode").
4. Boot back into the current (signed) image.
5. Run `sudo sbctl enroll-keys`. This pushes your key into db.
6. Reboot; confirm `sudo sbctl status` shows `enrolled`.

After this, the firmware enforces:
- bootloader signature valid → load
- UKI signature valid → execute
- kernel module signature valid → load

## Phase 4: TPM-bound /home and /mnt/data

The `ab-enroll-tpm-unlock` helper in this bundle does the LUKS
enrollment. You still need to:

1. LUKS-format the `/home` partition the first time:
   ```
   cryptsetup luksFormat /dev/disk/by-partlabel/home
   cryptsetup open /dev/disk/by-partlabel/home home
   mkfs.ext4 /dev/mapper/home
   ```
2. Set a strong recovery passphrase (kept in a password manager).
3. Enroll TPM:
   ```
   sudo ab-enroll-tpm-unlock /dev/disk/by-partlabel/home
   sudo ab-enroll-tpm-unlock /dev/disk/by-partlabel/DATA
   ```
4. Add crypttab entries for auto-unlock at boot.

PCR selection: we bind to PCRs 0+2+7 (firmware + option ROMs +
Secure Boot policy). We do NOT bind to PCR 11 (UKI) because every
sysupdate would change it and require re-enrollment.

## Recovery paths

Every step above must have a break-glass path:

| Failure                               | Recovery                                          |
|---------------------------------------|---------------------------------------------------|
| Verity root hash mismatch             | A/B rollback to previous slot                     |
| UKI signature mismatch                | A/B rollback                                      |
| Both slots fail signature             | Boot live-test USB, reinstall                     |
| TPM refuses to release LUKS key       | Boot, type the recovery passphrase                |
| Lost LUKS passphrase AND TPM refuses  | Data is gone; restore from offsite backup         |
| Lost sbctl private key                | Use live USB to enroll a new key in firmware db   |
| YubiKey lost (SSH + U2F-sudo enrolled)| Use the second enrolled YubiKey; you DID enroll two, right? |

The last row is important. Never enroll just one.

## When to do each phase

- **Phase 1 (RootVerity)**: worth doing soon. One rebuild. No
  new hardware dependency. Large attacker-effort increase.
- **Phase 2 (UKI signing)**: same rebuild as Phase 1. Needs sbctl
  on the build host, private key handling.
- **Phase 3 (firmware enrollment)**: physical trip per machine.
  Do it once per host and never again unless firmware is reset.
- **Phase 4 (TPM-bound data)**: per host; requires LUKS reformat
  of /home unless it is already encrypted. Plan for downtime.

You do not need to do all four to get most of the benefit. RootVerity
+ UKI signing + Phase 3 gets you most of the way. TPM-bound data
is the final upgrade.
