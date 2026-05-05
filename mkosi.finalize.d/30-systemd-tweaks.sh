#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$SRCDIR/scripts/finalize-lib.sh"

# Belt-and-suspenders: the preset disables systemd-boot-update.service, but
# `preset-all` will only honor that for units the preset *names*. If a unit
# was enabled in a previous image build via a leftover symlink (e.g. older
# image stages applied to the same BUILDROOT), preset-all may not remove it.
# Disable explicitly so the live-test USB doesn't burn 60-90s in
# `bootctl update` on every boot just to rewrite an already-correct
# /boot/EFI/systemd/systemd-bootx64.efi.
if [[ -f "$ROOT/usr/lib/systemd/system/systemd-boot-update.service" ]]; then
  echo "==> [FINALIZE] masking systemd-boot-update.service (slow on USB ESP, redundant for sysupdate path)"
  ln -snf /dev/null "$ROOT/etc/systemd/system/systemd-boot-update.service"
fi

# Same for systemd-networkd: this image uses NetworkManager. The preset
# disables networkd, but on some Debian/kernel combos networkd.socket
# is wired to other targets via static unit files we don't override,
# and you still get a [FAILED] red line at boot:
#   "Failed to listen on systemd-networkd.socket - Network Service Netlink Socket"
# Mask the socket and service so they cannot be pulled in by anything.
for _nu in systemd-networkd.service systemd-networkd.socket \
           systemd-networkd-wait-online.service \
           systemd-networkd-persistent-storage.service; do
  if [[ -f "$ROOT/usr/lib/systemd/system/$_nu" ]]; then
    echo "==> [FINALIZE] masking $_nu (this image uses NetworkManager)"
    ln -snf /dev/null "$ROOT/etc/systemd/system/$_nu"
  fi
done
