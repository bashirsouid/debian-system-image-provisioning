# APPLY.md — how to apply this overlay

Read `README.md` first for the what and why. This file is the "do
these exact steps" companion.

## 0. Prereqs on the build host

```
sudo apt-get update
sudo apt-get install --no-install-recommends \
    mkosi systemd systemd-container systemd-boot \
    fdisk dosfstools jq curl gpg whois \
    shellcheck zip
```

`whois` gets you `mkpasswd`. `systemd-container` gets you
`systemd-creds` and `systemd-dissect`.

## 1. Copy the overlay

From this overlay's root (where `README.md` and `mkosi.extra/` live):

```
cd /path/to/bashirsouid/debian-system-image-provisioning
cp -rT /path/to/overlay/. .
```

`cp -rT .` copies the contents of the overlay, not the overlay
directory itself. This is what you want.

## 2. Populate .mkosi-secrets/

On the build host only. This directory is already in `.gitignore`.

```
cd /path/to/repo
mkdir -m 700 -p .mkosi-secrets
```

Required files (all mode 0600):

```
.mkosi-secrets/
├── tailscale-authkey          # tskey-auth-... from Tailscale admin
├── cloudflared-token          # long base64 from Cloudflare Zero Trust dashboard
├── ssh-authorized-keys        # one or more sk-ed25519@openssh.com lines
├── sendgrid-api-key           # starts with SG.
├── pagerduty-routing-key      # 32-char integration key
└── healthchecks-ping-url      # https://hc-ping.com/<uuid>
```

Per-host overrides go under `.mkosi-secrets/hosts/<hostname>/`.

