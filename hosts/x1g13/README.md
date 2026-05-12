# x1g13 host overlay (ThinkPad X1 Carbon Gen 13)

This overlay is a workstation-oriented host configuration for the Lenovo X1 Carbon Gen 13 with Lunar Lake processor.

Use it with:

```bash
./build.sh --profile devbox --host x1g13
```

What it provides:

- ThinkPad power-management profile (`thinkpad`) with TLP, thinkfan, thermald
- Intel NPU support via `intel-npu` profile
- i915 GPU power-saving options
- SSD write-back caching
- Wi-Fi power-saving options
- Intel NPU kernel module auto-loading
- Example `/home` mount in `mkosi.extra/etc/fstab`
- Host-specific kernel command line in `kernel-cmdline.extra`

The `/home` example keeps mutable user data outside the retained root versions. Edit the `/etc/fstab` source in this overlay before using it on a real machine.
