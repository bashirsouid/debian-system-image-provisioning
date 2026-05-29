# devbox

Desktop workstation base. Installs the Liquorix performance kernel and
`spice-vdagent` (clipboard, resolution sync for QEMU/virt guests). Pair with
other profiles to build a full workstation image:

```sh
# Full desktop build example
./build.sh --profile "devbox awesomewm dev-tools ssh-server tailscale" --host mymachine
```

## No secrets required

This profile does not require any secrets. Secrets come from the profiles you
compose with it (`tailscale`, `cloudflare-tunnel`, `ssh-server`, etc.).

## Notes

* Liquorix is x86-64 only. On ARM64 or other arches, use the `server` profile
  and add desktop profiles on top.
* `dpkg` and `kmod` are kept in the image and mkosi package-metadata cleanup is
  disabled because purging `dpkg` can cause `kmod` auto-removal to fail
  (`kmod` maintainer scripts call `dpkg-maintscript-helper`).
* `spice-vdagent` is only useful when running as a QEMU guest. It is harmless
  on baremetal.
