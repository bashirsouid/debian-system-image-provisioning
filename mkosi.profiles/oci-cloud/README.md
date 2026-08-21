# oci-cloud

Everything needed to run a mkosi-built image as an Oracle Cloud
Infrastructure Compute instance, bundled into one profile so a
headless cloud host only needs to add this one name to its profile
list. This repo masks systemd-networkd and skips these fixes by
default because most existing hosts use the `wifi` profile's
NetworkManager stack and boot as fixed-size local/laptop images; a
cloud VM needs different networking and different first-boot disk
handling entirely.

Do not combine this profile with `wifi` on the same host - both try to
own network configuration and will conflict.

Ships:

- `/etc/systemd/network/20-dhcp.network` - DHCP on any `en*`/`eth*`
  interface.
- `/etc/systemd/system-preset/10-oci-cloud.preset` - enables
  `systemd-networkd.service`/`.socket` (sorts before the base
  `90-ab.preset` so it wins for these units).
- `/etc/oci-cloud.marker` - sentinel checked by two mechanisms:
  - `mkosi.finalize.d/30-systemd-tweaks.sh` skips masking
    systemd-networkd.
  - `build.sh`'s `apply_oci_cloud_fixes()` post-build step copies
    repart definitions into `/usr/lib/repart.d/` so root grows to fill
    the actual boot volume size on first real boot.

Persistent data storage on an OCI host is handled separately by the
`data-disk` profile (add it explicitly to a host's `profiles=` list
alongside `oci-cloud` if it has a second attached volume) — kept
separate since not every OCI host will necessarily have one.

Not needed for OCI with this setup: Oracle Cloud Agent. It's only
required for OCI console CPU/memory monitoring graphs and the Block
Volume Management plugin's auto-iSCSI-login feature - this repo uses
`paravirtualized` volume attachment instead, which needs neither.
