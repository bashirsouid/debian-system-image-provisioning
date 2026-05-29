# Remote access: Tailscale (primary) + Cloudflare Tunnel (backup) + hardware-backed SSH

This document covers the add-on that gives every built image two
independent paths back in:

* **Primary:** SSH over the Tailscale mesh (Wireguard). Low latency,
  fully authenticated via your Tailscale tenant.
* **Backup:** SSH over a Cloudflare Named Tunnel. Works even when the
  Tailscale control plane is unreachable, or when the host's ISP is
  egressing through something that breaks Wireguard UDP.
* **Auth:** Hardware-backed SSH keys (FIDO2, e.g. YubiKey) with user
  presence required on every login.

All three paths survive an A/B rollback because they are configured by
the image, not by post-install provisioning.

## One-time setup on the build host

### 1. Install host tools

```
sudo apt-get install --no-install-recommends jq curl
```

Install `age` too if you want to use the local encrypted vault
workflow from `docs/local-secret-vault.md`.

### 2. Generate a hardware-backed SSH key on your client machine

On the machine you will SSH *from*:

```
ssh-keygen -t ed25519-sk -O resident -O verify-required \
    -C "$(hostname)-$(date +%Y%m%d)" \
    -f ~/.ssh/id_ed25519_sk_admin
```

* `-O resident` stores the key handle on the YubiKey so you can
  reconstitute it on another machine with
  `ssh-keygen -K`.
* `-O verify-required` forces a PIN + touch on every use, not just
  touch.

Copy the PUBLIC key into the build repo's secrets staging area.

### 3. Provision the secrets directory

If you use the local age vault workflow, put these values in
`secrets/mkosi-secrets.json.age` instead and build with
`bin/mkosi-vault-build.sh`; see `docs/local-secret-vault.md`.
The `.mkosi-secrets/` layout below is still the build-time interface
that the vault wrapper materializes.

```
cd <repo>
mkdir -m 700 -p .mkosi-secrets
chmod 700 .mkosi-secrets
```

Populate three files. Top-level applies to all hosts; you can override
per host under `.mkosi-secrets/hosts/<host>/`.

#### 3a. Tailscale auth key

Log into the Tailscale admin console, go to Settings → Keys, and
generate a **reusable** auth key:

* Tag it (for example `tag:workstation`) so your ACLs can target it.
* Set a reasonable expiry (90 days is a common default).
* Save it to `.mkosi-secrets/tailscale-authkey` as a single line, no
  trailing newline, mode 0600.

```
install -m 600 /dev/stdin .mkosi-secrets/tailscale-authkey <<'EOF'
tskey-auth-kXXXXXXXXXXXX-YYYYYYYYYYYYYYYYYYYYYYYY
EOF
```

#### 3b. Cloudflare Tunnel token

In the Cloudflare Zero Trust dashboard
(`one.dash.cloudflare.com` → Networks → Tunnels), create a new
**Remotely-Managed Named Tunnel** for this host. Copy the install
token:

```
install -m 600 /dev/stdin .mkosi-secrets/cloudflared-token <<'EOF'
eyJhIjoi... long base64 string ...
EOF
```

Then, in the tunnel's Public Hostname config, add an **SSH** route:

| Subdomain | Domain       | Path | Type | URL             |
|-----------|--------------|------|------|-----------------|
| `ssh`     | `example.com`|      | SSH  | `localhost:22`  |

Attach a Cloudflare Access policy to that hostname. Require at least
one of: your Cloudflare SSO identity, a WARP posture check, or an
mTLS service token. **Do not leave the SSH hostname publicly reachable
without an Access policy** — that is equivalent to exposing sshd on
the public internet.

#### 3c. SSH authorized keys

```
cp ~/.ssh/id_ed25519_sk_admin.pub .mkosi-secrets/ssh-authorized-keys
chmod 600 .mkosi-secrets/ssh-authorized-keys
```

One public key per line. The verify script will warn if you include
non-hardware keys and refuse to continue in `--strict` mode.

### 4. Verify, then build

```
./scripts/verify-build-secrets.sh --strict
./scripts/package-credentials.sh --host <hostname>
./build.sh --profile server --host <hostname>
```

Integrate the first two calls into `build.sh` so every build enforces
them.

## What ends up in the image

* `/etc/credstore/tailscale-authkey` — plaintext credential on the
  LUKS-encrypted root filesystem, loaded through systemd
  `LoadCredential=` by `tailscale-up.service`.
* `/etc/credstore/cloudflared-token` — plaintext credential on the
  LUKS-encrypted root filesystem, loaded through systemd
  `LoadCredential=` by `cloudflared.service`.
* `/etc/ssh/authorized_keys.d/<user>` — plaintext public SSH keys.
* `/etc/ssh/sshd_config.d/50-hardening.conf` — hardened sshd config.
* `/usr/local/libexec/ab-remote-access/ensure-tailscale.sh`
* `/usr/local/libexec/ab-remote-access/ensure-cloudflared.sh`
* `/usr/local/libexec/ab-health-check.d/10-tailscale.sh`
* `/usr/local/libexec/ab-health-check.d/20-cloudflared.sh`
* `/usr/local/libexec/ab-health-check.d/30-sshd.sh`
* `/usr/local/sbin/ab-remote-access-status`

