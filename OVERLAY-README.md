# Overlay for bashirsouid/debian-system-image-provisioning

**Status:** reviewed prescription, not tested on hardware.
**Scope:** 82 files across four subsystems (remote access, correctness
fixes, reliability/alerting, security hardening).
**Target repo:** https://github.com/bashirsouid/debian-system-image-provisioning

This archive was produced by a multi-turn review and synthesis. It is
structured as a direct drop-in overlay on top of the existing repo —
every path here mirrors where it lands in the repo. Apply by copying
the tree over; there are no generated paths that have to be computed.

---

## 1. What this overlay provides

Four subsystems, each independently reversible.

### A. Remote access (subsystem: "addon")
- Tailscale with first-boot auth against an encrypted `systemd-creds`
  credential, a periodic re-auth watchdog, and a service drop-in that
  tightens restart policy.
- Cloudflare Named Tunnel for out-of-band SSH that works even when
  Tailscale is unreachable. Tunnel token is also an encrypted
  credential. Watchdog probes `/ready` and restarts on unhealthy.
- sshd hardened to pubkey-only with `PubkeyAuthOptions verify-required`,
  so FIDO2 hardware keys require user presence (YubiKey touch) on
  every connection. Modern crypto only. Listener locked to a single
  login user via `AllowUsers`.
- Three health-gate hooks (`/usr/local/libexec/ab-health-check.d/`)
  so a broken remote-access config on a newly installed A/B slot
  fails the health gate and automatically rolls back.

### B. Correctness fixes (subsystem: "fixes")
- New `.gitignore` that de-dupes the existing one and adds several
  categories of generated files.
- `.users.json.sample` updated to prefer `password_hash` over
  plaintext passwords.
- `scripts/hash-password.sh` helper that produces yescrypt hashes
  without ever writing the plaintext to disk.
- First-boot `ab-user-provision.service` that refuses plaintext
  passwords on production images (VARIANT_ID=prod) and shreds the
  users file after applying.
- `scripts/usb-write-and-verify.sh` that writes a raw image and
  then hashes back the written bytes from the block device; refuses
  to report success on mismatch.
- `scripts/verify-image-raw.sh` that validates a built `image.raw`
  via sfdisk + systemd-dissect before you flash it.
- `mkosi.repart/` split from `deploy.repart/` so the mkosi-built
  image has its own partition layout distinct from the one used by
  the bootstrap-to-target flow.
- `mkosi.conf.d/15-reproducibility.conf` pinning the Debian mirror
  to a specific `snapshot.debian.org` date.
