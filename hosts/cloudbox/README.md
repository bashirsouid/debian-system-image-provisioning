# cloudbox host overlay

This overlay targets an ARM64 server-style machine for testing the native
`systemd-repart` + `systemd-sysupdate` + `systemd-boot` path.

Use it with the `server` profile:

```bash
./build.sh --profile server --host cloudbox
```

What it changes:

- forces `Architecture=arm64`
- sets the hostname to `cloudbox`
- provides a host-specific kernel command line via `kernel-cmdline.extra`

The `server` profile itself picks the kernel metapackage by architecture:

- `linux-image-amd64` on x86-64
- `linux-image-arm64` on arm64

Notes:

- this is intentionally a server-only overlay; it does not pull in Xorg,
  AwesomeWM, or Liquorix
- the default kernel command line enables serial-console-friendly settings for
  cloud testing
