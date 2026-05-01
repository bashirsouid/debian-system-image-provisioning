# Live USB verification

## Why a verification pass is not optional

`dd` reports exit 0 when the write-side `close()` returns. That does
not mean:

* that the device actually persisted every block (write cache),
* that the device silently remapped sectors and returned garbage on
  read,
* that a flaky USB cable did not corrupt the last few megabytes,
* that `dd` wrote to the USB and not to `/dev/sda` because you had
  a typo and the USB enumerated differently than you thought.

Before you boot an image on real hardware, verify the write. If the
verify fails, you want that failure on your laptop, not on the
machine you are trying to provision.

## Using the helper

```
sudo ./scripts/usb-write-and-verify.sh \
    --source mkosi.output/debian-provisioning_*.raw \
    --target /dev/sdX
```

The script:

1. Refuses to write unless `/dev/sdX` is a block device, is not the
   host root disk, is not currently mounted, and is removable (or you
   pass `--i-know-this-is-not-removable`).
2. Hashes the source with sha256.
3. Writes with `dd bs=4M conv=fsync oflag=direct` so the write is not
   sitting in page cache when verification starts.
4. Drops the page cache (`vm.drop_caches=3`) so the read-back is
   honest.
5. Reads back exactly the source size from the target and hashes.
6. Refuses to report success if the hashes differ.

Integrate it into `bin/ab-install.sh` by replacing the
`dd` line that writes the image with a call to the helper. See
`PATCH.md` at the root of this bundle for the exact patch.

## What a failed verify looks like

```
[usb-write] VERIFY FAILED: source and device hashes differ. DO NOT boot this USB.
```

When that happens:

* Try a different USB port. USB 2 ports are more tolerant of
  marginal cables.
* Try a different USB stick. Old/cheap sticks silently corrupt
  writes under load.
* If the source file also changes hash between runs, you have a
  local storage problem, not a USB problem.

## Troubleshooting

`dd: error writing …: No space left on device` with a verify failure
almost always means the USB is smaller than the image. Use a larger
stick or rebuild with a smaller root size.

`Resource busy` on the target means something on your host mounted
it. Run `lsblk -o NAME,MOUNTPOINT /dev/sdX` and unmount everything
before retrying.
