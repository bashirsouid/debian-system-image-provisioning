# data-disk

Formats (idempotently, once) and mounts a separate, wholly unpartitioned
attached block device at `/mnt/data`, lazily, via systemd's automount
support. This is for hosts where the data disk has no partition table at
all — e.g. an OCI Compute instance with a second paravirtualized volume
attached as `/dev/sdb`.

Ships:
- `/usr/local/sbin/ab-data-disk-format` — idempotent oneshot script;
  formats `/dev/sdb` as ext4 with `LABEL=data` only if it has no
  existing filesystem signature. Safe to run on every boot.
- `ab-data-disk-format.service` (`WantedBy=multi-user.target`) — runs
  the above once per boot. No `local-fs.target` ordering, so there is no
  ordering-cycle risk.
- `/etc/fstab` entry: `LABEL=data /mnt/data ext4
  nofail,x-systemd.automount,x-systemd.device-timeout=30s 0 2`.

Mutually exclusive with the `data-partition` profile — both target
`/mnt/data`, so a host must select exactly one, never both.

The device path is hardcoded to `/dev/sdb` since only `cloudbox`
currently uses this profile. If a second host needs this with a different
device path, parameterize `DEVICE` via a host-descriptor key rather than
hardcoding a second value here.
