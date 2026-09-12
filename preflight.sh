#!/usr/bin/env bash
# Everything that has to be true before recording, checked rather than remembered.
#
# READ ONLY. It sends no transaction and starts no process. Run it, read the FAILs, fix
# them, run it again. Every check here exists because something went wrong once.
set -uo pipefail
cd "$(dirname "$0")"
ENV="${LEASH_ENV:-/home/ubuntu/DEV/ETHOnline2026/.env}"
set -a; . "$ENV"; set +a

STANDARD=0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b
POLICYSET=0xec45e967F4e907B92bb1A9a8b4fcF9F041792490
APPROVALS=0x7CB9d4Ac84C7Df38CEF5deCc8cDd8703eCa925B4
OWNER_NULLIFIER=0x180f9ee15bedaa3c1912ea178de159e0997ecaea8751f1b3f9f880601b49e881

fails=0; warns=0
pass() { printf '  \033[32mok  \033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; warns=$((warns+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
nh() { node -e 'const{namehash}=require("./agent/node_modules/viem");console.log(namehash(process.argv[1]))' "$1"; }
# Never swallow an error into a default. A read that fails returns the literal string
# ERR, which every caller below treats as a mismatch rather than as a zero.
call() { cast call "$@" --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo ERR; }
num() { # a numeric read, or ERR — never a silent 0
  v=$(call "$@" | awk '{print $1}')
  case "$v" in (''|ERR|*[!0-9]*) echo ERR ;; (*) echo "$v" ;; esac
}
usdc() { python3 -c "print(f'{$1/1e6:.2f}')"; }

NODE=$(nh vendors.leash.eth)

head_ "1. the face"
[ "$WORLD_ACTION" = "leash-owner" ] \
  && pass "WORLD_ACTION=leash-owner" \
  || fail "WORLD_ACTION is '$WORLD_ACTION' — it must be leash-owner, or the scan produces a different nullifier and the widening is refused"
on=$(num "$WALLET_ADDR" "ownerNullifier()(uint256)")
if [ "$on" = ERR ]; then fail "could not read ownerNullifier — is the wallet still delegated?"
elif [ "$(python3 -c "print(hex($on))")" = "$OWNER_NULLIFIER" ]; then pass "ownerNullifier matches the registered face"
else fail "ownerNullifier is $on — expected $OWNER_NULLIFIER"; fi

head_ "2. the rule the demo opens on"
p=$(call "$LEASH_RESOLVER" "policyOf(bytes32)(address)" "$NODE")
[ "$p" = "$STANDARD" ] && pass "pointer -> StandardPolicy" \
  || fail "pointer is $p — must be StandardPolicy ($STANDARD). ./reset-demo.sh fixes it"
for a in "$STANDARD" "$POLICYSET"; do
  [ "$(call "$APPROVALS" "isApproved(address)(bool)" "$a")" = "true" ] \
    && pass "approved: $a" || fail "NOT approved: $a — beat 4 has nothing to switch to"
done

head_ "3. the payees"
for pair in "acme true" "bluefin false" "api false"; do
  set -- $pair
  addr=$(call "$LEASH_RESOLVER" "policyOf(bytes32)(address)" "$(nh $1.leash.eth)")
  got=$(call "$WALLET_ADDR" "isPayeeAllowed(bytes32,address,address)(bool)" "$NODE" "$MOCK_USDC" "$addr")
  [ "$got" = "$2" ] && pass "$1 $addr allowed=$got" \
    || fail "$1 $addr allowed=$got, expected $2 — ./reset-demo.sh points it at a fresh address"
done

head_ "4. the budget"
# The room a full run needs: 5.00 retainer + 5.00 Bluefin (after the scan) + 0.50 top-up.
# Beat 3 is refused and costs nothing. Reporting only pass/fail here is not enough — what
# an operator needs to know at 2am is WHICH beats still fit, because the one carrying the
# only unmeasured wait (the face scan) is beat 2, and it needs 5.50 rather than 10.50.
spent=$(num "$WALLET_ADDR" "spentInCurrentPeriod(bytes32,address)(uint256)" "$NODE" "$MOCK_USDC")
rollover=$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
nxt = (now + datetime.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
print(str(nxt - now).split('.')[0])")
if [ "$spent" = ERR ]; then
  fail "could not read spentInCurrentPeriod — check MOCK_USDC and LEASH_NODE in .env"
else
  room=$((50000000 - spent))
  if [ "$spent" -lt 2000000 ]; then
    pass "$(usdc $spent) of 50.00 spent — every beat fits and the script's numbers match the screen"
  elif [ "$room" -ge 10500000 ]; then
    warn "$(usdc $spent) of 50.00 spent. All four beats run, but 'five dollars out of fifty' will not match the screen. Zeroes itself in $rollover"
  elif [ "$room" -ge 5500000 ]; then
    warn "$(usdc $spent) of 50.00 spent — $(usdc $room) left. Beat 1 will not fit, but beats 2, 3 and 4 will, which is enough to TIME THE FACE SCAN. Zeroes itself in $rollover"
  else
    fail "$(usdc $spent) of 50.00 spent — only $(usdc $room) left, not enough for beat 2. No reduction can clear the ledger; it zeroes itself in $rollover"
  fi
fi

head_ "5. money and gas"
bal=$(num "$MOCK_USDC" "balanceOf(address)(uint256)" "$WALLET_ADDR")
if [ "$bal" = ERR ]; then fail "could not read the wallet's USDC balance"
elif [ "$bal" -gt 60000000 ]; then pass "wallet holds $(usdc $bal) USDC"
else fail "wallet holds $(usdc $bal) USDC — not enough for a full run"; fi
for pair in "AGENT $AGENT_ADDR" "AGENT2 $AGENT2_ADDR" "ADMIN $ADMIN_ADDR"; do
  set -- $pair
  wei=$(cast balance "$2" --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo 0)
  eth=$(python3 -c "print(f'{int('${wei:-0}')/1e18:.4f}')")
  python3 -c "import sys; sys.exit(0 if float('$eth') > 0.005 else 1)" \
    && pass "$1 has $eth ETH" || fail "$1 has $eth ETH — too little to send"
done

head_ "6. both agents are bound to the same name"
for pair in "AGENT $AGENT_ADDR" "AGENT2 $AGENT2_ADDR"; do
  set -- $pair
  got=$(call "$WALLET_ADDR" "bindingOf(address)(bytes32,string,bool)" "$2" | head -1)
  [ "$got" = "$NODE" ] && pass "$1 bound to vendors.leash.eth" || fail "$1 binding is $got"
done

head_ "7. the vendor directory"
# The amounts here are what the model reads and therefore what gets paid, and the narration
# says three of them out loud. A directory that has drifted from the script is a mismatch a
# viewer catches and nobody rehearsing notices.
#
# They are small on purpose: a full run costs 3.50 against a 50.00 daily budget, which is
# fourteen takes a day. At 5.00 and 5.00 it was four, and a bad morning would have run out
# of budget before it ran out of time.
for want in "1.00 USDC per month" "first invoice is 2.00 USDC" "0.50 USDC at a time"; do
  grep -q "$want" agent/vendors.json \
    && pass "vendors.json: $want" \
    || fail "vendors.json does not say '$want' — the narration says it out loud"
done

head_ "8. the index"
code=$(curl -s -o /tmp/pf.json -w '%{http_code}' -m 15 -X POST "$SUBGRAPH_URL" \
  -H 'Content-Type: application/json' -d '{"query":"{_meta{block{number}}}"}')
if [ "$code" = "200" ] && [ "$(jq -r '.data._meta.block.number // "x"' /tmp/pf.json)" != "x" ]; then
  ib=$(jq -r '.data._meta.block.number' /tmp/pf.json)
  cb=$(cast block-number --rpc-url "$SEPOLIA_RPC" 2>/dev/null || echo "$ib")
  lag=$((cb - ib))
  [ "$lag" -lt 5 ] && pass "subgraph synced, $lag block(s) behind  (${SUBGRAPH_URL##*/})" \
    || warn "subgraph is $lag blocks behind — wait before recording"
else
  fail "subgraph returned HTTP $code. If 429: it is throttled. Deploy a fresh version label"
fi

head_ "9. the processes"
for pair in "8787 page" "8788 payments" "8789 subscriptions"; do
  set -- $pair
  if [ "$1" = "8787" ]; then
    [ "$(curl -s -o /dev/null -m 4 -w '%{http_code}' "localhost:$1/")" = "200" ] \
      && pass "page on :8787" || warn "page not running — ./run-demo.sh --dry"
  else
    n=$(curl -s -m 4 "localhost:$1/api/agent/state" | jq -r '.name // empty')
    [ "$n" = "$2" ] && pass "agent '$n' on :$1" || warn "agent '$2' not running on :$1 — ./run-demo.sh --dry"
  fi
done

printf '\n\033[1m%s\033[0m\n' "$([ $fails -eq 0 ] && echo "READY — $warns warning(s)" || echo "$fails BLOCKER(S), $warns warning(s)")"
exit $((fails > 0))
