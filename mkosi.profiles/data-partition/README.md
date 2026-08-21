# data-partition

Mounts a same-disk GPT partition labeled `DATA` at `/mnt/data`, lazily,
via systemd's automount support. This is for hosts with a physically
repartitioned data slice on the boot disk (e.g. a laptop with a
custom partition layout).

Ships:
- `/etc/fstab` entry: `PARTLABEL=DATA /mnt/data ext4
  noauto,nofail,x-systemd.automount,x-systemd.device-timeout=2s 0 2`.
  `nofail` + lazy automount means boot proceeds cleanly even if no
  `DATA` partition exists on a given disk.

Mutually exclusive with the `data-disk` profile — both target
`/mnt/data`, so a host must select exactly one, never both, or you'll
get two competing automount definitions for the same mountpoint.
Choose `data-partition` if the data lives on a partition of the boot
disk; choose `data-disk` if it's a wholly separate attached block
device (e.g. a second OCI volume) with no partition table.
