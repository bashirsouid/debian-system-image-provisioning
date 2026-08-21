# cloud-networking

systemd-networkd + DHCP for headless cloud/hypervisor VMs (OCI, other
clouds, QEMU/KVM guests) with a single wired NIC and no WiFi. This repo
masks systemd-networkd by default because most existing hosts use the
`wifi` profile's NetworkManager stack; this profile is the wired-only
alternative for server-class images that don't need NetworkManager's
D-Bus/PolicyKit dependency chain or WiFi roaming features.

Do not combine this profile with the `wifi` profile on the same host -
they both try to own network configuration and will conflict.

Ships:
- `/etc/systemd/network/20-dhcp.network` - DHCP on any `en*`- or `eth*`-named
  interface (matches typical virtio-net / systemd predictable naming on
  cloud hypervisors).
- `/etc/systemd/system-preset/10-cloud-networking.preset` - enables
  `systemd-networkd.service` and `systemd-networkd.socket`, with a
  filename that sorts before the base `90-ab.preset` so it wins for
  these specific units.
- `/etc/cloud-networking.marker` - sentinel file checked by
  `mkosi.finalize.d/30-systemd-tweaks.sh` to skip masking
  systemd-networkd for images that include this profile.
