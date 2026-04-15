# evox2 host overlay

This overlay is an example workstation-oriented host overlay.

Use it with:

```bash
./build.sh --profile devbox --host evox2
```

What it currently provides:

- an example `/home` mount in `mkosi.extra/etc/fstab`
- a host-specific kernel command line in `kernel-cmdline.extra`

The `/home` example keeps mutable user data outside the retained root versions.
Edit the `/etc/fstab` source in this overlay before using it on a real machine.