- Deb822 apt sources for the Cloudflare and Tailscale repos, with
  **real pinned signing-key fingerprints** in
  `scripts/fetch-third-party-keys.sh`:
  - Tailscale: `2596A99EAAB33821893C0A79458CA832957F5868`
    (verified against upstream docs and two independent GitHub
    issues; see comments in the script)
  - Cloudflare: `FBA8C0EE63617C5EED695C43254B391D8CACCBF8`
    (verified against Cloudflare's GitHub issues; see script)
- `scripts/lint.sh` + `.shellcheckrc` + `.github/workflows/lint.yml`
  for shellcheck CI.

### C. Reliability + alerting (subsystem: "reliability")
- `ab-monitor.timer` (every 5 min) runs eight checks: Tailscale
  BackendState, cloudflared `/ready`, sshd listening, A/B stale
  (7 days without a successful bless triggers a warning that repeats
  daily), BLS entry marked bad, failed systemd units, disk space
  (90%/95% warn/crit), NTP sync.
- `ab-heartbeat.timer` (every 5 min, offset) pings healthchecks.io
  as a dead-man's switch. If local fault is detected, it POSTs to
  `/fail` to escalate immediately without waiting for grace.
- Three notifiers: SendGrid (email), PagerDuty (Events API v2 with
  stable `dedup_key=<host>-<alert_key>` so triggers auto-group and
  `resolve` closes the incident), and a journal-structured notifier
  that always runs as a forensic record.
- Per-alert dedup state under `/var/lib/ab-monitor/state.json`:
  first-detection fires, continued failure goes quiet for 24h
  (`AB_MONITOR_REMIND_AFTER_SECS`) then re-notifies once per day,
  recovery fires a resolve.
- `[email protected]` template so any existing unit
  can add `OnFailure=ab-monitor-alert@%n.service` and get an instant
  page without waiting for the 5-minute timer. Routed through the
  same dedup state.
- Hardware watchdog (`/etc/systemd/system.conf.d/30-watchdog.conf`,
  `RuntimeWatchdogSec=60s`) so a kernel hang auto-recovers.
- Kernel panic auto-reboot after 30s, panic-on-oops, hardlockup and
  softlockup panics (`/etc/sysctl.d/90-ab-reliability.conf`).
- Journald capped at 2G (`/etc/systemd/journald.conf.d/20-ab-size.conf`)
  so an error loop cannot fill the root slot.
- `ab-monitor-status` (inspector) and `ab-monitor-test` (self-test
  with `--channel`, `--keep-open`, `--resolve-only`) CLIs.

### D. Security hardening (subsystem: "security")
- Kernel hardening sysctls: `yama.ptrace_scope=1`,
  `unprivileged_bpf_disabled=1`, `bpf_jit_harden=2`,
  `kexec_load_disabled=1`, `dev.tty.ldisc_autoload=0`,
  `fs.protected_*`, `tcp_syncookies`, `tcp_rfc1337`, IPv4/IPv6
  antispoof + martian logging, `icmp_echo_ignore_broadcasts`,
  and privacy extensions for IPv6.
- Kernel module blacklist (`/etc/modprobe.d/ab-blacklist.conf`):
  dccp, sctp, rds, tipc, n-hdlc, ax25, x25, appletalk, ipx, atm,
  cramfs, freevxfs, jffs2, hfs, hfsplus, udf, ksmbd, firewire-* —
  every module that has been a recurring local-exploit CVE source,
  disabled unless the host legitimately needs it.
- Default-deny nftables firewall (`/etc/nftables.conf`) with
  established+related, loopback, SSH (rate-limited to 10/minute
  burst 5 via `ct state new limit`), Tailscale mesh traffic
  (`iifname tailscale0`), WireGuard UDP 41641, constrained ICMP,
  mDNS limited to RFC1918 source addresses. Per-host additions
  via `/etc/nftables.conf.d/*.nft`.
- Sudoers hardening (`/etc/sudoers.d/90-ab-hardening`):
  `timestamp_timeout=5`, `timestamp_type=tty`, `requiretty`,
  `use_pty`, `env_reset` with strict `secure_path`, syslog/iolog
  to `authpriv`.
- Opt-in PAM-U2F for sudo. `ab-enable-pam-u2f` enrolls the YubiKey
  and writes to `/var/lib/ab-pam-u2f/u2f_mappings` without touching
  `/etc/pam.d/sudo` at runtime (that would clobber a dpkg conffile).
  Enforcement is a two-step rebuild: stage the mapping in the build
  tree, rebuild with `AB_ENABLE_PAM_U2F=yes`, deploy via sysupdate.
- systemd-resolved over TLS with DNSSEC (`1.1.1.1` primary, `9.9.9.9`
  fallback, both with strict SNI verification).
- systemd-oomd (userspace OOM killer based on PSI pressure) so the
  kernel's score-based OOMK cannot pick sshd or Home Assistant.
- `Storage=none` for coredumps — a crash of any process holding a
  just-decrypted credential cannot leak it to disk.
- `ab-enroll-tpm-unlock` helper that wraps `systemd-cryptenroll`
  to bind a LUKS key slot on `/home` or `/mnt/data` to PCRs 0+2+7
  (firmware + option ROMs + Secure Boot policy).
- `docs/secure-boot-roadmap.md` for the `RootVerity=signed` + UKI
  signing + firmware enrollment phases that require physical access.

---

## 2. Architecture

```
                  your build host (Debian trixie)
                  +------------------------------+
                  |  .mkosi-secrets/             |  (0700, gitignored)
                  |    tailscale-authkey         |
                  |    cloudflared-token         |
                  |    ssh-authorized-keys       |
                  |    sendgrid-api-key          |
                  |    pagerduty-routing-key     |
                  |    healthchecks-ping-url     |
                  +---------------+--------------+
                                  |
                                  v
      scripts/verify-build-secrets.sh  (shape + permissions gate)
                                  |
                                  v
      scripts/package-credentials.sh
                       writes per-image credential.secret +
                       encrypts tailscale+cloudflared tokens +
                       installs ssh authorized_keys +
                       substitutes __INITIAL_USERNAME__
                                  |
                                  v
      scripts/package-alert-credentials.sh
                       encrypts sendgrid + pagerduty + healthchecks
                                  |
                                  v
                             mkosi build
                                  |
                                  v
                           image.raw ---->  scripts/verify-image-raw.sh
                                  |
                                  v
                   scripts/usb-write-and-verify.sh (for hardware USB tests)
                             OR
                   systemd-sysupdate (for live deploys)


                           on the booted image
                  +------------------------------+
                  |  /etc/credstore.encrypted/   |  (encrypted blobs)
                  |  /var/lib/systemd/            |
                  |      credential.secret        |  (per-image host key)
                  +---------------+--------------+
                                  |
     +--------------+--------------+-----------------+--------------+
     |              |              |                 |              |
     v              v              v                 v              v
tailscale-up   cloudflared   ab-monitor         ab-heartbeat   ab-monitor
.service       .service      .timer (5m)         .timer (5m)   -alert@
                                  |                 |             .service
                                  v                 v             (OnFailure=)
                             8 checks ---> 3 notifiers
                               /              |   |   \
                              /               |   |    \
                       sendgrid.sh      pagerduty.sh  journal.sh
                              \               |   /
                               v              v  v
                        email        PagerDuty   journald
                           |              |         |
                           v              v         v
                         YOU          YOU       (forensic)

       Out-of-band paths:
       * Tailscale: [email protected] (primary)
       * Cloudflare Tunnel: via cloudflared access ssh (backup,
         works even when Tailscale's control plane is unreachable)
       * healthchecks.io: alerts YOU if heartbeat stops arriving
         (catches power loss / panic / network totally dark)
```

---

## 3. Inventory: every file, its purpose, and its subsystem

Format: `path  [subsystem]  purpose`

### Top-level
```
README.md                              [this file]    the master doc
APPLY.md                               [this overlay] step-by-step application guide
.gitignore                             [fixes]        replaces existing; de-duped, adds secrets/credstore/keyring ignores
.users.json.sample                     [fixes]        replaces existing; prefers password_hash, adds ssh_authorized_keys_file
.shellcheckrc                          [fixes]        repo-wide shellcheck defaults (disables SC1091, SC2155, SC2016)
.github/workflows/lint.yml             [fixes]        GHA that runs scripts/lint.sh on push and PR
.mkosi-secrets.example/README.md       [addon]        committed template for the (gitignored) .mkosi-secrets/ tree
```

### docs/
```
docs/remote-access.md                  [addon]        operator doc: auth-key provisioning, YubiKey setup, rotation
docs/user-provisioning.md              [fixes]        explains the password_hash workflow
docs/live-usb-verification.md          [fixes]        why dd exit 0 is not sufficient
docs/alerting.md                       [reliability]  three independent alert paths + dedup state machine
docs/runbook.md                        [reliability]  alert-key-indexed triage guide (read from phone when paged)
docs/secure-boot-roadmap.md            [security]     four-phase plan for verity + UKI signing + TPM
docs/hardening-walkthrough.md          [security]     ordered security changes with per-step risks + rollbacks
```

### mkosi.conf.d/
```
mkosi.conf.d/15-reproducibility.conf   [fixes]        pins Mirror= to snapshot.debian.org + SOURCE_DATE_EPOCH
mkosi.conf.d/20-remote-access.conf     [addon]        adds tailscale, cloudflared, openssh-server, libpam-u2f
```

### mkosi.repart/
```
mkosi.repart/00-esp.conf               [fixes]        ESP for the BUILT image.raw (not deploy.repart/)
mkosi.repart/10-root.conf              [fixes]        root partition for the BUILT image.raw
```

### scripts/
```
scripts/verify-build-secrets.sh        [addon]        build-time gate; refuses missing/malformed/world-readable
scripts/package-credentials.sh         [addon]        encrypts tailscale/cloudflared secrets; substitutes username
scripts/package-alert-credentials.sh   [reliability]  encrypts sendgrid/pagerduty/healthchecks; reuses credential.secret
scripts/hash-password.sh               [fixes]        yescrypt hash generator; no plaintext to disk
scripts/usb-write-and-verify.sh        [fixes]        dd conv=fsync + drop_caches + sha256 readback
scripts/verify-image-raw.sh            [fixes]        sfdisk + systemd-dissect sanity on mkosi output
scripts/fetch-third-party-keys.sh      [fixes]        pinned-fingerprint Cloudflare + Tailscale key fetcher
scripts/lint.sh                        [fixes]        shellcheck wrapper; --changed mode for CI PRs
```

### mkosi.extra/etc/ (image rootfs configs)
```
etc/apt/keyrings/README.md             [fixes]        placeholder so dir is tracked; .gpg files are gitignored
etc/apt/sources.list.d/cloudflared.sources  [fixes]   Deb822 for pkg.cloudflare.com/cloudflared bookworm
etc/apt/sources.list.d/tailscale.sources    [fixes]   Deb822 for pkgs.tailscale.com/stable/debian TRIXIE
etc/default/ab-monitor                 [reliability]  env config: channels, thresholds, email addresses
etc/default/tailscale-up               [addon]        tailscale up flags (host-overridable)
etc/modprobe.d/ab-blacklist.conf       [security]     blacklists obscure protocols + legacy FS modules
etc/nftables.conf                      [security]     default-deny firewall with rate-limited SSH + Tailscale allow
etc/pam.d/sudo-u2f                     [security]     PAM-U2F include file (NOT enabled by default)
etc/security/limits.d/90-ab-hardening.conf [security] nproc/nofile/core limits
etc/ssh/sshd_config.d/50-hardening.conf    [addon]    hardened sshd; __INITIAL_USERNAME__ is substituted at build
etc/sudoers.d/90-ab-hardening          [security]     timestamp_timeout=5, requiretty, use_pty, env_reset
etc/sysctl.d/90-ab-reliability.conf    [reliability]  kernel.panic=30, panic_on_oops, BBR, sysrq limited
etc/sysctl.d/95-ab-kernel-hardening.conf [security]   ptrace, BPF, kexec, IPv4/6 antispoof
etc/systemd/coredump.conf.d/10-ab.conf [security]     Storage=none; coredumps never hit disk
etc/systemd/journald.conf.d/20-ab-size.conf [reliability] caps journal at 2G, 30d retention
etc/systemd/oomd.conf.d/10-ab.conf     [security]     PSI-based userspace OOM killer
etc/systemd/resolved.conf.d/10-ab-hardening.conf [security] DoT + DNSSEC (hard-fail); Cloudflare/Quad9
etc/systemd/system.conf.d/30-watchdog.conf [reliability] hardware watchdog (RuntimeWatchdogSec=60s)
etc/systemd/system/ab-user-provision.service      [fixes]       first-boot user setup
etc/systemd/system/cloudflared.service            [addon]       tunnel with LoadCredentialEncrypted=
etc/systemd/system/cloudflared-watchdog.service   [addon]       /ready probe + restart
etc/systemd/system/cloudflared-watchdog.timer     [addon]       every 5 min
etc/systemd/system/tailscale-up.service           [addon]       first-boot auth
etc/systemd/system/tailscale-watchdog.service     [addon]       periodic ensure
etc/systemd/system/tailscale-watchdog.timer       [addon]       every 10 min after OnBootSec=2min
etc/systemd/system/tailscaled.service.d/10-restart.conf [addon] tightens upstream restart policy
etc/systemd/system/ab-monitor.service             [reliability] main monitor runner (loads all 3 alert creds)
etc/systemd/system/ab-monitor.timer               [reliability] every 5 min, RandomizedDelaySec=60s
etc/systemd/system/ab-heartbeat.service           [reliability] healthchecks.io ping
etc/systemd/system/ab-heartbeat.timer             [reliability] every 5 min, offset 4 min from monitor
etc/systemd/system/[email protected]       [reliability] template unit for OnFailure= hooks
```

### mkosi.extra/usr/local/ (image userspace tools)
```
usr/local/libexec/ab-health-check.d/10-tailscale.sh   [addon]       A/B health gate hook
usr/local/libexec/ab-health-check.d/20-cloudflared.sh [addon]       A/B health gate hook
usr/local/libexec/ab-health-check.d/30-sshd.sh        [addon]       A/B health gate hook
usr/local/libexec/ab-remote-access/ensure-tailscale.sh    [addon]   idempotent auth worker
usr/local/libexec/ab-remote-access/ensure-cloudflared.sh  [addon]   tunnel probe + restart
usr/local/libexec/ab-user-provision.sh                [fixes]       reads /etc/ab-users.json, applies hash
usr/local/libexec/ab-monitor/check.sh                 [reliability] main loop
usr/local/libexec/ab-monitor/state.sh                 [reliability] dedup state helpers
usr/local/libexec/ab-monitor/notify.sh                [reliability] dispatcher
usr/local/libexec/ab-monitor/ad-hoc-alert.sh          [reliability] OnFailure= worker
usr/local/libexec/ab-monitor/heartbeat.sh             [reliability] healthchecks.io pinger
usr/local/libexec/ab-monitor/checks/10-tailscale.sh       [reliability] check module
usr/local/libexec/ab-monitor/checks/20-cloudflared.sh     [reliability] check module
usr/local/libexec/ab-monitor/checks/30-sshd.sh            [reliability] check module
usr/local/libexec/ab-monitor/checks/40-ab-switch-age.sh   [reliability] check module
usr/local/libexec/ab-monitor/checks/50-ab-switch-status.sh [reliability] check module
usr/local/libexec/ab-monitor/checks/60-failed-units.sh    [reliability] check module
usr/local/libexec/ab-monitor/checks/70-disk-space.sh      [reliability] check module
usr/local/libexec/ab-monitor/checks/80-time-sync.sh       [reliability] check module
usr/local/libexec/ab-monitor/notifiers/sendgrid.sh        [reliability] email via SendGrid v3 Mail Send
usr/local/libexec/ab-monitor/notifiers/pagerduty.sh       [reliability] Events API v2 with dedup_key
usr/local/libexec/ab-monitor/notifiers/journal.sh         [reliability] structured journald
usr/local/sbin/ab-remote-access-status                [addon]       inspector
usr/local/sbin/ab-monitor-status                      [reliability] inspector
usr/local/sbin/ab-monitor-test                        [reliability] fire test alerts
usr/local/sbin/ab-enable-pam-u2f                      [security]    YubiKey enrollment; stages for rebuild
usr/local/sbin/ab-enroll-tpm-unlock                   [security]    systemd-cryptenroll --tpm2-pcrs=0+2+7 wrapper
```

---

## 4. Application steps

See `APPLY.md` in this overlay for the step-by-step procedure. TL;DR:

```
# From the root of debian-system-image-provisioning:
cp -r <overlay>/. .                # copy entire tree over yours
# Then apply the small diffs to build.sh / clean.sh / mkosi.finalize
# exactly as described in APPLY.md.
```

---

## 5. Validation matrix (before promoting to production)

### Build-host tests (in a VM is fine)

| Test                              | Command                                                    |
|-----------------------------------|------------------------------------------------------------|
| Lint clean                        | `./scripts/lint.sh`                                        |
| Secrets shape + perms             | `./scripts/verify-build-secrets.sh --strict`               |
| Build completes                   | `./build.sh --profile server --host <host>`                |
| Output image sanity               | `sudo ./scripts/verify-image-raw.sh`                       |

### Hardware-test USB (recommended before any production deploy)

| Test                              | Command                                                    |
|-----------------------------------|------------------------------------------------------------|
| USB writes + verifies readback    | `sudo ./scripts/usb-write-and-verify.sh --source mkosi.output/*.raw --target /dev/sdX` |
| Boots on real hardware            | reboot into USB via firmware menu                          |
| Tailscale auths                   | `tailscale status` shows BackendState=Running              |
| Cloudflared connects              | `curl -s localhost:45123/ready` shows readyConnections>=1  |
| SSH works from laptop             | `ssh user@<host>.<tailnet>.ts.net` with YubiKey touch      |
| SSH backup works                  | `ssh <user>@ssh.<domain>` via `cloudflared access ssh`     |
| Monitor self-test                 | `sudo ab-monitor-test` — email + PD page arrive            |
| Heartbeat works                   | `sudo systemctl list-timers ab-heartbeat.timer`            |
| Heartbeat fail-alert works        | stop the timer for 20 min, expect healthchecks.io alert    |
| nftables loaded                   | `sudo nft list ruleset`                                    |
| Sudoers tight                     | `sudo -k && sudo -v && sudo -l` — see new Defaults         |
| DNS over TLS                      | `resolvectl status` shows DNSSEC=yes, DNS over TLS=yes     |
| Watchdog armed                    | `systemctl status systemd-timedated 2>&1 \| grep -i watchdog` OR `wdctl` |
| A/B health gate runs              | `ab-status` shows healthy, boot count decremented          |
| Rollback works                    | deliberately break a service, confirm slot demotes on reboot |

### Post-deploy on real hardware (same checks above)

---

## 6. Known issues and TODOs

Things this overlay does NOT do, in rough descending priority:

### 6a. Untested end-to-end
Nothing in this overlay has been booted on hardware. I have only
syntax-checked with `bash -n` and lint-checked with `shellcheck
--severity=warning`, which is clean. **Before trusting the box with
Home Assistant, build in a VM and walk the validation matrix above.**
Treat every file as a prescription, not a tested artifact.

### 6b. The `AB_ENABLE_PAM_U2F=yes` build-time wiring is undefined
`ab-enable-pam-u2f` stages a mapping file and tells the user to
rebuild with `AB_ENABLE_PAM_U2F=yes`. That env var is not consumed
anywhere in the overlay yet. To close this, you need to add to your
`build.sh` (after `package-credentials.sh`):

```bash
if [[ "${AB_ENABLE_PAM_U2F:-no}" == "yes" ]]; then
    src=".mkosi-secrets/hosts/${HOST}/u2f-mappings"
    [[ -f "$src" ]] || fail "AB_ENABLE_PAM_U2F=yes but $src is missing"
    install -m 0644 -D "$src" "mkosi.extra/etc/u2f_mappings"
    # Ship our own complete /etc/pam.d/sudo that includes pam_u2f:
    install -m 0644 "mkosi.extra/etc/pam.d/sudo-u2f" \
                    "mkosi.extra/etc/pam.d/sudo.d/00-ab-u2f"
    # or, simpler, ship a full /etc/pam.d/sudo that has the line
    # already uncommented. Either way, this code is not present
    # in the overlay.
fi
```
Until this TODO is resolved, PAM-U2F enrollment is a no-op for sudo.

### 6c. Secure Boot + RootVerity not enabled
`docs/secure-boot-roadmap.md` covers the four phases; the overlay
only ships the TPM-enrollment helper (`ab-enroll-tpm-unlock`) and
no other wiring. Without verity, a local-root attacker can plant
persistence in the offline A/B slot's rootfs and rollback does not
save you.

### 6d. Fingerprint rotation is manual
`scripts/fetch-third-party-keys.sh` pins fingerprints at the values
observed in 2026-04. Cloudflare rotated the WARP signing key in late
2025 (per their docs); the `cloudflared` key may also rotate. Re-verify
annually. There is no automated rotation path.

### 6e. PCR set for TPM unlock is conservative
`ab-enroll-tpm-unlock` binds to PCRs 0+2+7 (firmware + option ROMs +
Secure Boot policy). This survives sysupdate-driven kernel changes
but does NOT detect a swapped UKI on the ESP. Binding to PCR 11 (UKI)
would catch that but requires re-enrollment on every sysupdate. The
current choice is "fails open on a swapped kernel, fails closed on
firmware/SB changes." Review per your threat model.

### 6f. The `40-ab-switch-age.sh` check assumes a specific marker path
It treats `/var/lib/ab-health/status.env` mtime as "last successful
bless". This matches the repo README's description but has not been
code-inspected against `ab-health-gate.service`. If the marker is
written elsewhere, adjust the path.

### 6g. The `50-ab-switch-status.sh` check assumes systemd-boot filename
conventions
It globs for `*.bad.*` and `*+0-[1-9]*` in `/boot/loader/entries/`.
`+0-N` is definitely correct (tries_left=0, tries_done>=1). `.bad.`
is less certain; systemd-boot uses filename-based counters, not a
`.bad` suffix. Leaving the pattern in because it is a cheap
belt-and-suspenders, but the real detection path is the `+0-N` glob.

### 6h. No fail2ban / sshguard
SSH is pubkey-only with verify-required and rate-limited at the
firewall. A real brute-force is therefore useless; the only cost is
log noise. If the noise bothers you, add fail2ban and a `recent`
module nft rule. Not shipped because the marginal security is close
to zero.

### 6i. No AppArmor profiles shipped
The sysctls enable AppArmor support but we do not ship profiles. The
Debian default packages bring a handful of profiles automatically
via their postinst scripts; those remain active. If you want strict
confinement for Home Assistant, cloudflared, or anything else, write
a profile and drop it in `/etc/apparmor.d/` via a host overlay.

### 6j. No auditd
auditd generates a lot of log volume for marginal benefit on a home
host. If you want it, add `auditd` + an `audit.rules` drop-in.

### 6k. No per-service AppArmor / systemd-nspawn isolation for HA
Home Assistant is typically run via Docker/Podman. The overlay does
not ship a `systemd-nspawn` or sandboxed unit for it. If you want a
locked-down HA, add a custom unit with `ProtectSystem=strict`,
`NoNewPrivileges=yes`, `DynamicUser=yes` where possible, and a
dedicated subvolume on `/home` or `/mnt/data`.

### 6l. The three-bundle integration order in build.sh is undocumented
You must call `verify-build-secrets.sh` → `package-credentials.sh` →
`package-alert-credentials.sh` in that order before mkosi. APPLY.md
shows the exact sequence. `package-alert-credentials.sh` will fail
loudly if `credential.secret` is missing, so mis-ordering is caught.

### 6m. mkosi.conf adjustments not automated
`mkosi.conf` is untouched by this overlay. You still need to:
- Remove `ExtraTrees=.mkosi-secrets:/` (the footgun we moved away from)
- Keep `RootPassword=!` and `RootShell=/bin/false` (already good)
- Decide whether to also set `RootVerity=signed` (Phase 1 of the roadmap)

See APPLY.md section "Changes to existing files" for the specific edits.

### 6n. No unit-enablement presets shipped
The overlay ships systemd units but does not include
`/etc/systemd/system-preset/90-ab.preset` or edits to `mkosi.finalize`
to enable them. APPLY.md section "Unit enablement" shows the options.

### 6o. Home Assistant-specific firewall/monitor hooks not included
The nftables baseline blocks port 8123. You need a per-host override
(`hosts/homeassistant/mkosi.extra/etc/nftables.conf.d/50-ha.nft`).
The monitor has no "HA is responding" check; if you want it, add
`checks.d/90-homeassistant.sh` that curls `http://localhost:8123/`
and parses status.

### 6p. No USB device allow-list
A hostile USB device (BadUSB, etc.) can still be plugged in and
enumerate. To harden, use `usbguard` (not shipped) or `dev.tty.ldisc_autoload=0`
+ udev rules that require explicit authorization. Only relevant if
someone can physically touch the box.

### 6q. Nothing kills a stale user session after monitor reboot
If you are SSH'd in when the watchdog kicks, your session is gone
with no warning. That is the point, but a `broadcast-before-reboot`
timer would be nicer. Not shipped.

---

## 7. How to double-check this work (for a reviewer)

If someone else (another chat, a coworker, future-you) needs to
verify everything here:

1. **Architecture review.** Read section 2 above. The three-path
   alerting design (active + dead-man's + journal) is the critical
   claim. Sanity: "if only 1 of {active, dead-man's, journal} was
   shipped, which failures would go unreported?" Active alone: misses
   power loss. Dead-man alone: does not tell you WHICH subsystem is
   failing. Journal alone: forensic only, no page.

2. **Secrets flow.** Trace one secret end-to-end: the Tailscale auth
   key. It lives on build host at `.mkosi-secrets/tailscale-authkey`
   (0600, gitignored). `scripts/verify-build-secrets.sh` asserts
   permissions, format (`tskey-auth-...`), and that git does not
   track it. `scripts/package-credentials.sh` encrypts it via
   `systemd-creds encrypt --with-key=host --host-key-path
   mkosi.extra/var/lib/systemd/credential.secret` into
   `mkosi.extra/etc/credstore.encrypted/tailscale-authkey`. On the
   booted image, `tailscale-up.service` declares
   `LoadCredentialEncrypted=tailscale-authkey:/etc/credstore.encrypted/tailscale-authkey`
   which systemd decrypts into `$CREDENTIALS_DIRECTORY` for the
   lifetime of that process only. `ensure-tailscale.sh` reads
   `$CREDENTIALS_DIRECTORY/tailscale-authkey` and passes it to
   `tailscale up --authkey=`. The plaintext never lives on disk
   inside the image.

3. **Credential.secret threat model.** This key encrypts the credstore
   using a symmetric key baked into the image at
   `/var/lib/systemd/credential.secret` (mode 0400 root). Anyone
   with the image file can recover plaintext. That is the same
   property as "plaintext on disk mode 0600 root" — no worse. The
   win is the organizational discipline: the ONLY ways a secret
   lands in the image are via `package-credentials.sh` (validated,
   named, encrypted) and `package-alert-credentials.sh`. No
   accidental `ExtraTrees=.mkosi-secrets:/` leakage. The upgrade
   path is `--with-key=tpm2` after Secure Boot + verity are wired
   up (see roadmap).

4. **Dedup state correctness.** `state.sh::state_transition`'s state
   table is 5 lines of case:
   - ok→fail OR unknown→fail: **trigger**
   - fail→fail within dedup window: **skip**
   - fail→fail past dedup window: **trigger** (reminder)
   - fail→ok: **resolve**
   - ok→ok OR unknown→ok: **skip**
   Verify by reading the bash `case "${prev_status}|${new_status}" in`
   block. PagerDuty also dedups on `dedup_key=<host>-<alert_key>`,
   so even if our local dedup has a bug, PD will not page 100 times.

5. **Fingerprint verification.** Run:
   ```
   curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
     | gpg --with-colons --fingerprint 2>/dev/null \
     | awk -F: '$1=="fpr" {print $10}'
   ```
   Should emit `2596A99EAAB33821893C0A79458CA832957F5868`. Same
   pattern for Cloudflare:
   ```
   curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
     | gpg --with-colons --fingerprint 2>/dev/null \
     | awk -F: '$1=="fpr" {print $10}'
   ```
   Should emit `FBA8C0EE63617C5EED695C43254B391D8CACCBF8`.

6. **Shellcheck.** From the repo root after application:
   ```
   ./scripts/lint.sh
   ```
   Should exit 0. If it does not, something was transcribed wrong.

7. **Unit parse.** For each `.service` / `.timer` under
   `mkosi.extra/etc/systemd/system/`:
   ```
   systemd-analyze verify <path-in-a-test-image>
   ```
   Cannot be run against the raw .service files outside an image
   because they reference paths that only exist inside; test inside
   the built image via `systemctl daemon-reload && systemctl status`.

8. **Integration check.** After applying, `git diff` vs upstream
   should show: additions to `mkosi.extra/`, `docs/`, `scripts/`,
   `mkosi.conf.d/`, `mkosi.repart/`; replacements of `.gitignore`
   and `.users.json.sample`; no changes to other top-level files.
   Any additional diff is something that went wrong in the copy.

---

## 8. Bundled document cross-reference

For deeper reads on specific parts:

| If you want to understand…                        | Read…                              |
|---------------------------------------------------|------------------------------------|
| Tailscale + Cloudflare + SSH end to end           | `docs/remote-access.md`            |
| The password_hash workflow                        | `docs/user-provisioning.md`        |
| Why dd exit 0 is insufficient                     | `docs/live-usb-verification.md`    |
| Alert paths, dedup, how to extend                 | `docs/alerting.md`                 |
| What to do when your phone pages you              | `docs/runbook.md`                  |
| Verity + UKI signing + TPM phases                 | `docs/secure-boot-roadmap.md`      |
| Ordered security changes + what breaks on apply   | `docs/hardening-walkthrough.md`    |
| Step-by-step application of this overlay          | `APPLY.md`                         |

---

## 9. Version / provenance

- Produced: 2026-04-17 by a multi-turn synthesis against
  `bashirsouid/debian-system-image-provisioning@main` (as observed
  via web_fetch of the GitHub HTML).
- Signing-key fingerprints verified against multiple independent
  sources on the date above. Re-verify before relying on them.
- No file in this overlay has been executed against a real Debian
  trixie build. This is a reviewed prescription.
