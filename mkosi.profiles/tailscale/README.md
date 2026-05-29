# tailscale

Tailscale mesh VPN. Reads a `tailscale-authkey` credential at first boot and
connects the machine to your Tailscale network via `tailscale-up.service`. A
watchdog timer re-authenticates if the backend state drops.

## Required secrets

| Secret | Vault key | Notes |
| --- | --- | --- |
| `tailscale-authkey` | `"tailscale-authkey"` | Reusable pre-auth key from the Tailscale admin console |

For per-host keys, add under `hosts.<hostname>."tailscale-authkey"` in the
vault. See `docs/remote-access.md` for setup and rotation.

## What this profile provides

* `tailscaled.service` — Tailscale daemon (enabled on install)
* `tailscale-up.service` — authenticates on first boot and on re-auth events
* `tailscale-watchdog.timer` — re-auth check every 10 minutes
* Health-check hook — fails the A/B health gate if Tailscale is not connected