## What runs on the image

| Unit                          | Trigger                          | Purpose                                                    |
|-------------------------------|----------------------------------|------------------------------------------------------------|
| `tailscaled.service`          | default-install enabled          | Tailscale daemon (upstream package)                        |
| `tailscale-up.service`        | `WantedBy=multi-user.target`     | Auth on first boot, re-auth if session died                |
| `tailscale-watchdog.timer`    | every 10 min                     | Re-runs ensure script; re-auth if BackendState != Running  |
| `cloudflared.service`         | `WantedBy=multi-user.target`     | Runs the tunnel                                            |
| `cloudflared-watchdog.timer`  | every 5 min                      | Probes `/ready`; restarts service if unhealthy             |
| `ssh.service`                 | default-install enabled          | sshd (hardened config baked into image)                    |

The health-check hooks under `/usr/local/libexec/ab-health-check.d/`
are called by the existing `ab-health-gate.service` before
`boot-complete.target`. If any of them fails, the current A/B slot
does not get blessed, boot counting decrements, and the next reboot
falls back to the previous version.

## Connecting

### Over Tailscale (primary)

```
ssh <user>@<host>.<your-tailnet>.ts.net
```

With `PubkeyAuthOptions verify-required`, the client will prompt you
to touch the YubiKey.

### Over Cloudflare Tunnel (backup)

One-time client setup:

```
brew install cloudflared      # or your OS equivalent
cloudflared access login ssh.example.com
```

Put this in `~/.ssh/config`:

```
Host ssh.example.com
    ProxyCommand cloudflared access ssh --hostname %h
    User <user>
    IdentityFile ~/.ssh/id_ed25519_sk_admin
```

Then `ssh ssh.example.com`. Cloudflare Access authenticates your
identity, the tunnel reaches the host, and sshd authenticates the
hardware key.

## Operational runbook

### "I revoked the Tailscale auth key and now the node is disconnected."

The watchdog will try to re-auth every 10 minutes and fail. Symptoms:
`tailscale-watchdog.service` in a failed state, `BackendState=NeedsLogin`.

Rebuild the image with a new auth key in `.mkosi-secrets/tailscale-authkey`
and deploy via the normal sysupdate path. If you cannot reach the host
to run sysupdate, connect via the Cloudflare Tunnel path and run it
there.

### "Cloudflare Tunnel shows no connections."

On the host:

```
ab-remote-access-status
journalctl -u cloudflared.service -n 200 --no-pager
```

If the service is active but `readyConnections=0`, the watchdog will
restart it within 5 minutes. If the token is invalid (revoked in the
dashboard), the logs will say so; rebuild with a new token.

### "I lost the YubiKey."

If you followed the `-O resident` recommendation, the key handle is
on the YubiKey, not on your laptop. Keep a second YubiKey enrolled
from the start: during step 3c, include public keys for BOTH YubiKeys
in `.mkosi-secrets/ssh-authorized-keys`.

If you lost both: connect via the Cloudflare Tunnel path using a
recovery public key you baked in (add a third entry to
`ssh-authorized-keys` tied to a second hardware token stored in a
safe), or re-flash the image with a fresh key pair and reinstall.

## Threat model notes

* **Where plaintext lives.** Plaintext auth material exists on the
  build host in `.mkosi-secrets/` while staging is unlocked, inside
  the image's LUKS-encrypted `/etc/credstore/`, and in-process for the
  lifetime of `tailscale-up.service` and `cloudflared.service` via a
  systemd-managed tmpfs credentials directory that only the service
  sees. Use `bin/mkosi-vault-build.sh` to keep the durable build-host
  copy encrypted at rest and remove `.mkosi-secrets/` after each build.
* **What an attacker with the locked image file can do.** Without the
  LUKS passphrase or TPM-unsealed key, they see ciphertext. If they
  obtain the passphrase or compromise a running system, they can read
  `/etc/credstore/`, so rotate Tailscale auth keys and cloudflared
  tokens routinely.
* **What an attacker on the network can do without a key.** Nothing
  useful. sshd rejects passwords, requires a hardware-backed key
  touch, and binds `AllowUsers` to a single account. Cloudflare Access
  rejects unauthenticated clients. Tailscale rejects peers not in
  your tailnet.
* **What an attacker who compromises a YubiKey does.** Needs the PIN
  (enforced by `-O verify-required`), needs physical presence to
  touch the device, and still has to pass Cloudflare Access for the
  backup path. A lost YubiKey should be de-enrolled: rebuild the
  image without its public key, deploy, and revoke its Tailscale
  session from the admin console.

## Rotation

* **Tailscale auth keys:** rotate every 90 days. Ephemeral keys are
  even better if your workflow can tolerate them.
* **Cloudflared tokens:** rotate on a cadence appropriate for your
  tenant; they do not have auto-expiry by default. Delete and
  re-create the tunnel connector in the Cloudflare dashboard.
* **SSH keys:** rotate on a 1–2 year cadence or immediately on
  suspected compromise.
* **Image credential store:** rebuilt each time `package-credentials.sh`
  runs. At-rest confidentiality comes from the image's LUKS root
  encryption; service isolation comes from systemd `LoadCredential=`.
