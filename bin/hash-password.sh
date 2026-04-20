#!/bin/bash
# bin/hash-password.sh
#
# Interactive helper: prompts for a password (no echo), prints either:
#   1. just the yescrypt hash (default, back-compatible with old callers), or
#   2. a ready-to-paste JSON user entry for .users.json (with --json).
#
# Usage:
#   ./bin/hash-password.sh                          # print hash only
#   ./bin/hash-password.sh --json --username demo   # print full entry
#   ./bin/hash-password.sh --json --username alice --uid 1001
#
# Does not write the password or the hash to any file.

set -euo pipefail

JSON=false
USERNAME=""
UID_VAL=""
GROUPS_VAL="sudo,audio,video,render,input,plugdev,dialout"

usage() {
    cat <<'USAGE'
Usage: ./bin/hash-password.sh [options]

Options:
  --json              emit a complete JSON entry ready for .users.json
                      instead of just the hash
  --username NAME     username to put in the JSON entry (with --json)
  --uid N             uid to pin in the JSON entry (with --json; default: auto)
  --groups CSV        supplementary groups (with --json)
                      default: sudo,audio,video,render,input,plugdev,dialout
  -h, --help          show this help

The password is read from stdin with echo disabled and is confirmed
twice. Minimum length is 12 characters. The hash is yescrypt when the
host's mkpasswd supports it, sha512crypt otherwise.

Examples:
  # Produce just the hash (back-compatible behavior):
  ./bin/hash-password.sh

  # Produce a full user entry to paste into .users.json:
  ./bin/hash-password.sh --json --username bashir --uid 1000
USAGE
}

fail() { printf '[hash-password] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)      JSON=true; shift ;;
        --username)  USERNAME="${2:?missing username}"; shift 2 ;;
        --uid)       UID_VAL="${2:?missing uid}"; shift 2 ;;
        --groups)    GROUPS_VAL="${2:?missing groups csv}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

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

# Prompts go to stderr so '--json > entry.json' and hash-only piping
# both stay clean.
{
    echo "Enter a password. It will not be echoed."
    if [[ "$JSON" == true ]]; then
        echo "A JSON user entry will be printed to stdout."
    else
        echo "The hash (NOT the password) will be printed to stdout."
    fi
    echo
} >&2

read -r -s -p "Password: " p1 >&2 || fail "read failed"
printf '\n' >&2
read -r -s -p "Confirm : " p2 >&2 || fail "read failed"
printf '\n' >&2

if [[ "${p1}" != "${p2}" ]]; then
    unset p1 p2
    fail "passwords did not match."
fi

if [[ ${#p1} -lt 12 ]]; then
    unset p1 p2
    fail "password is shorter than 12 characters; pick a stronger one."
fi

hash="$(printf '%s' "${p1}" | mkpasswd --method="${method}" -s)"
unset p1 p2

if [[ "$JSON" == false ]]; then
    printf '%s\n' "${hash}"
    cat >&2 <<'HINT'

Paste the hash above into the "password_hash" field of the relevant user
in .users.json. To get a full ready-to-paste JSON entry instead, rerun
with --json --username NAME.
HINT
    exit 0
fi

# --json path. Prefer jq if available for correct string escaping.
if command -v jq >/dev/null 2>&1; then
    jq -n \
        --arg username   "${USERNAME:-CHANGE_ME}" \
        --arg group      "${USERNAME:-CHANGE_ME}" \
        --arg groups_csv "$GROUPS_VAL" \
        --arg uid        "$UID_VAL" \
        --arg hash       "$hash" \
        '{
            username: $username,
            can_login: true,
            primary_group: $group,
            groups: ($groups_csv | split(",") | map(select(length > 0))),
            shell: "/bin/bash",
            password_hash: $hash
        }
        | if ($uid | length) > 0 then .uid = ($uid | tonumber) else . end'
else
    groups_json="$(printf '%s' "$GROUPS_VAL" | awk -F, '
        BEGIN { printf "[" }
        {
            for (i=1; i<=NF; i++) {
                if (i>1) printf ", "
                printf "\"%s\"", $i
            }
        }
        END { print "]" }
    ')"
    uid_line=""
    if [[ -n "$UID_VAL" ]]; then
        uid_line="  \"uid\": ${UID_VAL},"$'\n'
    fi
    cat <<JSON
{
  "username": "${USERNAME:-CHANGE_ME}",
  "can_login": true,
${uid_line}  "primary_group": "${USERNAME:-CHANGE_ME}",
  "groups": ${groups_json},
  "shell": "/bin/bash",
  "password_hash": "${hash}"
}
JSON
fi
