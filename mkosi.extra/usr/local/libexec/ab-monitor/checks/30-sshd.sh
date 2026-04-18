#!/bin/bash
# checks/30-sshd.sh - sshd listening
set -uo pipefail

active="no"
systemctl is-active --quiet ssh.service  && active="yes"
systemctl is-active --quiet sshd.service && active="yes"

if [[ "${active}" != "yes" ]]; then
    jq -n '{key:"sshd_down", status:"fail", severity:"critical",
            summary:"neither ssh.service nor sshd.service is active",
            details:{}}'
    exit 0
fi

port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
port="${port:-22}"

if command -v ss >/dev/null; then
    if ! ss -H -tln "sport = :${port}" | grep -q LISTEN; then
        jq -n --argjson p "${port}" \
            '{key:"sshd_down", status:"fail", severity:"critical",
              summary:("nothing listening on TCP/" + ($p|tostring)),
              details:{port:$p}}'
        exit 0
    fi
fi

jq -n --argjson p "${port}" \
    '{key:"sshd_down", status:"ok", severity:"info",
      summary:("listening on TCP/" + ($p|tostring)),
      details:{port:$p}}'
