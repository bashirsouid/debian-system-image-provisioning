#!/usr/bin/env bash
#
# Generates a Secure Boot signing key + self-signed certificate that
# mkosi will use to sign the UKI when a host opts in with
# SecureBoot=yes and points at these files.
#
# Output:
#   .secureboot/db.key    private signing key (mode 0600, gitignored)
#   .secureboot/db.crt    self-signed X.509 cert (DER or PEM)
#   .secureboot/db.esl    EFI signature list (for firmware enrollment)
#   .secureboot/db.auth   signed auth blob (for KEK-authenticated enroll)
#
# Once generated, these keys MUST be enrolled into each target
# machine's UEFI firmware before a Secure-Boot-on image will boot.
# See docs/secure-boot.md for per-host enrollment steps (evox2 via
# BIOS menu, cloudbox via cloud console's Secure Boot key upload,
# macbookpro13-2019-t2 — intentionally not supported, T2 + Linux SB
# is not a road worth walking).
#
# Re-running is safe: it will refuse to overwrite existing keys unless
# --force is passed. Losing db.key means every already-enrolled machine
# needs re-enrollment, so back it up somewhere offline (a USB stick in
# a drawer is fine, a cloud sync folder is NOT fine).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_DIR="${PROJECT_ROOT}/.secureboot"
CN="mkosi image provisioning signing key"
VALID_DAYS="3650"
FORCE=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/generate-secureboot-keys.sh [--force] [--cn "Name"] [--days N]

Generates a local Secure Boot signing key + self-signed cert under
.secureboot/. Refuses to overwrite unless --force is passed.

After generating:
  1. Opt the relevant host(s) into Secure Boot by adding
     hosts/<n>/mkosi.conf.d/30-secure-boot.conf with:
         [Validation]
         SecureBoot=yes
         SecureBootKey=.secureboot/db.key
         SecureBootCertificate=.secureboot/db.crt
  2. Enroll .secureboot/db.crt into each target's UEFI firmware.
     See docs/secure-boot.md for the per-host steps.
  3. Back up .secureboot/db.key OFFLINE. Losing it orphans every
     already-enrolled machine.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --cn)    CN="${2:?missing CN}"; shift 2 ;;
    --days)  VALID_DAYS="${2:?missing days}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v openssl >/dev/null 2>&1 || {
  echo "ERROR: openssl is required. Install it on the build host." >&2
  exit 1
}

# sbsiglist / sign-efi-sig-list come from the sbsigntool package on
# Debian. They're not strictly required for the key itself — mkosi
# can sign with just openssl — but the .esl / .auth outputs make
# firmware enrollment much easier and are standard for SB key bundles.
HAVE_SBSIGN=0
if command -v sbsiglist >/dev/null 2>&1 && command -v sign-efi-sig-list >/dev/null 2>&1; then
  HAVE_SBSIGN=1
fi

install -d -m 0700 "${KEY_DIR}"

for f in db.key db.crt db.esl db.auth; do
  if [[ -f "${KEY_DIR}/${f}" && "${FORCE}" != "1" ]]; then
    echo "ERROR: ${KEY_DIR}/${f} already exists. Pass --force to overwrite." >&2
    echo "       (But think twice — overwriting means re-enrolling every machine.)" >&2
    exit 1
  fi
done

echo "==> Generating Secure Boot signing key: ${KEY_DIR}/db.key"
umask 077
openssl req -new -x509 \
  -newkey rsa:4096 -nodes \
  -keyout "${KEY_DIR}/db.key" \
  -out    "${KEY_DIR}/db.crt" \
  -subj   "/CN=${CN}/" \
  -days   "${VALID_DAYS}" \
  -sha256

chmod 0600 "${KEY_DIR}/db.key"
chmod 0644 "${KEY_DIR}/db.crt"

if (( HAVE_SBSIGN )); then
  echo "==> Building EFI Signature List + signed auth blob for firmware enrollment"
  # A random GUID is fine; it just identifies this key entry in the
  # firmware's db. Generate and stash it alongside the key so we can
  # re-sign with the same GUID later if needed.
  if [[ ! -f "${KEY_DIR}/db.guid" ]]; then
    if command -v uuidgen >/dev/null 2>&1; then
      uuidgen > "${KEY_DIR}/db.guid"
    else
      # Fallback: synthesize a UUIDv4 from urandom.
      python3 -c 'import uuid; print(uuid.uuid4())' > "${KEY_DIR}/db.guid"
    fi
    chmod 0644 "${KEY_DIR}/db.guid"
  fi
  GUID="$(cat "${KEY_DIR}/db.guid")"

  sbsiglist \
    --owner "${GUID}" \
    --type x509 \
    --output "${KEY_DIR}/db.esl" \
    "${KEY_DIR}/db.crt"

  # Self-sign the ESL as "db" — this is fine for machines where we
  # own PK and KEK already, or for firmware that accepts unsigned
  # enrollment via setup mode.
  sign-efi-sig-list \
    -k "${KEY_DIR}/db.key" \
    -c "${KEY_DIR}/db.crt" \
    db \
    "${KEY_DIR}/db.esl" \
    "${KEY_DIR}/db.auth"
  chmod 0644 "${KEY_DIR}/db.esl" "${KEY_DIR}/db.auth"
else
  echo "==> sbsigntool not found; skipped .esl / .auth generation."
  echo "    To produce them: apt-get install sbsigntool efitools, then re-run with --force."
fi

cat <<EOF

==> Done. Files in ${KEY_DIR}/:
EOF
(
  cd "${KEY_DIR}"
  for f in db.key db.crt db.esl db.auth db.guid; do
    [[ -e "$f" ]] || continue
    perms="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")"
    printf '    %s (mode %s)\n' "$f" "$perms"
  done
)
cat <<EOF

Next steps:
  1. Back up ${KEY_DIR}/db.key OFFLINE (USB in a drawer; NOT cloud sync).
  2. Opt a host into Secure Boot by creating:
       hosts/<n>/mkosi.conf.d/30-secure-boot.conf
     with the contents shown by --help, then rebuild.
  3. Enroll db.crt (or db.auth) into that host's UEFI firmware.
     See docs/secure-boot.md.
EOF
