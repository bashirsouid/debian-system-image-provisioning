#!/usr/bin/env bash
set -euo pipefail

# Source shared library
source "$SRCDIR/scripts/finalize-lib.sh"

echo "==> [FINALIZE] enabling first-boot user provisioning and boot-health gating"
enable_target_unit multi-user.target provision-local-users.service
enable_target_unit boot-complete.target ab-health-gate.service

load_build_info
if [[ -n "${AB_ROOT_PASSWORD_HASH:-}" ]]; then
  echo "==> [FINALIZE] applying temporary root password for emergency mode"
  # Set the shell to /bin/bash so the password actually gets the user a working
  # session; the base mkosi.conf sets RootShell=/bin/false to harden production
  # builds, and that needs to be reverted whenever --allow-root is requested.
  chroot "$ROOT" usermod -s /bin/bash root
  # chpasswd -e takes a crypt-format hash on stdin (build.sh generates one with
  # `openssl passwd -6`). Using `usermod -p "$hash"` here would silently fail
  # for hashes containing `$` because of shell-expansion and historic /etc/shadow
  # quoting weirdness — that was the bug behind the previous "root login
  # doesn't work" symptom.
  echo "root:$AB_ROOT_PASSWORD_HASH" | chroot "$ROOT" chpasswd -e
  chroot "$ROOT" usermod -U root

  # Diagnostics: verify the account is actually unlocked.
  if chroot "$ROOT" passwd -S root | grep -q ' L '; then
    echo "WARNING: [FINALIZE] root account is STILL LOCKED after usermod -U" >&2
  else
    echo "==> [FINALIZE] root account is unlocked and ready"
  fi

  # Allow root login on every text VT, not just /dev/console. Debian ships
  # /etc/securetty with tty1..tty63 by default, but some hardened base images
  # (and some mkosi presets) trim it. pam_securetty.so consults this file from
  # /etc/pam.d/login, so a missing tty entry blocks console root login even
  # when the password is correct — masking the real failure as "wrong password".
  if [[ ! -f "$ROOT/etc/securetty" ]] || ! grep -q '^tty1$' "$ROOT/etc/securetty"; then
    echo "==> [FINALIZE] writing permissive /etc/securetty for emergency mode"
    {
      echo "console"
      for i in $(seq 1 12); do echo "tty$i"; done
    } > "$ROOT/etc/securetty"
    chmod 0600 "$ROOT/etc/securetty"
  fi
fi

if [[ -n "${AB_IMAGE_ID:-}" ]]; then
  echo "==> [FINALIZE] setting IMAGE_ID=$AB_IMAGE_ID in /usr/lib/os-release"
  append_or_replace_os_release_key IMAGE_ID "$AB_IMAGE_ID"
fi
if [[ -n "${AB_IMAGE_VERSION:-}" ]]; then
  echo "==> [FINALIZE] setting IMAGE_VERSION=$AB_IMAGE_VERSION in /usr/lib/os-release"
  append_or_replace_os_release_key IMAGE_VERSION "$AB_IMAGE_VERSION"
fi
