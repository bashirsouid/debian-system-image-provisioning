# docker-kernel-6-18

Docker engine with Debian trixie-backports kernel 6.18.x support.

## ⚠️ Secure Boot Warning

This profile uses the Debian backports kernel (`linux-image-6.18.*`) which ships
with **unsigned kernel modules**. If you boot with Secure Boot enabled, the
`bridge` and other networking modules will fail to load, causing Docker to fail
with "operation not supported".

For Secure Boot systems, use the `docker` profile instead (which uses the Signed
default Debian kernel).

## Usage

```bash
# For Secure Boot systems (recommended):
./build.sh --profile docker --host <host>

# For non-Secure Boot systems (backports kernel):
./build.sh --profile docker-kernel-6-18 --host <host>
```