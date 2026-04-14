# cloudbox host overlay

This overlay targets an ARM64 server-style machine, intended for OCI Ampere/
Always Free style testing.

Use it with the `server` profile:

```bash
./build.sh --profile server --host cloudbox
```

What it changes:
- forces `Architecture=arm64`
- sets the hostname to `cloudbox`

The `server` profile itself now picks the kernel metapackage by architecture:
- `linux-image-amd64` on x86-64
- `linux-image-arm64` on arm64

Notes:
- this is intentionally a server-only overlay; it does not pull in Xorg,
  AwesomeWM, or Liquorix
- for Oracle Cloud ARM console access, a serial console is often useful, so the
  sample A/B config for this host includes `console=ttyAMA0,115200 console=tty1`
