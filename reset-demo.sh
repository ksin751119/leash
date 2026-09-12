#!/usr/bin/env bash
# Puts the demo back to its opening state.
#
# The two payees are pointed at FRESH addresses rather than removed. `removePayee` leaves
# `everAllowed` set, so the panel would read "revoked" — a payee somebody approved and then
# dropped, which is a different and less flattering story than "we just hired them". And a
# payee that has been PAID reads "paid, never listed", which is beat four's punchline
# sitting on screen from the first frame.
#
# Moving the ENS record has no such residue, and it is what a name indirection is for.
#   ./reset-demo.sh                  # fresh addresses, generated
#   ./reset-demo.sh 0x… 0x…          # or supply your own
set -euo pipefail
cd /home/ubuntu/DEV/ETHOnline2026
set -a; . ./.env; set +a

STANDARD=0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b
# Fresh addresses, generated rather than invented. Between takes you need two the wallet
# has never seen, and thinking of them by hand is both a chore and a trap: the first pair
# picked this way differed from the ones they replaced in the last character, which on a
# 1080p frame is two addresses nobody can tell apart, one allowed and one not.
#
# Derived from the clock so they differ between runs, and padded out to a length that makes
# the shortened form on screen obviously distinct.
gen() { printf '0x%040x' "$(( 0x$(date +%s%N | sha256sum | cut -c1-12) ))"; }
BLUEFIN_NEW="${1:-$(gen)}"
sleep 1
API_NEW="${2:-$(gen)}"

node -e '
const { namehash } = require("/home/ubuntu/DEV/leash/agent/node_modules/viem");
for (const n of ["vendors.leash.eth","bluefin.leash.eth","api.leash.eth"])
  console.log(n, namehash(n));
' | while read -r name node; do echo "  $name -> $node"; done

nh() { node -e 'const{namehash}=require("/home/ubuntu/DEV/leash/agent/node_modules/viem");console.log(namehash(process.argv[1]))' "$1"; }

set_policy() { # node target label
  printf '%-22s ' "$3"
  cast send "$LEASH_RESOLVER" "setPolicy(bytes32,address)" "$1" "$2" \
    --private-key "$ADMIN_PK" --rpc-url "$SEPOLIA_RPC" --json \
    | jq -r '"tx \(.transactionHash)  status \(.status)"'
}

set_policy "$(nh vendors.leash.eth)" "$STANDARD"    "vendors -> Standard"
set_policy "$(nh bluefin.leash.eth)" "$BLUEFIN_NEW" "bluefin -> fresh"
set_policy "$(nh api.leash.eth)"     "$API_NEW"     "api     -> fresh"

echo
echo "=== state after reset ==="
echo -n "pointer   "; cast call "$LEASH_RESOLVER" "policyOf(bytes32)(address)" "$(nh vendors.leash.eth)" --rpc-url "$SEPOLIA_RPC"
for n in acme bluefin api; do
  a=$(cast call "$LEASH_RESOLVER" "policyOf(bytes32)(address)" "$(nh $n.leash.eth)" --rpc-url "$SEPOLIA_RPC")
  printf '%-9s %s  allowed=%s\n' "$n" "$a" \
    "$(cast call "$WALLET_ADDR" 'isPayeeAllowed(bytes32,address,address)(bool)' "$(nh vendors.leash.eth)" "$MOCK_USDC" "$a" --rpc-url "$SEPOLIA_RPC")"
done
spent=$(cast call "$WALLET_ADDR" "spentInCurrentPeriod(bytes32,address)(uint256)" "$(nh vendors.leash.eth)" "$MOCK_USDC" --rpc-url "$SEPOLIA_RPC" | awk '{print $1}')
echo "budget    $(python3 -c "print(f'{$spent/1e6:.2f}')") of 50.00 USDC spent this period"
