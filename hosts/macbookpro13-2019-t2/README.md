# macbookpro13-2019-t2 host overlay

This overlay targets the Intel 13-inch 2019 T2 MacBook Pro path.

Use it with the `macbook` profile:

```bash
./update-3rd-party-deps.sh
./build.sh --profile macbook --host macbookpro13-2019-t2
```

What it does:

- switches the desktop path from Liquorix to the t2linux Debian/Ubuntu kernel
- keeps PipeWire on Debian's default stack instead of shipping custom PipeWire overrides
- installs the T2 kernel, Apple Wi-Fi/Bluetooth firmware package, and fan daemon
- builds and installs the `snd_hda_macbookpro` CS8409 driver override into the image at build time
- enables mkosi build-script network access for this host because the driver installer fetches matching kernel source tarballs
- uses NetworkManager with Debian's `network-manager-iwd` integration
- keeps the t2linux/Apple-Firmware APT repos in the image so matching headers can still be installed later if you rerun the audio fix manually
- loads `apple-bce` automatically for the rest of the T2 bridge devices
- adds T2-oriented kernel args: `intel_iommu=on iommu=pt pcie_ports=compat pm_async=off mem_sleep_default=deep`
- enables a suspend workaround service that reloads the T2 and Broadcom modules across suspend/resume
- ships a manual fallback helper at `/usr/local/sbin/macbook-audio-fix`

Intentional choices:

- this overlay does **not** install `tiny-dfr` or any Touch Bar customization package
- if your exact machine exposes a Touch Bar under Linux, the t2 kernel's default mode is left alone
- speaker DSP tuning is **not** added here because the t2linux audio guide says its current experimental speaker DSP config is only for the 16-inch 2019 MacBook Pro and should not be used on other models
- `apple-t2-audio-config` is kept as a supporting package, but it is **not** treated as the primary speaker fix for this model; the primary fix path is the CS8409 driver override
- hibernation is **not** fully wired by default in this repo's retained-version layout because that still needs swap + resume configuration; this overlay focuses on suspend and day-to-day hardware bring-up first

Practical notes:

- disable Secure Boot in macOS Recovery before trying to boot Linux on a T2 Mac
- the recommended first real-hardware test is now a removable USB created with `sudo ./bin/write-live-test-usb.sh --target /dev/sdX`
- boot that USB from Startup Manager, verify Wi-Fi/Bluetooth/audio/sleep on real hardware, and only then run `/root/INSTALL-TO-INTERNAL-DISK.sh` from the booted USB
- keep some macOS recovery/firmware path around if you can; it is still the cleanest way to handle Apple firmware updates and recovery
- if Bluetooth audio glitches, prefer 5 GHz Wi-Fi over 2.4 GHz on BCM4377-based machines
- if audio is still missing after booting a built image, run `sudo macbook-audio-fix` and reboot once
