#!/bin/bash
# scripts/hash-password.sh
#
# Interactive helper: prompts for a password (no echo), prints a
# yescrypt hash suitable for dropping into .users.json as
# "password_hash". Does not write the password or the hash to any file.
#
# Usage:
#   ./scripts/hash-password.sh
#
# The printed hash looks like:
#   $y$j9T$...salt...$...hash...
#
# Copy that entire string (including the leading $y$) into
# the "password_hash" field of the relevant user in .users.json.

set -euo pipefail

fail() { printf '[hash-password] ERROR: %s\n' "$*" >&2; exit 1; }

# mkpasswd is in the 'whois' package on Debian/Ubuntu.
if ! command -v mkpasswd >/dev/null 2>&1; then
    fail "mkpasswd is not installed. Run: sudo apt-get install --no-install-recommends whois"
fi

# Prefer yescrypt (the current Debian/Ubuntu default for /etc/shadow).
# Fall back to sha512crypt on older builds where yescrypt isn't
# available in the host's libcrypt.
if mkpasswd -m help 2>&1 | grep -qw yescrypt; then
    method=yescrypt
elif mkpasswd -m help 2>&1 | grep -qw sha512crypt; then
    method=sha512crypt
else
    fail "mkpasswd supports neither yescrypt nor sha512crypt on this host."
fi

echo "Enter a password. It will not be echoed."
echo "The hash (NOT the password) will be printed to stdout."
echo

# -s suppresses echo. Read twice to confirm.
read -r -s -p "Password: " p1 || fail "read failed"
printf '\n'
read -r -s -p "Confirm : " p2 || fail "read failed"
printf '\n'

if [[ "${p1}" != "${p2}" ]]; then
    # Do not print anything that could reveal length differences.
    unset p1 p2
    fail "passwords did not match."
fi

if [[ ${#p1} -lt 12 ]]; then
    unset p1 p2
    fail "password is shorter than 12 characters; pick a stronger one."
fi

# mkpasswd reads from stdin with -s. The --stdin long flag is not
# available on all distro versions; -s is.
hash="$(printf '%s' "${p1}" | mkpasswd --method="${method}" -s)"
unset p1 p2

printf '%s\n' "${hash}"
