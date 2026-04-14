# Host-Specific Configuration

Each subdirectory represents a physical or virtual machine with unique settings.

## Creating a new host

1. Create `hosts/<hostname>/mkosi.conf.d/50-host.conf`.
2. Add host-specific packages, kernel parameters, etc.
3. Optionally add `hosts/<hostname>/mkosi.extra/` for files like `/etc/fstab`.
4. Build with: `./build.sh --profile devbox --host <hostname>`.

## Example Host

The `example-host` directory provides a starting point for host-specific configurations.
