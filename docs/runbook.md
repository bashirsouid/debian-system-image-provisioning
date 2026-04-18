# Ops runbook

Read this from your phone when the page goes off. Anchors match the
alert keys you will see in PagerDuty / email subjects.

## Getting in

Primary path: Tailscale.
```
ssh <user>@<host>.<tailnet>.ts.net
```

Backup path: Cloudflare Tunnel. If Tailscale is the alert subject,
use this instead.
```
ssh <host>.<your-domain>      # ProxyCommand cloudflared access ssh is in ~/.ssh/config
```

If BOTH paths are unreachable, the monitor is probably also not
sending alerts — the page you just got may be from healthchecks.io
reporting no ping in 15 minutes. Skip to "box is fully dark."

## Quick triage, any alert

```
sudo ab-monitor-status             # full snapshot of monitor state
sudo ab-remote-access-status       # tailscale + cloudflared + sshd
systemctl --failed                 # any failed units?
journalctl -p err -b -n 100        # errors since boot
ab-status                          # current A/B slot + bootctl state
```

## Alert: `tailscale_down`

Meaning: `BackendState != Running`, or `tailscaled.service` is
inactive.

Steps:
1. `systemctl status tailscaled.service`
2. `tailscale status` — look for reason (NeedsLogin, Stopped, etc.)
3. If `NeedsLogin`: the auth key was revoked or expired. Generate a
   new reusable auth key in the Tailscale admin, write to
   `.mkosi-secrets/tailscale-authkey`, rebuild image, deploy via
   sysupdate. While offline on Tailscale, SSH in over the Cloudflare
   Tunnel backup path.
4. If daemon inactive: `systemctl restart tailscaled.service` and
   then `systemctl restart tailscale-up.service`.
5. If the watchdog timer is failing:
   `systemctl reset-failed tailscale-watchdog.service` to clear the
   rate-limit.

## Alert: `cloudflared_down`

Meaning: `/ready` metrics endpoint returned no ready connections, or
the service is inactive.

Steps:
1. `journalctl -u cloudflared.service -n 200 --no-pager`
2. Common causes in order of likelihood:
   - Token revoked in the Cloudflare dashboard → rebuild image with
     new token in `.mkosi-secrets/cloudflared-token`.
   - Upstream network blocking the tunnel (some ISPs / captive
     portals) → nothing to do at the host; revert via Tailscale.
   - cloudflared version too old → bumped on next image rebuild.
3. Restart is safe: `systemctl restart cloudflared.service`.
4. Tunnel should reach `readyConnections >= 1` within ~30s:
   ```
   curl -s http://127.0.0.1:45123/ready
   ```

## Alert: `sshd_down`

Meaning: sshd is not listening on port 22 (or the configured port).

Steps:
1. `systemctl status ssh.service`
2. `sshd -t` — does the config parse?
3. If `sshd -t` fails, recent config change went in with a syntax
   error. Either roll back via A/B (reboot, health gate will likely
   fail the new slot and revert) or edit `/etc/ssh/sshd_config.d/`
   from the Cloudflare Tunnel ssh path.

## Alert: `ab_stale`

Meaning: more than 7 days since a successful A/B bless on this slot.

Not a paging event; this is a warning. Indicates you have stopped
deploying updates. Either:
- deploy a new image (recommended: `./scripts/sysupdate-local-update.sh`),
- or adjust `AB_MONITOR_STALE_AB_SECS` in `/etc/default/ab-monitor`
  if 7 days is wrong for this host.

Ignoring this alert means security patches are piling up. Do not
ignore for more than 30 days.

## Alert: `ab_bad`

Meaning: at least one BLS entry in `/boot/loader/entries/` is marked
bad (all tries exhausted).

Steps:
1. `bootctl` — show which entry is current and which is bad.
2. `ls -la /boot/loader/entries/` — look for `*.bad.*` files.
3. If the current slot works but the other is bad: normal; an
   update failed health checks and rolled back. Check why:
   ```
   journalctl -u ab-health-gate.service -b -1    # previous boot
   ```
4. If BOTH slots look bad: boot will eventually stop finding a good
   entry. Escalate: you may need to bootstrap from the live USB.

## Alert: `failed_units`

Meaning: one or more systemd units are in `failed` state.

Steps:
1. `systemctl --failed`
2. For each: `journalctl -u <unit> -n 100 --no-pager`
3. Fix the immediate problem, then `systemctl reset-failed <unit>`
   to clear the alert.
4. If a unit keeps failing, add `Restart=on-failure` and
   `StartLimitBurst=` to its drop-in, or figure out the root cause.

## Alert: `disk_full`

Meaning: a watched mount is >= 90% (warning) or >= 95% (critical).

Steps:
1. `df -h /` `df -h /home` `df -h /var`
2. Most common culprit: journald logs. `journalctl --disk-usage`
   and `journalctl --vacuum-size=1G` if needed. The journald size
   caps in `/etc/systemd/journald.conf.d/20-ab-size.conf` should
   prevent this but can be overridden.
3. Docker / HA snapshots under `/home`? Check
   `~/homeassistant/backups/` or similar.

## Alert: `time_desync`

Meaning: `timedatectl` reports `NTPSynchronized=no`.

Steps:
1. `systemctl status systemd-timesyncd.service`
2. `timedatectl timesync-status`
3. Common causes: NTP port blocked by upstream router / ISP. Try
   `Chronyd` with `iburst` and fallback pool servers.

Why this matters: without correct time, TLS certs look invalid and
ALL outbound alerts (SendGrid, PagerDuty, healthchecks.io) fail
closed. This is a silent-alert-disabling bug and deserves urgent
fixing.

## Box is fully dark

You got a healthchecks.io "missed heartbeat" page but cannot SSH in
over any path.

1. Is the box powered? Check smart plug, UPS, physical LED.
2. Is the network switch up? Ping the router from another device.
3. If you believe the box is up but network is down: forced reboot
   via IPMI / remote PDU. The hardware watchdog should already have
   tried a reboot within the last minute.
4. If a reboot does not recover it: boot the live-test USB (see
   `docs/live-test-usb.md`), use it as a recovery environment,
   and run `/root/INSTALL-TO-INTERNAL-DISK.sh` only as a last
   resort.

## Testing alerts after a deploy

```
sudo ab-monitor-test
```

Fires one trigger + one resolve through every configured channel
(SendGrid, PagerDuty, healthchecks.io is not triggered from here —
that one you test by stopping `ab-heartbeat.timer` for 20 minutes
and watching for the missed-ping email).

You should see:
- one email in your inbox,
- one PagerDuty incident that auto-resolves 3 seconds later,
- journald entries under `ab-monitor AB_MONITOR_KEY=monitor_self_test`.

If any of those do not arrive, fix that BEFORE trusting the system
with a real alert.
