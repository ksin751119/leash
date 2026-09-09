// agent/check-reason-table.mjs
// Reads src/Reason.sol and asserts agent/reason.mjs agrees with it, code for code.
//
// Why this exists: this repo now holds the same 13 numbers in three languages. A
// renumbering in Solidity would leave the agent confidently reporting the wrong reason to
// whoever is watching the demo - "over the limit" when the chain said "no human approved
// this". Nothing else would catch it, because each table is self-consistent.
//
// Run: node check-reason-table.mjs   (exit 0 = agree, 1 = drifted)
import { readFileSync } from "node:fs";
import { REASON } from "./reason.mjs";

const sol = readFileSync(new URL("../src/Reason.sol", import.meta.url), "utf8");

// uint8 internal constant NAME = 7;
const re = /uint8\s+internal\s+constant\s+([A-Z_]+)\s*=\s*(\d+)\s*;/g;
const fromSol = {};
for (const m of sol.matchAll(re)) fromSol[m[1]] = Number(m[2]);

// Guard against regex falling behind Solidity formatting: count all `internal constant`
// declarations and fail if the number parsed does not match.
const constantCount = (sol.match(/internal\s+constant/g) || []).length;
const solNames = Object.keys(fromSol).sort();
const jsNames = Object.keys(REASON).sort();
let bad = 0;

if (solNames.length === 0) {
  console.log("FAIL  parsed 0 constants out of src/Reason.sol - the regex no longer matches");
  process.exit(1);
}

if (solNames.length !== constantCount) {
  console.log(`FAIL  parsed ${solNames.length} constants but found ${constantCount} internal constant declarations - the regex has fallen behind the Solidity formatting`);
  process.exit(1);
}

for (const name of new Set([...solNames, ...jsNames])) {
  const s = fromSol[name];
  const j = REASON[name];
  const ok = s !== undefined && j !== undefined && s === j;
  if (!ok) bad++;
  console.log(
    `${ok ? "ok  " : "FAIL"}  ${name.padEnd(20)} solidity=${s ?? "(absent)"} js=${j ?? "(absent)"}`,
  );
}

console.log(bad === 0 ? `\nall ${solNames.length} codes agree` : `\n${bad} MISMATCH`);
process.exit(bad === 0 ? 0 : 1);
