# Retained-root workflow notes

This repository now uses the modern retained-version flow as its design center:

- build a versioned image with `mkosi`
- export versioned sysupdate source artifacts
- bootstrap a target layout once with `systemd-repart`
- install versions with `systemd-sysupdate`
- let `systemd-boot` boot counting + `systemd-bless-boot` decide whether the new version stays

## What the current tree supports

- reproducible mkosi-built images
- source-built AwesomeWM for the devbox profile
- first-boot user creation that works in rootless mkosi builds
- optional host UID/GID sync for the build host user
- versioned root/UKI/BLS artifact export after build
- destructive first bootstrap to a blank/offline target disk or image
- in-place later updates with `systemd-sysupdate`
- boot health gating before `boot-complete.target`
- ARM64 `cloudbox` server builds and automation
- dual-boot install alongside existing OSes (`--preserve` mode)
- optional persistent storage symlinks for Docker/K3s (`symlink-docker`, `symlink-k3s` profiles)

## Dual-boot / preserve mode

If you want to keep an existing OS (e.g. Windows) and add Linux A/B root
partitions in the free space, run the installer from a live USB:

```bash
sudo ./bin/ab-install.sh \
  --target /dev/nvme0n1 \
  --preserve \
  --home-size 64G \
  --data-size rest \
  --yes
```

`--preserve` changes the behaviour of `systemd-repart` from `--empty=force`
(wipe everything) to `--empty=allow` (add new partitions alongside existing
ones). Existing partitions are left untouched; new ESP, root-A, root-B,
HOME and DATA partitions are created in the available free space.

All new partitions are automatically aligned to 4K boundaries for optimal
SSD/NVMe performance. After repartitioning, a post-install check verifies
alignment of every partition on the target.

## Persistent container storage symlinks

By default Docker and K3s store their data under `/var/lib/`, which lives
inside the A/B root partition and gets replaced on each update. Two optional
profiles create first-boot systemd oneshot services that symlink these
directories to the persistent DATA partition:

| Profile | What it does |
|---------|--------------|
| `symlink-docker` | `/var/lib/docker -> /mnt/data/docker` |
| `symlink-k3s` | `/var/lib/rancher/k3s -> /mnt/data/k3s`, `/var/lib/containers -> /mnt/data/containers` |

Both are idempotent (gated by `ConditionPathExists=!.../done`), require no
packages, and are composed into the image at build time:

```bash
./build.sh --host mylaptop
```

## What still remains out of scope

- Secure Boot signing/integration for the update path
- a cloud-provider-specific “switch this instance to boot from the newly prepared volume” step
- richer application-aware health hooks beyond failed-unit checks and optional scripts
