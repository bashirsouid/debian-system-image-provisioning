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

## 3. Root slot sizing: tiny build image, grown to fill the slot

The built root image is intentionally **much smaller than the partition it
gets deployed to**. This is deliberate; it is not a misconfiguration.

There are two independent size knobs, and they are easy to confuse:

- **`mkosi.repart/10-root.conf` — the build image.** Uses `Minimize=guess`, so
  the encrypted root `.raw` is sized to **each host's actual content** rather
  than a fixed size. This matters because hosts vary widely — a server is a few
  GB, while a full desktop host (steam, chromium, vscode, digikam, …) is much
  larger — so no single fixed size fits them all; `Minimize` adapts per host.
  `SizeMaxBytes=50G` is only a sanity ceiling (matched to the largest deploy
  slot). Why keeping it small matters: the root is LUKS-encrypted, and an
  encrypted partition **cannot be sparse** — every block is written as
  ciphertext. A fixed 15–30G build image therefore wrote 15–30G of real bytes
  during the build and needed roughly twice that in scratch space, which is
  what caused `systemd-repart` "No space left on device" failures. Sizing to
  content keeps builds small and fast and lets you keep more build images
  around before `./clean.sh`. (`Minimize` measures content by populating the
  filesystem an extra time — the "Pre-populating … twice" pass — which is a
  small build-time cost for getting the right size on every host automatically.)

- **`deploy.repart/10-root-a.conf`, `11-root-b.conf` — the physical slots.**
  `SizeMinBytes=15G`, `SizeMaxBytes=50G`. This is what actually carves the
  target disk when `bin/ab-install.sh` partitions it. Each root slot is
  15–50G; the persistent `DATA` partition (`/mnt/data`, default `rest`) soaks
  up whatever is left. **This `SizeMaxBytes` is the real ceiling on how large
  the running root can get** — not the build-image value.

### Bridging the two: `ab-grow-root.service`

Because the encrypted root can't be grown by the deploy tooling
(`bin/ab-install.sh` skips `resize2fs` for LUKS roots), the image instead grows
itself **at boot**. `ab-grow-root.service` (enabled via the base preset) runs
`/usr/local/sbin/ab-grow-root` on every boot:

1. `cryptsetup resize <root-mapper>` — extend the dm-crypt mapping to fill the
   whole partition (volume key is already in the kernel keyring from the
   boot-time unlock, so no passphrase prompt).
2. `resize2fs <dev>` — online-grow the ext4 to fill the (now full-size) device.

It grows to the **actual partition size** on the target — i.e. up to the
`deploy.repart` `SizeMaxBytes` (50G), not the build image's 15G guard. It is
idempotent (a no-op once the fs already fills the slot), so it also grows each
freshly-flashed slot on its first boot after an A/B update. This keeps the
running root from filling up between weekly/monthly reflashes (e.g. mid-week
`apt` upgrades) while keeping the build images tiny.

To change how large the deployed root can grow, edit `SizeMaxBytes` in **both**
`deploy.repart/10-root-a.conf` and `11-root-b.conf` (keep them equal so the A
and B slots match). Verify after boot with `df -h /` and
`journalctl -b -u ab-grow-root`.
