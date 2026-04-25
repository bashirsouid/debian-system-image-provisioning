#!/bin/bash
# /usr/local/libexec/ab-health-check.d/30-sshd.sh
#
# Fails health if sshd is not active or not listening on the expected
# port. Without SSH we lose remote management; refusing to bless a
# slot that cannot be SSH'd into is the whole point of having the
# out-of-band paths in the first place.

set -euo pipefail

log() { printf '[ab-health 30-sshd] %s\n' "$*" >&2; }

if ! systemctl is-active --quiet ssh.service && \
   ! systemctl is-active --quiet sshd.service; then
    log "FAIL: neither ssh.service nor sshd.service is active."
    exit 1
fi

# Does sshd -T produce a valid config?
if ! /usr/sbin/sshd -t 2>/dev/null; then
    log "FAIL: sshd -t reports invalid config."
    /usr/sbin/sshd -t >&2 || true
    exit 1
fi

# Is the configured port actually bound?
port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
port="${port:-22}"

if command -v ss >/dev/null 2>&1; then
    if ! ss -H -tln "sport = :${port}" | grep -q LISTEN; then
        log "FAIL: nothing listening on TCP/${port}."
        exit 1
    fi
fi

log "ok: sshd active and listening on ${port}."
exit 0
