# QEMU sample home seed

For normal `./run.sh` use, the simplest path is now the default one: `run.sh` mounts `runtime-seeds/qemu-home/` into the guest and first boot copies that sample data into the login user's home only when the target paths do not already exist. The current seed covers `~/.config/awesome` and `~/.config/picom`.

Because `run.sh` now defaults to an ephemeral VM snapshot, those sample-home changes are discarded when the VM exits unless you opt into `--persistent`. That keeps QEMU smoke tests from mutating the `image.raw` you may later flash.

Use `--no-qemu-home-seed` if you want a completely bare VM home.

# Persistent /home and QEMU testing modes

There are really two different problems here, and they should be handled
with different mechanisms.

## 1. Real machines with retained-root updates

For workstation-style retained-root deployments, `/home` should generally live
outside the root image on its own persistent partition or subvolume. The root
slots should be replaceable; `/home` should not.

The repo now prefers the **native GPT path** for that:

- create `/home` as a GPT partition of type `home`
- keep it on the same physical disk as the root partitions
- let `systemd-gpt-auto-generator` mount it automatically on boot

That is the layout the hardware-test USB installer now defaults to when you pick
`rest` for `/home`.

There is also a simple optional persistent data path baked into the image now:

- if a partition with `PARTLABEL=DATA` exists, it is mounted at `/mnt/data`
- if no such partition exists, the `nofail` mount entry is ignored and boot
  continues normally

You can still use host-specific overlays via `--host NAME` when you want a more
opinionated machine-local storage layout, but the preferred golden path is now:

- GPT `home` partition for `/home`
- optional `DATA` partition for `/mnt/data`
- retained root versions managed separately by `systemd-sysupdate`

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
