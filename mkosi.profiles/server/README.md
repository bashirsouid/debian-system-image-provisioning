# server

Minimal headless CLI baseline. No desktop stack, no window manager, no graphics
packages. The recommended starting point for any server, VM, or cloud instance.
Compose with other profiles for production use:

```sh
# Typical production server build
./build.sh --profile "server ssh-server tailscale cloudflare-tunnel healthchecksio" --host myserver
```

## No secrets required

This profile does not require any secrets itself. Secrets come from the profiles
you compose with it.

## Kernel

On x86-64: `linux-image-amd64` (Debian stock kernel).
On ARM64: `linux-image-arm64`.

The kernel is selected by the base mkosi config; the `server` profile does not
override it. Use the `kernel-6-18` profile to pull a newer kernel from
`trixie-backports`.
