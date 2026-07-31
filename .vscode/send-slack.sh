#!/usr/bin/env bash
# Post STDIN to Slack via chat.postMessage. Bot token is a SECRET, never in-repo.
# Token from: $SLACK_BOT_TOKEN, then Keychain (dre-slackbot-token).
# Usage: echo "*hi*" | send-slack.sh [channel_id_or_#name]
set -euo pipefail
command -v jq >/dev/null || { echo "[ERROR] jq required (brew install jq)." >&2; exit 1; }

CHANNEL="${1:-${SLACK_CHANNEL:-#dre-denver}}"
TOKEN="${SLACK_BOT_TOKEN:-}"
[ -z "$TOKEN" ] && TOKEN=$(security find-generic-password -s dre-slackbot-token -w 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  echo "[ERROR] No bot token. Store it: security add-generic-password -a \"\$USER\" -s dre-slackbot-token -w 'xoxb-...'" >&2
  exit 1
fi
case "$TOKEN" in xox*) ;; *) echo "[ERROR] Not a Slack token (expect xoxb-...) - refusing." >&2; exit 1;; esac

MSG=$(cat)
[ -z "${MSG// }" ] && { echo "[ERROR] Empty message on stdin." >&2; exit 1; }

RESP=$(jq -n --arg c "$CHANNEL" --arg t "$MSG" '{channel:$c, text:$t}' \
  | curl -sS -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-type: application/json; charset=utf-8' --data @-)

if [ "$(printf '%s' "$RESP" | jq -r '.ok')" = "true" ]; then
  echo "[OK] Posted to $CHANNEL (ts=$(printf '%s' "$RESP" | jq -r '.ts'))."
else
  echo "[FAIL] Slack error: $(printf '%s' "$RESP" | jq -r '.error')" >&2
  exit 1
fi
