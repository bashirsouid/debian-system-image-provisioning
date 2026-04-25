#!/usr/bin/env bash
#
# Preflight audit: fails the build if any tracked file under
# mkosi.extra/ or hosts/*/mkosi.extra/ looks like per-machine
# identity that would produce unsafe images if shared across hosts.
#
# Banned patterns:
#   */etc/ssh/ssh_host_*          SSH host keys (private OR public).
#                                 Sharing them across machines lets an
#                                 attacker impersonate one from another.
#   */etc/machine-id              Non-empty only. systemd treats a
#   */var/lib/dbus/machine-id     zero-byte file as a deliberate
#                                 first-boot marker, which is the
#                                 correct way to ship one.
#   */var/lib/systemd/random-seed Entropy state; identical seeds on
#                                 every machine defeat the point.
#   */etc/hostid                  gethostid(3) / zfs / some init
#                                 scripts read this; per-machine.
#
# When this script fails, delete the offending file and let the
# relevant service (sshd-keygen@.service, systemd-machine-id-setup,
# systemd-random-seed.service) generate it on first boot.
#
# Usage:
#   scripts/verify-no-baked-identity.sh
#
# Exit status:
#   0 — clean
#   1 — one or more violations found (list printed to stderr)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

violations=()

add_if_bad() {
    local path="$1"
    case "$path" in
        */etc/machine-id|*/var/lib/dbus/machine-id)
            # Empty = deliberate first-boot marker; that's fine.
            [[ -s "$path" ]] && violations+=("$path")
            ;;
        *)
            violations+=("$path")
            ;;
    esac
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Only scan tracked files. Build-time generated content under
    # mkosi.extra/ (credstore blobs, per-image credential.secret,
    # fetched apt keyrings) is gitignored and must not trip this.
    while IFS= read -r -d '' path; do
        add_if_bad "$path"
    done < <(
        git ls-files -z \
            'mkosi.extra/etc/ssh/ssh_host_*' \
            'mkosi.extra/etc/machine-id' \
            'mkosi.extra/etc/hostid' \
            'mkosi.extra/var/lib/dbus/machine-id' \
            'mkosi.extra/var/lib/systemd/random-seed' \
            'mkosi.profiles/*/mkosi.extra/etc/ssh/ssh_host_*' \
            'mkosi.profiles/*/mkosi.extra/etc/machine-id' \
            'mkosi.profiles/*/mkosi.extra/etc/hostid' \
            'mkosi.profiles/*/mkosi.extra/var/lib/dbus/machine-id' \
            'mkosi.profiles/*/mkosi.extra/var/lib/systemd/random-seed' \
            'hosts/*/mkosi.extra/etc/ssh/ssh_host_*' \
            'hosts/*/mkosi.extra/etc/machine-id' \
            'hosts/*/mkosi.extra/etc/hostid' \
            'hosts/*/mkosi.extra/var/lib/dbus/machine-id' \
            'hosts/*/mkosi.extra/var/lib/systemd/random-seed' \
            2>/dev/null
    )
else
    # No git metadata (tarball build, shallow CI clone, etc.) —
    # fall back to a filesystem scan.
    while IFS= read -r -d '' path; do
        add_if_bad "${path#./}"
    done < <(
        find . \
            \( -path './mkosi.extra/*' \
               -o -path './mkosi.profiles/*/mkosi.extra/*' \
               -o -path './hosts/*/mkosi.extra/*' \) \
            \( \
                -name 'ssh_host_*' \
                -o -path '*/etc/machine-id' \
                -o -path '*/etc/hostid' \
                -o -path '*/var/lib/dbus/machine-id' \
                -o -path '*/var/lib/systemd/random-seed' \
            \) \
            -type f \
            -print0 2>/dev/null
    )
fi

if [[ ${#violations[@]} -eq 0 ]]; then
    exit 0
fi

cat >&2 <<'EOF'
ERROR: the following files are committed under mkosi.extra/ or
hosts/*/mkosi.extra/ and would be baked into every image built from
this tree. They are per-machine identity and must be generated at
first boot instead:

EOF
for v in "${violations[@]}"; do
    printf '  %s\n' "$v" >&2
done
cat >&2 <<'EOF'

Why this matters:
  * shared SSH host keys let an attacker impersonate one machine from
    another
  * shared machine-ids collapse systemd journal IDs, boot IDs, and
    DHCPv6 DUIDs across machines
  * a baked-in random-seed gives every machine the same initial
    entropy pool

Fix: remove the file(s) and let systemd / sshd generate them on first
boot. An empty (zero-byte) /etc/machine-id or /var/lib/dbus/machine-id
is accepted because systemd treats that as a deliberate first-boot
marker.
EOF
exit 1
