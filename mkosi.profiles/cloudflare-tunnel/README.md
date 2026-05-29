# cloudflare-tunnel

Cloudflare Named Tunnel outbound-only connector. Gives backup SSH reachability
when Tailscale is unavailable or when UDP is blocked. Configures
`cloudflared.service` and a watchdog that restarts the tunnel if the health
endpoint stops responding.

## Required secrets

| Secret | Vault key | Notes |
| --- | --- | --- |
| `cloudflared-token` | `"cloudflared-token"` | Install token from Cloudflare Zero Trust → Networks → Tunnels |

For per-host tokens, add under `hosts.<hostname>."cloudflared-token"` in the
vault. Each host needs its own tunnel connector in the Cloudflare dashboard.
See `docs/remote-access.md` for setup and the SSH public-hostname config.

## What this profile provides

* `cloudflared.service` — runs the tunnel (enabled on install)
* `cloudflared-watchdog.timer` — probes `/ready` every 5 minutes and restarts
  the service if unhealthy
* Health-check hook — fails the A/B health gate if the tunnel is not connected
