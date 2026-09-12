// Resets the demo to its opening state. Run before a take.
//
// The two payees are pointed at FRESH addresses rather than removed. `removePayee` leaves
// `everAllowed` set, so the panel would read "revoked" — a payee somebody approved and then
// dropped, which is a different story from "we just hired them". Moving the ENS record has
// no such residue, and it is what a name indirection is for.
import { createWalletClient, createPublicClient, http, parseAbi, namehash } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";

const RESOLVER = "0x607a4d7363d9E7511a932F82eAE1e12FB609915b";
const STANDARD = "0x88F2bfF031BB4Cf2BeAA28d47aDa52EbEebbc33b";

const t = http(process.env.SEPOLIA_RPC);
const admin = privateKeyToAccount(process.env.ADMIN_PK);
const wallet = createWalletClient({ account: admin, chain: sepolia, transport: t });
const pub = createPublicClient({ chain: sepolia, transport: t });
const ABI = parseAbi(["function setPolicy(bytes32 node, address policy)"]);

// Lowercase: viem refuses a mixed-case address that is not a valid EIP-55 checksum.
const [, , bluefinAddr, apiAddr] = process.argv;

const steps = [
  ["vendors.leash.eth", STANDARD, "the rule the demo opens on"],
  ["bluefin.leash.eth", bluefinAddr, "a contractor nobody has ever approved"],
  ["api.leash.eth", apiAddr, "a payee nobody has ever paid"],
];

for (const [name, target, why] of steps) {
  if (!target) throw new Error(`missing address for ${name}`);
  const h = await wallet.writeContract({
    address: RESOLVER, abi: ABI, functionName: "setPolicy",
    args: [namehash(name), target],
  });
  const r = await pub.waitForTransactionReceipt({ hash: h });
  console.log(`${name.padEnd(20)} -> ${target}  ${r.status}   (${why})`);
}
