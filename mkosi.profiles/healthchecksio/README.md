# healthchecksio

Dead-man's-switch heartbeat to [healthchecks.io](https://healthchecks.io).
Pings a check URL on a regular schedule; if the ping stops arriving, Healthchecks
alerts you. Useful for detecting silent failures (machine off, network down,
systemd unit crashed) without actively polling the machine.

## Required secrets

| Secret | Vault key | Notes |
| --- | --- | --- |
| `healthchecks-ping-url` | `"healthchecks-ping-url"` | Ping URL from the Healthchecks dashboard (e.g. `https://hc-ping.com/...`) |

For per-host URLs, add under `hosts.<hostname>."healthchecks-ping-url"` in the
vault.

## What this profile provides

* A systemd timer that pings the URL on a configured schedule
* Integration with the A/B health gate — the heartbeat is sent after a
  successful boot only
