#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$SRCDIR/scripts/finalize-lib.sh"

# /etc/default/locale: pam_env(8) reads this on every login. On Debian +
# systemd, package install can leave /etc/default/locale as a *dangling*
# symlink (typically -> /etc/locale.conf, which is never populated unless
# `localectl set-locale` ran). Without a real file, every login generates
#   pam_env(login:session): Unable to open env file: /etc/default/locale
# in the journal.
#
# We can't drop /etc/default/locale via mkosi.extra because cp(1) refuses
# to write through a dangling symlink at the destination ("cp: not writing
# through dangling symlink"). Handle it here in shell instead, where we can
# detect the dangling symlink and replace it with a real file.
LOCALE_FILE="$ROOT/etc/default/locale"
install -d -m 0755 "$ROOT/etc/default"
if [[ -L "$LOCALE_FILE" && ! -e "$LOCALE_FILE" ]]; then
  echo "==> [FINALIZE] /etc/default/locale is a dangling symlink; replacing with real file"
  rm -f "$LOCALE_FILE"
fi
if [[ ! -e "$LOCALE_FILE" ]]; then
  echo "==> [FINALIZE] writing /etc/default/locale (LANG=C.UTF-8) for pam_env"
  printf 'LANG=C.UTF-8\n' > "$LOCALE_FILE"
  chmod 0644 "$LOCALE_FILE"
fi

# Pre-create the XDG layout in /etc/skel with restrictive perms.
#
# Why: dotbot's `link` action does NOT auto-create parent directories,
# so a fresh home that lacks ~/.config will silently fail to materialize
# every dotfiles symlink under it. Pre-seeding here means any user
# created via useradd (whether through provision-local-users or by
# hand later) starts with a working XDG tree, regardless of what their
# dotfiles repo remembered to declare.
#
# Mode 0700 on the parents matters too: home itself is locked to 0700
# already (see provision-local-users + HOME_MODE below), but we want
# the same posture preserved if someone later relaxes the top-level
# perm — config and cache dirs should not become world-readable just
# because the home dir did. Defense in depth.
#
# Git does not track directory perms, so doing this in finalize rather
# than via mkosi.extra/etc/skel/... is what guarantees the modes are
# right on every build host.
echo "==> [FINALIZE] pre-creating /etc/skel XDG dirs at mode 0700"
install -d -m 0700 "$ROOT/etc/skel/.config"
install -d -m 0700 "$ROOT/etc/skel/.cache"
install -d -m 0700 "$ROOT/etc/skel/.local"
install -d -m 0700 "$ROOT/etc/skel/.local/share"
install -d -m 0700 "$ROOT/etc/skel/.local/bin"

# Lock the default home-dir mode at the login.defs level. Debian ships
# HOME_MODE=0755 in older releases (and an unset/commented HOME_MODE in
# some), which means a `useradd` outside our provisioning script would
# create a world-readable home. provision-local-users already does
# `chmod 0700` on the top-level home, but enforcing the same policy in
# /etc/login.defs is what makes it true for every user-creation path,
# not just first-boot provisioning.
LOGIN_DEFS="$ROOT/etc/login.defs"
if [[ -f "$LOGIN_DEFS" ]]; then
  if grep -qE '^[#[:space:]]*HOME_MODE[[:space:]]' "$LOGIN_DEFS"; then
    echo "==> [FINALIZE] setting HOME_MODE=0700 in /etc/login.defs"
    sed -i 's|^[#[:space:]]*HOME_MODE[[:space:]].*|HOME_MODE\t0700|' "$LOGIN_DEFS"
  else
    echo "==> [FINALIZE] appending HOME_MODE=0700 to /etc/login.defs"
    printf '\n# AB image: restrict default home-dir perms to owner only\nHOME_MODE\t0700\n' >> "$LOGIN_DEFS"
  fi
fi

# Lock /root to 0700.
#
# Why: mkosi.extra/root/ ships a few helper scripts (diagnose-boot.sh,
# ab-enroll-tpm, ab-verify) and mkosi creates the destination /root
# in the image with the *source* directory's perms — which on the
# build host is 0755 because git does not track 0700 directory modes
# reliably. The result is /root readable by every user on the image,
# which is wrong: ab-install.sh later drops build artifacts and
# (optionally) install bundles under /root/, and we don't want a
# regular login user to be able to ls those.
#
# Same defense-in-depth posture as the /etc/skel and HOME_MODE blocks
# above: enforce the mode in finalize so it is correct on every build,
# regardless of what perms the source tree happens to have.
if [[ -d "$ROOT/root" ]]; then
  echo "==> [FINALIZE] locking /root to 0700"
  chmod 0700 "$ROOT/root"
# Ensure /mnt/data mount point and permissions
# Create group for data users
chroot "$ROOT" groupadd -r data-users || true
# Create users if they don't exist, then add them to the group
chroot "$ROOT" id -u bashirs >/dev/null 2>&1 || chroot "$ROOT" useradd -m -s /bin/bash bashirs || true
chroot "$ROOT" id -u ansible >/dev/null 2>&1 || chroot "$ROOT" useradd -m -s /bin/bash ansible || true
# Add users to the group
chroot "$ROOT" usermod -a -G data-users bashirs || true
chroot "$ROOT" usermod -a -G data-users ansible || true
# Create the mount directory with appropriate permissions
install -d -m 0775 "$ROOT/mnt/data"
# Set ownership inside the chroot
chroot "$ROOT" chown root:data-users /mnt/data
fi