See `docs/remote-access.md` for provider-specific setup (where in
each vendor's dashboard to click to get these).

## 3. Fetch third-party apt signing keys

One-time (fingerprints are already pinned in the script):

```
./scripts/fetch-third-party-keys.sh
```

This fetches the Tailscale and Cloudflare signing keys, verifies
their fingerprints against the pinned values, and writes them to
`mkosi.extra/etc/apt/keyrings/`. Those files are gitignored.

Re-run this before every release rebuild to get any key rotation.

## 4. Changes to existing files in the repo

### 4a. `mkosi.conf`

Currently has `ExtraTrees=.mkosi-secrets:/` — **remove this line**.
Anything under `.mkosi-secrets/` that needs to reach the image now
goes through `scripts/package-credentials.sh` or
`scripts/package-alert-credentials.sh` explicitly.

Also — if you want Phase 1 of the Secure Boot roadmap now — add:

```
[Output]
Verity=signed
```

(Only do this after you have tested the build without it.)

### 4b. `build.sh`

Near the top, after arg parsing and before `mkosi`:

```bash
# Fail fast if shellcheck finds a regression
"${REPO_ROOT}/scripts/lint.sh"

# Validate secrets shape and perms before we build
"${REPO_ROOT}/scripts/verify-build-secrets.sh" \
    ${STRICT_SECRETS:+--strict} \
    ${PROFILE:+--profile "${PROFILE}"} \
    ${HOST:+--host "${HOST}"}

# Encrypt tailscale/cloudflared/ssh; writes per-image credential.secret
"${REPO_ROOT}/scripts/package-credentials.sh" \
    ${HOST:+--host "${HOST}"}

# Encrypt sendgrid/pagerduty/healthchecks (reuses credential.secret)
"${REPO_ROOT}/scripts/package-alert-credentials.sh" \
    ${HOST:+--host "${HOST}"}
```

`package-alert-credentials.sh` MUST run AFTER `package-credentials.sh`
because it reuses the per-image `credential.secret` that
`package-credentials.sh` writes. If you reverse the order it will
fail loudly with "credential.secret missing."

### 4c. `clean.sh`

Add to the `--all` path:

```bash
rm -rf -- mkosi.extra/etc/credstore.encrypted
rm -f  -- mkosi.extra/var/lib/systemd/credential.secret
rm -rf -- mkosi.extra/etc/ssh/authorized_keys.d
rm -f  -- mkosi.extra/etc/apt/keyrings/*.gpg
```

Do NOT remove `mkosi.extra/etc/ssh/sshd_config.d/50-hardening.conf` —
it has a `__INITIAL_USERNAME__` template that `package-credentials.sh`
substitutes in place. If you want a fully clean state, use
`git checkout mkosi.extra/etc/ssh/sshd_config.d/50-hardening.conf`.

### 4d. `mkosi.finalize`

Add a section to enable the new units. You have two options:

**Option A — simple direct enablement (fewer moving parts):**

```bash
for unit in \
    tailscale-up.service         tailscale-watchdog.timer \
    cloudflared.service          cloudflared-watchdog.timer \
    ab-user-provision.service \
    ab-monitor.timer             ab-heartbeat.timer \
    ssh.service \
    nftables.service \
    systemd-resolved.service     systemd-timesyncd.service \
    systemd-oomd.service \
; do
    systemctl --root="${BUILDROOT}" enable "${unit}"
done
```

**Option B — presets (scales better if you add more units later):**

Write `mkosi.extra/etc/systemd/system-preset/90-ab.preset`:

```
enable tailscale-up.service
enable tailscale-watchdog.timer
enable cloudflared.service
enable cloudflared-watchdog.timer
enable ab-user-provision.service
enable ab-monitor.timer
enable ab-heartbeat.timer
enable ssh.service
enable nftables.service
enable systemd-resolved.service
enable systemd-timesyncd.service
enable systemd-oomd.service
```

Then in `mkosi.finalize`:

```bash
systemctl --root="${BUILDROOT}" preset-all
```

## 5. Build

```
./build.sh --profile server --host <host>
```

Expect to see in order:
- shellcheck passes silently
- `verify-build-secrets` prints `ok: ...` lines for each secret
- `package-credentials` prints `encrypting tailscale-authkey`, etc.
- `package-alert-credentials` prints the alert secrets
- mkosi build runs to completion
- an `image.raw` appears under `mkosi.output/`

## 6. Validate the image BEFORE flashing it

```
sudo ./scripts/verify-image-raw.sh
```

Should finish with `image verification passed.`. If it reports any
FAIL line, do not flash.

## 7. Flash to a USB with readback verify

```
lsblk                        # identify the USB device
sudo ./scripts/usb-write-and-verify.sh \
    --source mkosi.output/debian-provisioning_*.raw \
    --target /dev/sdX
```

Will refuse to write if the target is not removable or is the
host root disk. Will refuse to claim success if post-write hash
differs from source.

## 8. Boot the USB on the target host

Use the firmware boot menu (F12 / Esc / Opt on Mac). Once up:

```
sudo ab-monitor-status       # nothing red, all configured?
sudo ab-remote-access-status # tailscale + cloudflared + sshd all up?
sudo ab-monitor-test         # trigger + resolve through email + PD
```

If those all pass, you can proceed to install to internal disk.

## 9. First-boot password hash

On your laptop:

```
./scripts/hash-password.sh
```

Enter a password (no echo, typed twice, minimum 12 chars). Copy the
printed hash (starts with `$y$j9T$...`) into `.users.json`:

```
[
  {
    "username": "demo",
    "can_login": true,
    "password_hash": "$y$j9T$...the hash you got...",
    "force_password_change_on_first_login": false,
    ...
  }
]
```

Rebuild and redeploy. First-boot provisioning will apply the hash
and shred `/etc/ab-users.json` when done.

## 10. Post-deploy verifications

```
# Monitor state
sudo ab-monitor-status
systemctl list-timers ab-monitor.timer ab-heartbeat.timer

# Firewall
sudo nft list ruleset

# DNS
resolvectl status

# Watchdog
systemctl show -p RuntimeWatchdogUSec

# Force a test alert through every channel
sudo ab-monitor-test

# Test the healthchecks.io dead-man's switch
#   (stop the timer for 20+ minutes, expect a missed-ping alert)
sudo systemctl stop ab-heartbeat.timer
# ... wait 20 min ...
sudo systemctl start ab-heartbeat.timer
```

## 11. Rolling back

Every change in this overlay can be rolled back by either:

- **A/B rollback:** reboot and use `bootctl set-default @prev` to
  pick the previous version. The health gate does this automatically
  on failed boots.
- **Per-file override:** drop a file with the same path under
  `hosts/<host>/` that overrides or disables the one you do not
  want.
- **Git revert:** every file in this overlay is tracked; `git revert`
  on the merge commit backs out the overlay wholesale.

## 12. What to do if something is wrong

Most likely failure modes and where to look:

| Symptom                                         | Look at                                  |
|-------------------------------------------------|------------------------------------------|
| `systemctl status tailscale-up.service` fails   | credstore exists? Auth key valid?         |
| `cloudflared.service` restarts in a loop        | token valid? journal -u cloudflared      |
| SSH rejected after boot                         | `sshd -T`; `/etc/ssh/authorized_keys.d/` |
| Email alerts stop arriving                      | `journalctl -u ab-monitor.service`       |
| PagerDuty incidents duplicate                   | `AB_MONITOR_REMIND_AFTER_SECS` too small |
| DNS stops working                               | `resolvectl status`; try `DNSSEC=allow-downgrade` |
| Monitor self-test has no effect                 | credentials present? `ls /etc/credstore.encrypted/` |
| nftables blocks something unexpected            | `/etc/nftables.conf.d/*.nft` per-host    |

Most issues are visible in `journalctl -b -p err`.
