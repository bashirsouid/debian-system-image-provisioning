# Mkosi Image Building - Machine Provisioning

This project restructures mkosi image building for machine provisioning, supporting different roles (devbox, server) and host-specific configurations.

## Architecture

-   **`mkosi.conf`**: Base configuration shared by all images (Debian Trixie).
-   **`mkosi.profiles/`**: Role-based configurations.
    -   `devbox`: Desktop environment with AwesomeWM (built from source) and Liquorix kernel.
    -   `server`: Minimal headless environment.
-   **`hosts/`**: Host-specific overrides (fstab, extra drivers, etc.).
-   **`mkosi.build`**: Two-phase build script to compile AwesomeWM from source.
-   **`mkosi.postinst`**: Post-installation script for security (root lockdown).
-   **`build.sh`**: Smart wrapper for building images.
-   **`run.sh`**: Helper to boot the image in QEMU with optimized display.
-   **`clean.sh`**: Helper to clean up build artifacts.

## Prerequisites

-   `mkosi` (version 25+)
-   `qemu-system-x86_64`
-   `jq` (for user provisioning)

## Getting Started

1.  **Prepare Users**:
    ```bash
    cp .users.json.sample .users.json
    # Edit .users.json and set your usernames and passwords
    ```

2.  **Build a Devbox Image**:
    ```bash
    ./build.sh --profile devbox
    ```

3.  **Boot the Image**:
    ```bash
    ./run.sh --profile devbox
    ```

## Key Features

-   **Debian Trixie**: Uses the latest testing distribution.
-   **Liquorix Kernel**: Included in the `devbox` profile for better performance and hardware support (e.g., Ryzen AI 395).
-   **AwesomeWM from source**: Compiles the latest git version of AwesomeWM, with runtime dependencies managed automatically via the Debian package system overlay trick.
-   **Security**: The `root` account is completely locked. Users are provisioned via `.users.json` during the first boot.
-   **Resizable QEMU Window**: Uses `virtio-gpu` and `spice-vdagent` to support seamless window resizing in the VM.

## Troubleshooting

### QEMU Display Issues
If `gl=on` fails, the `run.sh` script automatically falls back to `gl=off`. Ensure you have `spice-vdagent` running in the guest for automatic resolution scaling.

### Rebuilding
Use `./build.sh --force` to force a rebuild if automatic staleness detection doesn't catch a change. Use `./clean.sh --all` for a completely fresh build.
