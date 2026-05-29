#!/bin/bash
# /usr/local/libexec/ab-monitor/notifiers/mailjet.sh
#
# Reads the alert envelope from AB_* env vars (set by notify.sh), reads
# the Mailjet credentials from $CREDENTIALS_DIRECTORY/mailjet_public_key
# and $CREDENTIALS_DIRECTORY/mailjet_private_key, and POSTs an email
# via the Mailjet v3.1 Send API.
#
# API docs: https://dev.mailjet.com/email/guides/send-api-v31/

set -uo pipefail

# shellcheck source=/dev/null
source /etc/default/ab-monitor

log() { printf '[mailjet] %s\n' "$*" >&2; }

: "${CREDENTIALS_DIRECTORY:?not set; mailjet notifier must be run from a systemd unit with LoadCredential=}"

if [[ ! -r "${CREDENTIALS_DIRECTORY}/mailjet_public_key" || ! -r "${CREDENTIALS_DIRECTORY}/mailjet_private_key" ]]; then
    log "no mailjet credentials; cannot send email."
    exit 1
fi

MJ_PUB="$(cat "${CREDENTIALS_DIRECTORY}/mailjet_public_key")"
MJ_PRIV="$(cat "${CREDENTIALS_DIRECTORY}/mailjet_private_key")"

if [[ -z "${AB_MONITOR_EMAIL_TO:-}" || -z "${AB_MONITOR_EMAIL_FROM:-}" ]]; then
    log "AB_MONITOR_EMAIL_TO / AB_MONITOR_EMAIL_FROM not set; skipping."
    exit 1
fi

sev_upper="$(tr '[:lower:]' '[:upper:]' <<<"${AB_SEVERITY}")"
case "${AB_EVENT}" in
    trigger) subject="[${AB_HOST}] ${sev_upper}: ${AB_SUMMARY}" ;;
    resolve) subject="[${AB_HOST}] RESOLVED: ${AB_KEY}" ;;
    *)       subject="[${AB_HOST}] ${AB_EVENT}: ${AB_KEY}" ;;
esac

# Pretty-print details for the body
details_pretty="$(jq -r 'to_entries | map("  \(.key): \(.value)") | .[]' <<<"${AB_DETAILS}" 2>/dev/null || echo "  (none)")"

read -r -d '' text_body <<EOF || true
Host:       ${AB_HOST}
Time:       ${AB_TIMESTAMP}
Event:      ${AB_EVENT}
Key:        ${AB_KEY}
Severity:   ${AB_SEVERITY}
Summary:    ${AB_SUMMARY}

Details:
${details_pretty}

Runbook: ${AB_RUNBOOK_URL:-<not configured>}

--
This message was sent by ab-monitor on ${AB_HOST}.
EOF

# Build the JSON payload via jq so special characters in the summary
# cannot break out of the string context.
payload="$(jq -n \
    --arg to "${AB_MONITOR_EMAIL_TO}" \
    --arg from "${AB_MONITOR_EMAIL_FROM}" \
    --arg from_name "${AB_MONITOR_EMAIL_FROM_NAME:-AB Monitor}" \
    --arg subject "${subject}" \
    --arg text "${text_body}" \
    '{
        Messages: [
            {
                From: { Email: $from, Name: $from_name },
                To: [ { Email: $to } ],
                Subject: $subject,
                TextPart: $text
            }
        ]
    }')"

http_code="$(curl \
    --silent --show-error \
    --max-time "${AB_MONITOR_HTTP_TIMEOUT:-10}" \
    --output /dev/null \
    --write-out '%{http_code}' \
    -X POST https://api.mailjet.com/v3.1/send \
    --user "${MJ_PUB}:${MJ_PRIV}" \
    -H "Content-Type: application/json" \
    --data-raw "${payload}" 2>&1)"
rc=$?

unset MJ_PUB MJ_PRIV

if (( rc != 0 )); then
    log "curl exit ${rc}"
    exit 2
fi

if [[ "${http_code}" != "200" ]]; then
    log "Mailjet returned HTTP ${http_code}"
    exit 3
fi

log "sent: ${AB_EVENT} ${AB_KEY} -> ${AB_MONITOR_EMAIL_TO} (HTTP ${http_code})"
exit 0
