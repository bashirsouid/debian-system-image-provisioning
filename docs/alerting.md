# Alerting architecture

Three independent paths so one failure mode never silences all of
them:

1. **Active alerts** (SendGrid email + PagerDuty paging)
   - Runs on the host via `ab-monitor.timer` every 5 minutes.
   - Detects known failure modes (Tailscale down, cloudflared down,
     SSH down, A/B stale, etc.) and sends targeted notifications.
   - Requires: the host is up, has outbound internet, and valid
     credentials for at least one channel.
   - Good for: distinguishing *which* subsystem failed while
     everything else is fine.

2. **Dead-man's switch** (healthchecks.io)
   - Runs on the host via `ab-heartbeat.timer` every 5 minutes.
   - POSTs to a private URL on healthchecks.io. Healthchecks alerts
     YOU if a ping does not arrive within its configured grace window.
   - Requires: the host is up and has outbound internet.
   - Good for: catching total outages (power, kernel panic, network
     totally down, monitor itself broken) that the active path
     cannot report.

3. **Journal of record**
   - Every alert is written to the local journal with structured
     fields before any outbound attempt.
   - Requires: nothing beyond a working journald.
   - Good for: post-mortem forensics, including cases where BOTH
     outbound paths were broken.

## Why not just PagerDuty for everything

PagerDuty's paging path is best-in-class for "something went wrong
and I need to know right now." But it requires an active POST from
the monitored host. If the host is dead, PD never knows.

healthchecks.io exists precisely to cover that gap. It's simple:
you ping, it waits, if it stops getting pings it alerts. Free tier
is enough for a handful of hosts.

## Why SendGrid on top of PagerDuty

Two reasons:

1. Not every alert is pageable. Disk at 90% full is a warning, not
   an incident. PD with `AB_MONITOR_PD_MIN_SEVERITY=error` (default)
   only pages on `error`/`critical`. Email gets *everything*.
2. If PagerDuty itself is having a bad day (it happens), you still
   have email. Belt and suspenders.

If you are on a tight budget and PD is cost-prohibitive, you can
run email-only by setting `AB_MONITOR_CHANNELS="sendgrid"` and
still get healthchecks.io's missed-ping escalation as the paging path.

## Dedup and escalation

State file at `$AB_MONITOR_STATE_DIR/state.json`. For each alert
key, we track:

- `status` (ok | fail)
- `first_detected` — timestamp of the first fail
- `last_changed` — timestamp of the most recent status flip
- `last_notified` — timestamp of the most recent outbound notification
- `notified_count` — how many notifications we've sent

On every check, `state_transition` in `state.sh` computes the next
action from (prev_status, new_status, time_since_last_notified):

| Prev | New  | Action                                                        |
|------|------|---------------------------------------------------------------|
| ok   | fail | **trigger** — send email + PD trigger                         |
| fail | fail | **skip** if last_notified < 24h ago                           |
| fail | fail | **trigger** (reminder) if last_notified >= 24h ago            |
| fail | ok   | **resolve** — send email + PD resolve                         |
| ok   | ok   | skip                                                          |

PagerDuty's own deduplication (via `dedup_key = <host>-<alert_key>`)
handles the "I got 50 emails about the same thing" problem on the PD
side, but we also locally suppress email floods.

Tune the reminder cadence with `AB_MONITOR_REMIND_AFTER_SECS`.

## State lives on the rootfs slot

State is under `/var/lib/ab-monitor/` by default. `/var/lib` is on
the A/B root partition, so when you flip slots, the state resets.
That is intentional: an A/B switch is a momentous event, and the
first checks after a slot flip act as a proactive post-switch health
report.

If you want state to survive A/B, set
`AB_MONITOR_STATE_DIR=/home/.ab-monitor` in a host overlay. `/home`
is on its own partition per the repo's storage model and persists
across slot flips.

## Extending: adding a new check

1. Create `/usr/local/libexec/ab-monitor/checks.d/42-myname.sh` in
   your host overlay. Executable, 0755.
2. Have it emit ONE line of JSON on stdout:
   ```json
   {"key":"my_thing_broken","status":"fail","severity":"warning",
    "summary":"concise one-liner","details":{"any":"extra","data":42}}
   ```
3. Return exit 0 even when reporting fail.
4. That's it. On the next timer tick, the main loop will pick it up,
   dedup it, and notify through all configured channels.

Key names (`"key"`) should be stable and lowercase_snake_case because
they double as PagerDuty `component` and as anchors in the runbook.
Keep them short.

## Extending: adding a new notifier

Drop a file at
`/usr/local/libexec/ab-monitor/notifiers/<name>.sh`, then include
`<name>` in `AB_MONITOR_CHANNELS`. The notifier reads the
`AB_*` env vars that `notify.sh` exports and POSTs/emails/calls as
appropriate. Look at `sendgrid.sh` for the pattern.

## OnFailure= integration

Any systemd unit you want to page on immediately (without waiting
for the 5-minute timer) can add:

```
OnFailure=ab-monitor-alert@%n.service
```

This fires an instant alert. The template unit routes through the
same dedup state so a flapping unit cannot page you 100 times.

Good candidates: `ab-health-gate.service`, `systemd-bless-boot.service`,
`sysupdate.service`, any home-automation service you run on the box.
