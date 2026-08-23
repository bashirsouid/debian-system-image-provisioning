# symlink-k3s

Persists K3s state and container storage across A/B root swaps by
symlinking `/var/lib/rancher/k3s` and `/var/lib/containers` to the
DATA partition (`/mnt/data/k3s`, `/mnt/data/containers`).

## What this profile ships

| File | Purpose |
| --- | --- |
| `/usr/local/libexec/ab-symlink-k3s` | Idempotent first-boot script: ensures parents, **adopts baked seed content** (e.g. `server/manifests` from the image), then replaces real dirs with symlinks via `ln -sfn`. |
| `/etc/systemd/system/ab-symlink-k3s.service` | Oneshot, `After=local-fs.target`, `Before=k3s-install.service k3s.service`. Runs once per root slot (marker at `/var/lib/ab-symlink-k3s/done`). |

## Why the adoption logic matters

If another profile (e.g. `k3s-hello-world`) bakes content into
`/var/lib/rancher/k3s/server/manifests/` at build time, that path
exists as a **real directory** in the image. The old one-liner
`ln -sf /mnt/data/k3s /var/lib/rancher/k3s` would create the symlink
*inside* that directory instead of replacing it, silently defeating
persistence. The new script detects a real directory, **migrates its
content into `/mnt/data/k3s` with `cp -an` (no-clobber)**, then
replaces it with the symlink — so seed manifests are adopted on first
boot, and evolved runtime state is preserved on later boots / A/B swaps.

## Ordering guarantees

- `After=local-fs.target` — DATA partition (`data-disk` or
  `data-partition`) is mounted (or lazy automount triggered).
- `Before=k3s-install.service k3s.service` — symlinks exist **before**
  the k3s installer runs, so the generated `k3s.service` writes all
  state (etcd, containerd, manifests) into `/mnt/data/k3s`.

The k3s profile's installer unit declares `After=ab-symlink-k3s.service`
to match.

## Retry behavior

If `/mnt/data` is not present when the unit runs (e.g. a test build
without a data disk), the script logs a warning, exits 0 **without**
writing the done marker. The next boot retries. This keeps the service
from permanently failing on hosts that accidentally select this profile
without a DATA partition.

## Pairing

- `data-disk` or `data-partition` (mutually exclusive; provides `/mnt/data`).
- `k3s` (the thing being persisted).
- `symlink-caddy` (separate profile for Caddy cert persistence).

## Architecture

No architecture pinning; works on amd64 and arm64 alike.