# symlink-caddy

Persists Caddy TLS certificates, ACME account, and autosave config
across A/B root swaps by symlinking `/var/lib/caddy` to the DATA
partition (`/mnt/data/caddy`) and ensuring the `caddy` user owns it.

## What this profile ships

| File | Purpose |
| --- | --- |
| `/usr/local/libexec/ab-symlink-caddy` | Idempotent first-boot script: adopts baked content, chowns to `caddy:caddy`, replaces with symlink via `ln -sfn`. |
| `/etc/systemd/system/ab-symlink-caddy.service` | Oneshot, `After=local-fs.target`, `Before=caddy.service`. Runs once per root slot (marker at `/var/lib/ab-symlink-caddy/done`). |
| `/etc/systemd/system-preset/93-symlink-caddy.preset` | `enable ab-symlink-caddy.service` |

## Why chown matters

The Debian `caddy` package runs the service as user `caddy` (home
`/var/lib/caddy`). Certificates and ACME account are stored under
`/var/lib/caddy/.local/share/caddy/`. If the symlink target
(`/mnt/data/caddy`) is not owned by `caddy:caddy`, Caddy cannot write
renewed certs or its autosave JSON. The script guards with
`getent passwd caddy` and chowns recursively after migration.

## Ordering guarantees

- `After=local-fs.target` — DATA partition mounted.
- `Before=caddy.service` — symlink + chown complete **before** Caddy
  starts and writes any certs.

## Retry behavior

Same as `symlink-k3s`: if `/mnt/data` absent, logs warning, exits 0
without marker → next boot retries. No permanent failure on hosts
without a DATA partition.

## Pairing

- `data-disk` or `data-partition` (provides `/mnt/data`).
- `k3s-proxy` (the Caddy service being persisted). This profile is
  atomic and does not `require=` k3s-proxy; pairing is documented, not
  enforced.

## Architecture

No architecture pinning; works on amd64 and arm64 alike.