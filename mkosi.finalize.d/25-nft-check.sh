#!/usr/bin/env bash
# /usr/local/libexec/ab-finalize-nftables-check.sh
#
# Build-time syntax check for /etc/nftables.conf. Runs inside the
# image's chroot using the image's own nft binary, so absolute
# include paths (/etc/nftables.conf.d/*) resolve correctly.
#
# AB_SKIP_NFT_CHECK=1 skips the check (e.g. when nft is unavailable).
#
# Placed in mkosi.finalize.d/ so it runs near the end of the build,
# after all profiles have composed the final nftables.conf.

set -euo pipefail

echo "==> [FINALIZE] validating /etc/nftables.conf syntax"

# Allow graceful skip when nft is not available in the image
if [[ -n "${AB_SKIP_NFT_CHECK:-}" ]]; then
  echo "==> [FINALIZE] AB_SKIP_NFT_CHECK set; skipping nftables syntax check"
  exit 0
fi

BUILDROOT="${BUILDROOT:-}"
if [[ -z "$BUILDROOT" ]]; then
  echo "==> [FINALIZE] BUILDROOT not set; cannot chroot to validate nftables.conf" >&2
  exit 0
fi

# The image's nft binary location (installed by k3s profile / nftables pkg)
NFT_BIN="${BUILDROOT}/usr/sbin/nft"
CONF_FILE="${BUILDROOT}/etc/nftables.conf"

if [[ ! -x "$NFT_BIN" ]]; then
  echo "==> [FINALIZE] nft not available in image (${NFT_BIN}); skipping syntax check" >&2
  exit 0
fi

if [[ ! -f "$CONF_FILE" ]]; then
  echo "==> [FINALIZE] /etc/nftables.conf not found in image; skipping" >&2
  exit 0
fi

echo "==> [FINALIZE] running 'nft --check --file /etc/nftables.conf' inside chroot"
if ! chroot "$BUILDROOT" /usr/sbin/nft --check --file /etc/nftables.conf; then
  echo "ERROR: /etc/nftables.conf failed 'nft --check'; refusing to ship a broken firewall" >&2
  exit 1
fi

echo "==> [FINALIZE] nftables.conf syntax OK"