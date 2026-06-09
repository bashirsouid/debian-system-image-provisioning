# thinkpad-x1g13

Model profile for the **ThinkPad X1 Gen13 (Intel Lunar Lake)**. Holds the
hardware enablement that used to live in `hosts/x1g13/mkosi.extra/`:
manually-placed LNL firmware (Wi-Fi/Bluetooth, xe GPU, SOF audio, NPU),
the trixie-backports firmware pin, Xorg/input configs, modprobe options,
SSD sysfs tuning, TLP, and the speaker-DAC audio fixups.

Layer it on top of `thinkpad-g13` (which installs the firmware/audio/TLP
packages). A host selects it via its descriptor's `profiles =` line.

Nothing here is personal to a specific machine — per-instance config
(hostname, `/home` mount, backup paths) lives in the host descriptor
(`hosts.local/<name>.conf`), not in this profile.

No secret values are required.
