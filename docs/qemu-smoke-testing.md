# QEMU smoke testing

`./run.sh` boots the most-recently-built image in a QEMU VM so you can
verify the image works before committing it to a flash. It defaults to
an **ephemeral snapshot** — the real `image.raw` under `mkosi.output/`
is never written to by the VM.

This doc covers the diagnostic flags. For day-to-day happy-path use,
`./run.sh` with no arguments is usually all you need.

## The happy path

```bash
./build.sh --profile devbox
./run.sh
```

The VM opens in a QEMU GUI window. Log in with the user you defined in
`.users.json` (the sample ships `demo` / `change-me-now`). For the
devbox profile, `startx` starts AwesomeWM.

If you get here, the image works and you can move on to hardware-test
USB (see `docs/live-test-usb.md`) or flashing.

## When it won't boot

The three diagnostic flags exist because a GUI QEMU window that flashes
and dies gives you no information. They are not production options.

### Step 1 — is the root tree itself broken?

```bash
./run.sh --boot-nspawn
```

This runs `mkosi boot` (systemd-nspawn) instead of `mkosi vm`. It
bypasses firmware, the bootloader, the UKI, and the initrd entirely.

- **If `--boot-nspawn` works but the regular VM does not:** your root
  filesystem is fine; the break is in the boot chain. Go to step 2.
- **If `--boot-nspawn` also fails:** the root tree itself is broken.
  Check the last `./build.sh` log for package resolution failures,
  script errors in `mkosi.build` / `mkosi.finalize`, or missing files
  in `mkosi.extra/`.

### Step 2 — watch the real boot on serial

```bash
./run.sh --debug
```

This enables `mkosi --debug`, overrides the `Console=gui` default with
`--console=interactive`, and pushes these kernel arguments via
`KernelCommandLineExtra=`:

- `console=ttyS0,115200` — serial console output
- `console=tty0` — keep VGA output too
- `systemd.journald.forward_to_console=1` — journal into the serial
- `systemd.log_level=debug`, `systemd.log_target=console`
- `udev.log_level=info`, `rd.udev.log_level=info`

These are appended at runtime via SMBIOS — they are **not** baked into
the image.

Typical failure shapes at this point:

| What you see | Likely cause |
| --- | --- |
| `systemd-boot` splash followed by `Failed to open \EFI\Linux\*.efi` | UKI is missing. Either `UnifiedKernelImages=no` is set and the profile didn't install a kernel, or `systemd-ukify` wasn't resolved. |
| `Kernel panic - not syncing: VFS: Unable to mount root fs` | Bootloader handed off to a kernel but the root partition couldn't be found or the initrd lacks the right storage driver. |
| Boots, hits `provision-local-users.service` and fails | First-boot provisioning error. See `docs/user-provisioning.md`. |
| No output at all, just a dead window | Firmware couldn't find a boot entry; check the ESP contents with `systemd-dissect mkosi.output/*.raw`. |

If the log points at a missing kernel, this is most likely what
happened: the base `mkosi.conf` does not list a `linux-image-*` in
`Packages=`. Each profile is responsible for pulling one (`liquorix`
for devbox, `t2linux` for macbook, `linux-image-arm64` for
cloudbox). If that profile step failed silently, the image has
systemd-boot but nothing to boot.

To confirm that theory:

```bash
mkosi summary | grep -i -E "packages|kernel|uki"
```

If `linux-image-*` isn't in the resolved `Packages=`, that's the bug.

### Step 3 — dropping to rescue

```bash
./run.sh --serial --kernel-arg systemd.unit=rescue.target
```

This gets you to a root shell before `multi-user.target` starts,
bypassing any service that's hanging the boot. From there:

```bash
journalctl -b -p err     # all errors from this boot
systemctl list-units --failed
systemctl status <failed-unit>
```

Anything else you need to hand to `mkosi` directly:

```bash
./run.sh --serial --mkosi-arg --debug-workspace
./run.sh --kernel-arg foo=bar --kernel-arg baz=qux
```

Both `--kernel-arg` and `--mkosi-arg` are repeatable.

## Other flags worth knowing

- `--profile NAME`, `--host NAME` — override what was last built
- `--persistent` — keep writes across VM restarts (useful for
  multi-boot tests; be careful, this does mutate `image.raw`)
- `--runtime-home` — mount the host home at `/root` inside the VM,
  read-write. Disposable-use only.
- `--runtime-tree HOST:GUEST` — mount an arbitrary host directory into
  the VM. Safer than `--runtime-home` because it's explicit about what
  gets shared.
- `--no-qemu-home-seed` — skip the default
  `runtime-seeds/qemu-home/` mount for desktop profiles

## Host packages that need to be installed

`./run.sh` auto-installs these on Debian/Ubuntu hosts via the
`ab_hostdeps_*` helpers. If you're on a different distro, install the
equivalents manually:

| Debian/Ubuntu | Purpose |
| --- | --- |
| `mkosi` | the builder itself |
| `qemu-system-x86` | x86-64 VM emulation for `mkosi vm` |
| `ovmf` | UEFI firmware; a disk image with `Bootloader=systemd-boot` needs this to boot |
| `virtiofsd` | virtio-fs daemon for `RuntimeTrees=` on recent mkosi |
| `swtpm` | software TPM; required when the image or profile touches vTPM |
| `systemd-container` | needed for `--boot-nspawn` (provides `systemd-nspawn`) |

Set `AB_AUTO_INSTALL_DEPS=no` to disable auto-install and get a manual
install hint instead.
