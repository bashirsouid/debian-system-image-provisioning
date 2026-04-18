#!/bin/bash
# checks/50-ab-switch-status.sh - current BLS entry not marked bad
set -uo pipefail

if ! command -v bootctl >/dev/null; then
    jq -n '{key:"ab_bad", status:"ok", severity:"info", summary:"bootctl unavailable", details:{}}'
    exit 0
fi

entry="$(bootctl 2>/dev/null | awk '/selected:/ {print $2; exit}')"

# Entries in /boot/loader/entries/ that contain ".bad." or "+0-<N>"
# (tries_left==0, tries_done>=1) are failed boot entries.
# Entries in /boot/loader/entries/ that contain ".bad." or "+0-<N>"
# (tries_left==0, tries_done>=1) are failed boot entries.
bad_files=""
shopt -s nullglob
for f in /boot/loader/entries/*.bad.* /boot/loader/entries/*+0-[1-9]*; do
    bad_files+="${f##*/}"$'\n'
done
shopt -u nullglob
bad_files="${bad_files%$'\n'}"

if [[ -n "${bad_files}" ]]; then
    jq -n --arg e "${entry:-unknown}" --arg b "${bad_files}" \
        '{key:"ab_bad", status:"fail", severity:"critical",
          summary:"one or more BLS entries are marked bad",
          details:{selected:$e, bad_entries:($b | split("\n") | map(select(length>0)))}}'
else
    jq -n --arg e "${entry:-unknown}" \
        '{key:"ab_bad", status:"ok", severity:"info",
          summary:"A/B healthy",
          details:{selected:$e}}'
fi
