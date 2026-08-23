# k3s-proxy

Host-level **Caddy** reverse proxy that terminates public TLS for
services published by the local k3s cluster (NodePort backends). The
profile also disables k3s' bundled **Traefik** ingress controller and
**ServiceLB**, which would otherwise bind host ports 80/443 and conflict
with Caddy.

## What this profile ships

| File | Purpose |
| --- | --- |
| `Packages=` | `caddy` — from Debian trixie main (native amd64 + arm64 packages; no third-party repo / `apt-keys.conf` needed). |
| `/etc/caddy/Caddyfile` | Placeholder site block (`http://:80 { respond ... }`). Replaced at build time by `host-descriptor.sh` when the host descriptor defines `k3s_proxy_domain = <fqdn>` (and optional `acme_email`). |
| `/etc/nftables.conf.d/input/61-k3s-proxy.nft` | Opens inbound TCP 80/443 and UDP 443 (HTTP/3 QUIC) in the base default-drop firewall. |
| `/etc/default/ab-k3s-extra` | `INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb"`. Read by `k3s-install.service` **after** the user's `/etc/default/ab-k3s-install`, so profile flags win on conflicts. |
| `/etc/systemd/system-preset/92-k3s-proxy.preset` | `enable caddy.service` (belt-and-braces; Debian postinst also enables). |

## TLS configuration (host descriptor)

Add to `hosts.local/<host>.conf`:

```
k3s_proxy_domain = hello.example.com
acme_email       = you@example.com   # optional; Let's Encrypt account email
```

The descriptor renderer (`scripts/lib/host-descriptor.sh`) generates a
real Caddyfile with automatic HTTPS and a site block reverse-proxying
to `127.0.0.1:30080` (the NodePort used by `k3s-hello-world`). Without
`k3s_proxy_domain`, the placeholder Caddyfile ships and Caddy serves
HTTP-only on port 80.

## Interaction with k3s

The k3s profile's installer reads `EnvironmentFile=-/etc/default/ab-k3s-extra` in addition to the user pin file. This profile's file disables k3s' built-in Traefik + ServiceLB, freeing 80/443 for Caddy.

## Pairing with persistent certs

To persist ACME certs + account across A/B root swaps, also select the
`symlink-caddy` profile (symlinks `/var/lib/caddy` → `/mnt/data/caddy`
and chowns to the `caddy` user). It is a standalone atomic profile;
pairing is documented here, not enforced via `requires=`.

## Architecture

Caddy comes from Debian main — native `amd64` and `arm64` packages. No
architecture pinning in this profile; the descriptor's `Architecture=`
drives apt's selection at build time.