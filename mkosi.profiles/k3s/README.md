# k3s

Single-node Kubernetes via Rancher's `get.k3s.io` install script, run as
a **first-boot oneshot** (`mkosi.extra/etc/systemd/system/k3s-install.service`):
on the first boot with network the unit downloads and installs k3s
(`/usr/local/bin/k3s` + a generated `k3s.service`) and drops an install
marker so later boots skip it. The generated `k3s.service` keeps the
node running afterwards.

No secret values are required unless otherwise documented.

## What this profile ships besides the installer

| File | Purpose |
| --- | --- |
| `/etc/rancher/k3s/config.yaml` | `resolv-conf: /run/systemd/resolve/resolv.conf`. The base image uses systemd-resolved's 127.0.0.53 stub, which is unreachable from pod netns — without this CoreDNS cannot resolve anything. This file is owned by this profile; do not ship it from other profiles (mkosi extra composition is last-writer-wins per path). |
| `/etc/nftables.conf.d/input/60-k3s.nft` | Opens input for `cni0`, `flannel.1`, `veth*`, pod/service CIDRs. The base firewall is default-drop; without these rules NodePort and pod traffic is silently dropped. |
| `/etc/nftables.conf.d/forward/60-k3s.nft` | Opens forward for `cni0`, `flannel.1`. Enables NodePort DNAT and pod-to-pod/service forwarding. |

## Version pinning and install overrides

The installer unit reads two optional env files:

1. `/etc/default/ab-k3s-install` — user pin file. Set
   `INSTALL_K3S_VERSION=vX.Y.Z` here to pin a release.
2. `/etc/default/ab-k3s-extra` — profile-owned adjustments (shipped by
   e.g. `k3s-proxy`, which sets
   `INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb"`). Read
   after #1, so on variable conflicts the profile wins.

## Interaction with persistent-storage profiles

The installer declares `After=ab-symlink-k3s.service`, so when the
`symlink-k3s` profile is selected the DATA-partition symlinks exist
before k3s writes any state (ordering-only references to units that are
not shipped are ignored by systemd, so plain builds are unaffected).

## Firewall note for multi-node clusters

This profile assumes single-node: no WAN rule exists for flannel VXLAN
(udp/8472). Multi-node would additionally need that port allowed
between nodes.
