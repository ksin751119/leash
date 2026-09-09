// Sending one spend, and reading what the chain said about it.
//
// A policy block does NOT revert - src/LeashAccount.sol:802 emits SpendBlocked and returns
// normally, so the subgraph can index it. So a successful receipt is not a successful
// payment: the outcome is in the logs, and it has to be read there.
//
// Signing happens in-process. Never shell out to `cast send`: its --private-key flag has no
// environment variant, so the key would sit in argv where `ps` can read it.
import { createWalletClient, createPublicClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { reasonName } from "./reason.mjs";

// cast keccak, 2026-09-09.
export const TOPIC_EXECUTED =
  "0xf0b4af7bfd5a13b5eff4d2de508be60041b405cee18bf6f135c692be137d1381";
export const TOPIC_BLOCKED =
  "0x8ab53b1df82e8bdff7dad3143040ff0efb1d94506ab3e47853c38b5925c50828";

const ABI = parseAbi(["function spend(address token, address payee, uint256 amount)"]);
const lower = (a) => String(a ?? "").toLowerCase();

// SEPOLIA_RPC carries an API key, so no error string may contain it. Extracted and exported
// rather than inlined in the catch because sendSpend itself is not unit-tested - it needs a
// chain - and an untested redaction on a secret-bearing string is the defect Task 3 shipped:
// there the pinned test exercised the one path that was already safe, so the hole survived
// review. Keep the non-url detail: an error that says only "something went wrong" costs real
// debugging time on a path that fires when configuration is already broken.
export function redactUrls(text) {
  return String(text ?? "").replace(/https?:\/\/\S+/g, "<rpc>");
}

export function classifyReceipt(receipt, walletAddress) {
  const w = lower(walletAddress);
  const logs = (receipt?.logs ?? []).filter((l) => lower(l.address) === w);

  // Check for a block first: if both somehow appear, "blocked" is the safer reading.
  const b = logs.find((l) => lower(l.topics?.[0]) === TOPIC_BLOCKED);
  if (b) {
    // Non-indexed args, in order: node, amount, reason, policy, spentSoFar, limit.
    // reason is the third word. A short data field means we cannot say - do not guess.
    const hex = String(b.data ?? "0x").slice(2);
    if (hex.length < 64 * 3) return { outcome: "blocked", reason: null, reasonName: null };
    const word = hex.slice(64 * 2, 64 * 3);
    const reason = Number(BigInt("0x" + word));
    return { outcome: "blocked", reason, reasonName: reasonName(reason) };
  }

  if (logs.some((l) => lower(l.topics?.[0]) === TOPIC_EXECUTED)) {
    return { outcome: "executed", reason: null, reasonName: null };
  }
  return { outcome: "no-event", reason: null, reasonName: null };
}

export async function sendSpend({ rpcUrl, privKey, wallet, token, payee, amount }) {
  // Declared outside the try so the catch can still see it: a hash obtained before a later
  // failure (waitForTransactionReceipt timing out is the case that matters - 120s is ten
  // Sepolia blocks, and congestion makes it ordinary) must reach the caller. "Sent, outcome
  // unknown" and "never sent" are different states; conflating them by dropping the hash on
  // any error is what let a timeout re-arm an intent whose transaction might still land, and
  // pay it twice.
  let tx;
  try {
    const account = privateKeyToAccount(privKey);
    const transport = http(rpcUrl);
    const walletClient = createWalletClient({ account, chain: sepolia, transport });
    const publicClient = createPublicClient({ chain: sepolia, transport });

    tx = await walletClient.writeContract({
      address: wallet,
      abi: ABI,
      functionName: "spend",
      args: [token, payee, BigInt(amount)],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx, timeout: 120_000 });
    return { tx, ...classifyReceipt(receipt, wallet) };
  } catch (err) {
    // Never let an RPC url reach a log or a response: it can carry an API key.
    //
    // viem prepares the write with eth_estimateGas and a chain-id assert, so the failures
    // that actually happen against a live wallet - short MockUSDC balance, no Sepolia ETH,
    // an RPC that 401s - surface as an *estimation* error whose useful detail sits in
    // err.cause / err.details / err.metaMessages, not in err.shortMessage. Dropping those
    // is walking into a supervised run against a finite budget with "HTTP request failed."
    // Mirrors subgraph.mjs's approach to the same shape of nested error.
    const top = String(err?.shortMessage ?? err?.message ?? err).split("\n")[0];
    const causeMsg = err?.cause?.shortMessage ?? err?.cause?.message;
    const detail = err?.details;
    const meta = Array.isArray(err?.metaMessages) ? err.metaMessages.join(" ") : null;
    const full = [top, causeMsg, detail, meta].filter(Boolean).join(" — ");
    const msg = redactUrls(full);
    return tx ? { tx, error: msg } : { error: msg };
  }
}
