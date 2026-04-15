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

## What still remains out of scope

- Secure Boot signing/integration for the update path
- a cloud-provider-specific “switch this instance to boot from the newly prepared volume” step
- richer application-aware health hooks beyond failed-unit checks and optional scripts
