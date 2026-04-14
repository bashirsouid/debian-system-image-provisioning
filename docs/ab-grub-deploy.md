# GRUB A/B notes (archived)

This document is kept only as historical context.

The repository now recommends the **systemd-boot** path described in:

- `docs/ab-systemd-boot-deploy.md`
- `README.md`

Reason for the change:
- the built images already use `Bootloader=systemd-boot`
- systemd-boot makes one-shot vs persistent slot selection simpler with `bootctl`
- slot-specific kernel flags fit naturally into Boot Loader Specification entries
- the old GRUB-specific path added extra moving parts without buying much here

If you still need the old GRUB flow, use the v13 tree as the historical reference.
