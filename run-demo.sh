#!/usr/bin/env bash
# Starts the whole demo: the page server on 8787, and one agent process per key.
#
#   ./run-demo.sh              # the real thing — the first tick SPENDS MONEY
#   ./run-demo.sh --dry        # same wiring, no payments (empty intent list)
#   ./run-demo.sh --stop       # stop everything, and stop burning the subgraph quota
#
# Two agents, one wallet. Each process is given ONLY the key it is allowed to hold; the
# .env is never sourced, because it also holds WALLET_PK and WORLD_RP_SIGNER_PK and an
# agent process holding either of those would invert the model this demo exists to show.
#
# The agents share a budget because they share a NAME, not because these two commands know
# about each other — `spent[node][token][bucket]` has no agent in its key. Neither process
# is told the other exists.
set -euo pipefail
ENV="${LEASH_ENV:-/home/ubuntu/DEV/ETHOnline2026/.env}"
LOG="${LEASH_LOG_DIR:-/tmp/leash}"
mkdir -p "$LOG"
get() { grep -m1 "^$1=" "$ENV" | cut -d= -f2- | tr -d '\r'; }

# Stop everything. Not a convenience: two agents ticking every 8 s is 900 subgraph
# queries an hour, and leaving them idle overnight is what exhausted three Studio
# deployments in a row — the quota was never spent by anybody using the demo. Stop them
# when you are not watching and the deployment survives to the next day.
if [ "${1:-}" = "--stop" ]; then
  pkill -f "node server.mjs" 2>/dev/null || true
  pkill -f "node loop.mjs"   2>/dev/null || true
  sleep 1
  echo "stopped. The subgraph stops being queried, which is the point."
  exit 0
fi

INTENTS="${AGENT_INTENTS:-$PWD/agent/intents.json}"
if [ "${1:-}" = "--dry" ]; then
  echo '[]' > "$LOG/no-intents.json"
  INTENTS="$LOG/no-intents.json"
  echo "dry run: the agents will propose nothing until you ask them to"
fi

pkill -f "node server.mjs" 2>/dev/null || true
pkill -f "node loop.mjs"   2>/dev/null || true
sleep 1

( cd world && \
  ADMIN_PK="$(get ADMIN_PK)" SEPOLIA_RPC="$(get SEPOLIA_RPC)" \
  WALLET_ADDR="$(get WALLET_ADDR)" LEASH_NODE="$(get LEASH_NODE)" \
  WORLD_APP_ID="$(get WORLD_APP_ID)" WORLD_RP_ID="$(get WORLD_RP_ID)" \
  WORLD_ACTION="$(get WORLD_ACTION)" WORLD_ATTESTER="$(get WORLD_ATTESTER)" \
  WORLD_RP_SIGNER_PK="$(get WORLD_RP_SIGNER_PK)" MOCK_USDC="$(get MOCK_USDC)" \
  LEASH_RESOLVER="$(get LEASH_RESOLVER)" STANDARD_POLICY="$(get STANDARD_POLICY)" \
    nohup node server.mjs > "$LOG/server.log" 2>&1 & )

start_agent() { # name port pk_var addr_var
  ( cd agent && \
    AGENT_NAME="$1" PORT="$2" \
    AGENT_PK="$(get "$3")" AGENT_ADDR="$(get "$4")" \
    SEPOLIA_RPC="$(get SEPOLIA_RPC)" WALLET_ADDR="$(get WALLET_ADDR)" \
    LEASH_NODE="$(get LEASH_NODE)" STANDARD_POLICY="$(get STANDARD_POLICY)" \
    MOCK_USDC="$(get MOCK_USDC)" LEASH_RESOLVER="$(get LEASH_RESOLVER)" \
    SUBGRAPH_URL="$(get SUBGRAPH_URL)" AGENT_TICK_MS="${AGENT_TICK_MS:-4000}" \
    AGENT_INTENTS="$INTENTS" \
      nohup node loop.mjs > "$LOG/agent-$1.log" 2>&1 & )
}

start_agent payments      8788 AGENT_PK  AGENT_ADDR
start_agent subscriptions 8789 AGENT2_PK AGENT2_ADDR

sleep 4
echo
echo "  the page is the only thing to open:"
echo "     http://localhost:8787/?agent=payments"
echo "     http://localhost:8787/?agent=subscriptions"
echo
# The agents serve /api/agent/state and nothing else — opening localhost:8788 in a
# browser correctly returns {"error":"not found"}. Reporting a bare HTTP code here
# made that look like a dead process, so report what is actually true instead.
for p in 8788 8789; do
  body=$(curl -s --max-time 5 "localhost:$p/api/agent/state" || true)
  name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null || true)
  if [ -n "$name" ]; then
    printf '  agent %-14s up on :%s  (state endpoint only; it serves no page)\n' "$name" "$p"
  else
    printf '  agent on :%s did NOT answer — see %s/agent-*.log\n' "$p" "$LOG"
  fi
done
