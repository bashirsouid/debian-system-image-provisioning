# symlink-docker

Persists Docker storage (`/var/lib/docker`) across A/B root swaps by
symlinking it to the DATA partition (`/mnt/data/docker`).

## What this profile ships

| File | Purpose |
| --- | --- |
| `/usr/local/libexec/ab-symlink-docker` | Idempotent first-boot script: adopts baked content, replaces real dir with symlink via `ln -sfn`. |
| `/etc/systemd/system/ab-symlink-docker.service` | Oneshot, `After=local-fs.target`, `Before=docker.service`. Runs once per root slot (marker at `/var/lib/ab-symlink-docker/done`). |
| `/etc/systemd/system-preset/93-symlink-docker.preset` | `enable ab-symlink-docker.service` |

## Why the adoption logic matters

If the image bakes content into `/var/lib/docker` at build time, that
path exists as a **real directory** in the image. The old one-liner
`ln -sf /mnt/data/docker /var/lib/docker` would create the symlink
*inside* that directory instead of replacing it, silently defeating
persistence. The new script detects a real directory, **migrates its
content into `/mnt/data/docker` with `cp -a --update=none` (no-clobber)**,
then replaces it with the symlink — so seed content is adopted on first
boot, and evolved runtime state is preserved on later boots / A/B swaps.

## Ordering guarantees

- `After=local-fs.target` — DATA partition (`data-disk` or
  `data-partition`) is mounted (or lazy automount triggered).
- `Before=docker.service` — symlink exists **before** the Docker daemon
  starts and writes any state.

The `docker` profile is not required; this profile is atomic and can be
selected independently. Pairing with `docker` is documented, not enforced.

## Retry behavior

If `/mnt/data` is not present when the unit runs (e.g. a test build
without a data disk), the script logs a warning, exits 0 **without**
writing the done marker. The next boot retries. This keeps the service
from permanently failing on hosts that accidentally select this profile
without a DATA partition.

## Architecture

No architecture pinning; works on amd64 and arm64 alike.