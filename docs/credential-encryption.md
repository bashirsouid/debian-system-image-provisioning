# Credential & Encryption Architecture

This document explains how secrets are protected in images built by
this project, both at rest and at runtime.

## Overview

```
Build Host                       Target Machine (QEMU or Baremetal)
──────────                       ──────────────────────────────────
                                 ┌─────────────────────────────────┐
  ./build.sh --host evox2        │  ESP (unencrypted, FAT32)       │
  ├─ prompts for LUKS passphrase │  └─ systemd-boot + UKI          │
  ├─ copies secrets as plaintext │  ┌─────────────────────────────────┐
  │  into /etc/credstore/        │  │  Root Partition (LUKS2)         │
  └─ mkosi builds .raw with     │  │  ├─ /etc/credstore/             │
     LUKS2-encrypted root        │  │  │   ├─ tailscale-authkey       │
                                 │  │  │   ├─ cloudflared-token       │
                                 │  │  │   └─ ...                     │
                                 │  │  ├─ /etc/ssh/authorized_keys.d/ │
                                 │  │  └─ everything else             │
                                 │  └─────────────────────────────────┘
                                 └─────────────────────────────────┘
```

## Layers of Protection

### Layer 1: LUKS2 Full Disk Encryption (at rest)

The root partition is encrypted with LUKS2 during the `mkosi` build.
You type the passphrase interactively during `./build.sh`. The
passphrase is held only in `/dev/shm/` (RAM-backed tmpfs) for the
duration of the build and is **never written to persistent storage**.

**What this protects against:**
- Physical theft of the drive or USB stick
- Offline forensic analysis of the disk
- Unauthorized reads of credentials, logs, and application code

### Layer 2: systemd LoadCredential= (at runtime)

Services that need secrets (Tailscale, Cloudflare, SendGrid, etc.)
use systemd's `LoadCredential=` directive. When a service starts,
systemd copies the credential file into an isolated, memory-backed
tmpfs that is **only visible to that specific service**. When the
service stops, the tmpfs is destroyed.

**What this protects against:**
- A compromised web server process reading another service's secrets
- Arbitrary file read vulnerabilities (the credential file is
  `0600 root:root`, and even if bypassed, other services' credentials
  are in isolated namespaces)

### Layer 3: TPM2 Enrollment (optional, baremetal)

After the first passphrase-unlocked boot on the target machine,
run `sudo ab-enroll-tpm` to bind the LUKS volume to the hardware
TPM. Subsequent boots auto-unlock without typing a password.

**What this protects against:**
- Drive removal attacks (the drive is unreadable on any other machine)
- Boot tampering (if combined with Secure Boot, the TPM refuses to
  unseal if the boot chain has been modified)

## Workflow

### Development (QEMU)

1. `./build.sh --host evox2` — prompts for LUKS passphrase
2. `./run.sh --host evox2` — QEMU boots, prompts for LUKS passphrase
3. Login and run `sudo ab-verify` to confirm everything is working
4. Iterate on changes

### Production (Baremetal)

1. `./build.sh --host evox2` — prompts for LUKS passphrase
2. Flash to USB or disk
3. Boot the target machine — type the LUKS passphrase
4. Login and run `sudo ab-verify`
5. Run `sudo ab-enroll-tpm` to bind to the hardware TPM
6. Reboot — the machine now auto-unlocks
7. The passphrase remains as a manual recovery fallback

## Why Not systemd-creds encrypt?

The `systemd-creds encrypt` tool encrypts individual credential
files against a master key. In theory, this provides per-credential
encryption at rest. In practice, for cross-built images (where the
build host and the target are different machines), it has a fatal
flaw: the build host's `systemd-creds` binds the encryption to the
host's own machine-id and/or TPM. The target machine has a different
machine-id and different TPM, so it cannot decrypt the credentials.

Newer versions of `systemd-creds` added a `--host-key-path` flag
to work around this, but Debian trixie's version does not have it.

LUKS encryption of the entire partition provides strictly superior
protection:
- It encrypts **everything**, not just individual credential files
- It does not have portability issues between build host and target
- It uses the same battle-tested LUKS2 cryptographic primitives

## Credential Store Layout

| Path | Purpose | Permissions |
|------|---------|-------------|
| `/etc/credstore/tailscale-authkey` | Tailscale pre-auth key | `0600` |
| `/etc/credstore/cloudflared-token` | Cloudflare tunnel token | `0600` |
| `/etc/credstore/sendgrid-api-key` | SendGrid API key | `0600` |
| `/etc/credstore/pagerduty-routing-key` | PagerDuty routing key | `0600` |
| `/etc/credstore/healthchecks-ping-url` | Healthchecks.io ping URL | `0600` |

All files are owned by `root:root`. Services access them via
`LoadCredential=<name>:/etc/credstore/<name>`, which loads the file
into an isolated tmpfs visible only to that service.

## Tools

| Command | Where it runs | Purpose |
|---------|--------------|---------|
| `sudo ab-verify` | Inside the booted image | Full post-boot verification (LUKS, TPM, credentials, SSH, VPN, system health) |
| `sudo ab-enroll-tpm` | Inside the booted image | Bind LUKS to the hardware TPM for auto-unlock |
| `sudo ab-enroll-tpm --status` | Inside the booted image | Check TPM enrollment status |
| `sudo ab-runtime-validate` | Inside the booted image | Extended runtime validation with email/PagerDuty probes |
