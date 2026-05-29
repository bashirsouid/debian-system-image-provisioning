# Swap Profile

## Overview
The `swap` profile creates a 2 GiB swap file on the target machine at first boot. It uses `fallocate` to allocate the file efficiently without zero‑filling, minimizing SSD wear. The profile installs a systemd one‑shot service that creates the file, formats it with `mkswap`, and activates it via `swapon`. A static fstab entry ensures the swap persists across reboots.

## File layout
```
mkosi.profiles/
└─ swap/
   ├─ mkosi.conf                # minimal config – no extra packages needed
   ├─ profile.manifest          # description metadata
   ├─ mkosi.extra/
   │   ├─ etc/
   │   │   ├─ fstab             # fstab entry for /swapfile
   │   │   └─ systemd/
   │   │       ├─ system/
   │   │       │   └─ swap-setup.service   # systemd unit to create swap
   │   │       └─ system-preset/
   │   │           └─ 91-swap.preset         # enables the unit
   │   └─ usr/
   │       └─ local/
   │           └─ bin/
   │               └─ create-swap.sh          # script that runs at boot
   └─ README.md                 # (this file)
```

## How it works
1. On boot, `swap-setup.service` (WantedBy=local-fs.target) runs `create-swap.sh`.
2. The script checks if `/swapfile` exists; if not, it creates a 2 GiB file with `fallocate -l 2048M`.
3. The file is set to mode 600, initialized with `mkswap`, and activated with `swapon`.
4. The fstab line `/swapfile none swap sw 0 0` ensures the swap is re‑enabled on subsequent boots.

## Enabling / Disabling
- **Enable**: The profile is enabled automatically when `swap` is added to the profile list (e.g., `--profile=swap` or in `hosts/<host>/profile.default`).
- **Disable**: Remove the profile from the list, or disable the unit manually:
  ```bash
  systemctl disable --now swap-setup.service
  ```

## Troubleshooting
- **Swap not active**: Run `swapon --show` to verify. Check service status: `systemctl status swap-setup.service`.
- **Insufficient space**: Ensure the root filesystem has at least 2 GiB free. The `fallocate` call will fail if there isn’t enough space.
- **Missing `fallocate`**: The script requires the `fallocate` binary from `util-linux`. It is part of the base image; if you strip it, the service will fail.

## Compatibility notes
- Works on ext4, XFS, Btrfs, and other filesystems that support `fallocate`.
- The swap file is created on the root filesystem (`/`). If you need it on a different mount, adjust `SWAPFILE` in `create-swap.sh`.
- The profile does not install any additional packages; it only relies on utilities already present in the base image.

