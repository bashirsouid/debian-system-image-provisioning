# QEMU sample home seed

For normal `./run.sh` use, the simplest path is now the default one: `run.sh` mounts `runtime-seeds/qemu-home/` into the guest and first boot copies that sample data into the login user's home only when the target paths do not already exist. The current seed covers `~/.config/awesome` and `~/.config/picom`.

Because `run.sh` now defaults to an ephemeral VM snapshot, those sample-home changes are discarded when the VM exits unless you opt into `--persistent`. That keeps QEMU smoke tests from mutating the `image.raw` you may later flash.

Use `--no-qemu-home-seed` if you want a completely bare VM home.

# Persistent /home and QEMU testing modes

There are really two different problems here, and they should be handled
with different mechanisms.

## 1. Real machines with dual-root updates

For workstation-style A/B deployments, `/home` should generally live outside the
slot image on its own persistent partition or subvolume. The root slots should be
replaceable; `/home` should not.

This tree already supports host-specific overlays via `--host NAME`, so the clean
pattern is:

- keep the base image generic
- add a host-specific `/etc/fstab` only on machines that should mount external `/home`
- keep servers or machines without persistent `/home` on the generic image

Example build:

```bash
./build.sh --profile devbox --host evox2
```

The example overlay in `hosts/evox2/` mounts a partition labeled `HOME` onto
`/home` with `nofail,x-systemd.automount` so the machine can still boot if that
partition is missing.

Adjust the source and filesystem type to match reality on the target machine.
Using `UUID=` or `PARTUUID=` is stricter than `LABEL=` if you prefer that.

## 2. QEMU compatibility testing against your host config

Do not attach the host's live `/home` block device directly read-write to the VM.
That is not the same thing as a persistent machine-local `/home`, and it creates
unnecessary risk.

For compatibility testing in QEMU, use one of these:

- `./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"`
- `./run.sh --runtime-home`

`--runtime-tree` is the safer default because it lets you share only what you are
trying to test, such as the AwesomeWM config directory. Note that mkosi maps the
invoking host user to `root` inside runtime trees, so the guest usually should
copy the shared files into its own home instead of symlinking directly to them.

`--runtime-home` is the quickest path on current Debian-trixie mkosi when you
want the host home available inside the guest. It is mounted at `/root`, so
use it as a source for copying config into the logged-in user's home.

For example:

```bash
./run.sh --runtime-home
```

Then inside the guest you can copy from `/root/.config/awesome` into your login
user's home before running `startx`.

A practical pattern for config testing is:

```bash
./run.sh --runtime-tree "$HOME/.config/awesome:/mnt/host-awesome"
```

Then inside the guest:

```bash
mkdir -p ~/.config/awesome
sudo cp -a /mnt/host-awesome/. ~/.config/awesome/
sudo chown -R "$USER:$USER" ~/.config/awesome
startx
```

That tests your real Awesome config without making the guest depend on a shared
persistent `/home` design.
