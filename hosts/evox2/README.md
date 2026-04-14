# evox2 host overlay

This overlay is an example of how to move `/home` out of the image for a specific
machine while keeping the generic base image unchanged.

Current behavior:

- overlays `/etc/fstab` with a single `/home` mount entry
- expects a persistent partition labeled `HOME`
- uses `nofail,x-systemd.automount` so boot does not hard-fail if the partition is absent

Typical use:

```bash
./build.sh --profile devbox --host evox2
```

Before using this on bare metal, change the line in `mkosi.extra/etc/fstab` to the
actual identifier and filesystem type for the target machine.
