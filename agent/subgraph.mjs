// The one read the agent makes per tick.
//
// Entity ids in the deployed index are LOWERCASE, while .env holds checksummed addresses.
// Interpolating a checksummed address returns an empty result, and because this module fails
// closed, that surfaces as "the agent does nothing" - a symptom that looks nothing like its
// cause. buildIds is separate and directly tested for exactly that reason.
const lower = (a) => String(a ?? "").toLowerCase();

export function buildIds({ wallet, node, agent, token }) {
  const w = lower(wallet);
  const n = lower(node);
  return {
    agent: `${w}-${lower(agent)}`,
    budget: `${w}-${n}-${lower(token)}`,
    node: n,
    wallet: w,
  };
}

// Payees are filtered on the `wallet` and `node` FIELDS, not by an id prefix.
// `id_starts_with` is not available on an `ID!` field in graph-node - verified against the
// live index on 2026-09-09, which answers "Invalid value provided for argument `where`".
// Both fields are `Bytes!` in the schema, so they take lowercase hex.
const QUERY = `
query AgentState($agentId: ID!, $budgetId: ID!, $node: ID!, $wallet: Bytes!, $nodeBytes: Bytes!) {
  _meta { block { number } }
  agent(id: $agentId) { id revoked }
  subname(id: $node) { label live }
  policyPointer(id: $node) { policy approved }
  agentBudget(id: $budgetId) { token limit spent periodEnd }
  payees(where: { wallet: $wallet, node: $nodeBytes }) { payee allowed lastToken }
}`;

export async function fetchSnapshot(cfg, fetchImpl = fetch) {
  const ids = buildIds(cfg);
  let body;
  try {
    const res = await fetchImpl(cfg.url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: QUERY,
        variables: {
          agentId: ids.agent,
          budgetId: ids.budget,
          node: ids.node,
          wallet: ids.wallet,
          nodeBytes: ids.node,
        },
      }),
    });
    // Never put cfg.url in an error: a subgraph url can carry an API key.
    if (!res.ok) return { ok: false, error: `subgraph returned HTTP ${res.status}` };
    body = await res.json();
  } catch (err) {
    // Never put cfg.url in an error: a subgraph url can carry an API key.
    // The exception path can leak the URL in err.message (Node's fetch does this).
    const raw = String(err?.message ?? err);
    const safe = cfg.url ? raw.split(cfg.url).join("<redacted>") : raw;
    return { ok: false, error: `subgraph unreachable: ${safe}` };
  }

  if (body?.errors?.length) {
    return { ok: false, error: `subgraph errors: ${body.errors.map((e) => e.message).join("; ")}` };
  }
  const d = body?.data;
  const blockNumber = d?._meta?.block?.number;
  if (typeof blockNumber !== "number") {
    // Deciding without knowing how far behind the index is would make every verdict
    // unfalsifiable. Fail closed instead.
    return { ok: false, error: "subgraph did not report _meta.block.number" };
  }

  const payees = {};
  for (const p of d.payees ?? []) {
    payees[lower(p.payee)] = { allowed: p.allowed === true, lastToken: p.lastToken ? lower(p.lastToken) : null };
  }

  const chain = typeof cfg.chainBlock === "number" ? cfg.chainBlock : blockNumber;
  return {
    ok: true,
    block: { subgraph: blockNumber, chain, lag: Math.max(0, chain - blockNumber) },
    agent: { address: lower(cfg.agent), revoked: d.agent?.revoked === true },
    subname: d.subname ? { label: d.subname.label, live: d.subname.live === true } : null,
    policy: d.policyPointer
      ? { address: lower(d.policyPointer.policy), approved: d.policyPointer.approved === true }
      : null,
    budget: d.agentBudget
      ? {
          token: lower(d.agentBudget.token),
          limit: String(d.agentBudget.limit),
          spent: String(d.agentBudget.spent),
          periodEnd: Number(d.agentBudget.periodEnd ?? 0),
        }
      : null,
    payees,
  };
}
