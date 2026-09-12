#!/usr/bin/env bash
# Measures one beat end to end, in the states a viewer can SEE on the page.
# The word count only measures talking; this is the other half of the runtime.
set -euo pipefail
PORT="${1:-8788}"
INSTR="${2:?instruction}"
t0=$(date +%s%3N)
ms() { echo "$(( $(date +%s%3N) - t0 ))"; }
say() { printf '%7sms  %s\n' "$(ms)" "$1"; }

say "Ask pressed"
R=$(curl -s --max-time 150 -X POST "localhost:$PORT/api/agent/instruct" \
      -H 'Content-Type: application/json' -d "{\"instruction\":$(printf '%s' "$INSTR" | jq -Rs .)}")
say "model answered and the card appeared   (model alone: $(echo "$R" | jq -r '.instruction.tookMs')ms)"

id=$(echo "$R" | jq -r '.intents[0].id')
[ "$id" = "null" ] && { echo "no intent proposed"; exit 1; }

seen_tx=0
for _ in $(seq 1 90); do
  S=$(curl -s "localhost:$PORT/api/agent/state")
  tx=$(echo "$S" | jq -r --arg i "$id" '.intents[]|select(.id==$i)|.lastAction.tx // empty')
  oc=$(echo "$S" | jq -r --arg i "$id" '.intents[]|select(.id==$i)|.lastAction.outcome // empty')
  if [ -n "$tx" ] && [ "$seen_tx" = 0 ]; then say "transaction sent  $tx"; seen_tx=1; fi
  if [ -n "$oc" ]; then say "receipt classified: $oc  — the card says DONE"; break; fi
  sleep 1
done

spent_before=$(curl -s "localhost:$PORT/api/agent/state" | jq -r '.budget.spent')
for _ in $(seq 1 90); do
  s=$(curl -s "localhost:$PORT/api/agent/state" | jq -r '.budget.spent')
  if [ "$s" != "$spent_before" ]; then say "the budget bar moved  ($spent_before -> $s)"; break; fi
  sleep 1
done
