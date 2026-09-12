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
  agent(id: $agentId) { id revoked node }
  subname(id: $node) { label live }
  policyPointer(id: $node) { policy approved }
  # What a human wrote when they approved a policy. The pointer names an address; this is
  # the sentence that address was approved AS, and it is the only human-readable thing in
  # the whole control plane. Fetched as a list because GraphQL cannot chain one lookup into
  # another in a single query, and there are two of them.
  approvedPolicies(first: 20) { id description approved }
  agentBudget(id: $budgetId) { token limit spent periodEnd remaining }
  payees(where: { wallet: $wallet, node: $nodeBytes }) { payee allowed everAllowed lastToken }
  # Every agent bound to this node — not just the one asking. The budget entity above is
  # keyed by (wallet, node, token) and has no agent in it, so a page that shows one agent
  # beside one budget invites the reader to assume the budget is that agent's. It is not.
  agents(where: { wallet: $wallet, node: $nodeBytes }) { agent revoked spendCount blockedCount boundAt }
  # Every spend attempt against this node, executed and refused alike, most recent first.
  #
  # The refused ones exist nowhere else. A policy violation is a no-op plus an event, not a
  # revert, so there is no getter anywhere on chain that will tell you what was turned away
  # today — the log is the only record, and this is the only thing that reads it.
  spends(where: { node: $nodeBytes }, orderBy: timestamp, orderDirection: desc, first: 60) {
    agent payee amount executed reason reasonName spentAfter timestamp txHash
  }
}`;

// Who spent the shared budget, and how much of it each of them spent.
//
// The onchain ledger is `spent[node][token][bucket]` — three keys, none of them an agent —
// so the chain itself keeps no per-agent figure and neither does the index. This
// reconstructs one from the spend log, and it does it by *arithmetic on the log* rather
// than by assuming a period length:
//
//   the most recent executed spend must have left `spentAfter` equal to the budget's
//   current `spent`. Subtract its `amount` and you have the total before it, which is
//   the `spentAfter` of the spend before that — and so on, until the running total
//   reaches zero, which is the first spend of the current period.
//
// The chain breaking is the period boundary. That is why nothing here needs to know that
// the period happens to be 86400 seconds, and why a rule whose period changes does not
// silently make this wrong.
//
// Pure, so the walk is testable without a subgraph.
export function buildCohort(agents, spends, budget) {
  const rows = new Map();
  for (const a of agents ?? []) {
    rows.set(lower(a.agent), {
      address: lower(a.agent),
      revoked: a.revoked === true,
      spendCount: Number(a.spendCount ?? 0),
      blockedCount: Number(a.blockedCount ?? 0),
      boundAt: Number(a.boundAt ?? 0),
      spentThisPeriod: "0",
    });
  }

  // Index by the total each spend left behind. Ties across periods are possible in
  // principle (yesterday passed through the same running total); prefer the later one,
  // since the walk starts at the present and moves backwards.
  const byTotal = new Map();
  for (const s of spends ?? []) {
    // A REFUSED attempt must never enter this walk. `subgraph/src/account.ts` records
    // `SpendBlocked.spentSoFar` in the same `spentAfter` field, so a refusal carries a
    // number that looks exactly like a valid link in the chain — and following it would
    // subtract an amount nobody ever spent, handing one agent someone else's spending.
    // Filtered here rather than only in the query, so the guarantee does not depend on a
    // caller getting the `where` clause right.
    if (s.executed === false) continue;
    const key = String(s.spentAfter);
    const prev = byTotal.get(key);
    if (!prev || Number(s.timestamp ?? 0) > Number(prev.timestamp ?? 0)) byTotal.set(key, s);
  }

  const tally = new Map();
  let expected = budget?.spent != null ? BigInt(budget.spent) : 0n;
  // Bounded by the page of spends fetched: a malformed log must not spin here.
  for (let guard = 0; expected > 0n && guard < (spends?.length ?? 0) + 1; guard++) {
    const s = byTotal.get(String(expected));
    if (!s) break; // the walk ran off the fetched page, or the log has a gap
    const amount = BigInt(s.amount);
    if (amount <= 0n) break; // would not terminate
    const who = lower(s.agent);
    tally.set(who, (tally.get(who) ?? 0n) + amount);
    expected -= amount;
  }

  for (const [who, amount] of tally) {
    const row = rows.get(who);
    if (row) row.spentThisPeriod = String(amount);
    // An agent that spent but is no longer in `agents` cannot happen (the entity is never
    // deleted), so there is deliberately no else-branch inventing a row.
  }

  // Bind order, so the list on screen does not reshuffle itself as agents spend.
  return [...rows.values()].sort((a, b) => a.boundAt - b.boundAt || a.address.localeCompare(b.address));
}

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
    if (!res.ok) {
      // 429 is reported distinctly because it is the one failure the agent can make worse.
      // Studio rate-limits per deployment, and a loop that keeps asking every TICK_MS while
      // being told to stop keeps the window from ever clearing. `retryAfterMs` tells the
      // caller how long to hold off; nothing else in this module knows about time.
      if (res.status === 429) {
        const header = Number(res.headers?.get?.("retry-after"));
        return {
          ok: false,
          rateLimited: true,
          retryAfterMs: Number.isFinite(header) && header > 0 ? header * 1000 : null,
          error: "subgraph is rate-limiting us (HTTP 429)",
        };
      }
      return { ok: false, error: `subgraph returned HTTP ${res.status}` };
    }
    body = await res.json();
  } catch (err) {
    // Never put cfg.url in an error: a subgraph url can carry an API key.
    // The exception path can leak the URL in err.message (Node's fetch does this for
    // malformed URLs). Real connection failures (DNS, host unreachable, ECONNREFUSED)
    // put the detail in err.cause.message instead, which carries only the hostname,
    // never a path or API key. Include both for proper diagnostics without leaking.
    const raw = String(err?.message ?? err);
    const cause = err?.cause?.message ? ` (${err.cause.message})` : "";
    const full = raw + cause;
    let safe = full;
    if (cfg.url) {
      safe = full.split(cfg.url).join("<redacted>");
      // Also redact the hostname part, since connection errors report only the hostname
      try {
        const u = new URL(cfg.url);
        safe = safe.split(u.hostname).join("<redacted>");
      } catch {
        // If URL parsing fails, the split-redaction above is still active
      }
    }
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
    payees[lower(p.payee)] = {
      allowed: p.allowed === true,
      // `allowed === false` has two causes and the frontend must not conflate them: a
      // payee taken off the list, and one that was never on it. Only the second can be
      // paid, and only under a policy that does not check the allow-list at all - which
      // is the entire point PolicySet exists to demonstrate.
      everAllowed: p.everAllowed === true,
      lastToken: p.lastToken ? lower(p.lastToken) : null,
    };
  }

  const chain = typeof cfg.chainBlock === "number" ? cfg.chainBlock : blockNumber;
  return {
    ok: true,
    block: { subgraph: blockNumber, chain, lag: Math.max(0, chain - blockNumber) },
    agent: {
      address: lower(cfg.agent),
      revoked: d.agent?.revoked === true,
      node: d.agent?.node ? lower(d.agent.node) : null,
    },
    subname: d.subname ? { label: d.subname.label, live: d.subname.live === true } : null,
    policy: d.policyPointer
      ? {
          address: lower(d.policyPointer.policy),
          approved: d.policyPointer.approved === true,
          // Matched here rather than in a second query. `approved` on the pointer is a
          // point-in-time snapshot from the event; `approved` on the list row is current,
          // and the two disagreeing is exactly the state a revocation produces.
          description:
            (d.approvedPolicies ?? []).find((a) => lower(a.id) === lower(d.policyPointer.policy))
              ?.description ?? null,
        }
      : null,
    // Every policy a human has ever approved, so the page can show what the wallet COULD be
    // pointed at and not only what it is pointed at. Swapping the pointer is one
    // transaction; a panel that shows a single address makes it look like a property of the
    // wallet rather than a choice someone made.
    approvedPolicies: (d.approvedPolicies ?? []).map((a) => ({
      address: lower(a.id),
      description: a.description ?? null,
      approved: a.approved === true,
    })),
    budget: d.agentBudget
      ? {
          token: lower(d.agentBudget.token),
          limit: String(d.agentBudget.limit),
          spent: String(d.agentBudget.spent),
          // Schema: "Pre-computed remaining budget... null" when limit is 0 (unlimited).
          // decide() still computes its own figure (the rollover case means the index's
          // answer can be stale-restrictive), but publishing the subgraph's own answer
          // alongside it is what the schema's mapping-side arithmetic was for - see
          // subgraph/schema.graphql:35.
          remaining: d.agentBudget.remaining != null ? String(d.agentBudget.remaining) : null,
          periodEnd: Number(d.agentBudget.periodEnd ?? 0),
        }
      : null,
    payees,
    // Every agent under this name, with the part of the shared budget each one spent this
    // period. Present whenever the read succeeded, so a page can show the sharing rather
    // than assert it.
    cohort: buildCohort(d.agents, d.spends, d.agentBudget),
    // What this wallet turned away, most recent first. There is no onchain equivalent:
    // a blocked spend is a status-1 receipt carrying an event and no state change, so
    // nothing can be read back. Capped at what a panel can show without becoming a log
    // viewer — the point is that refusals are visible at all, not that all of them are.
    refusals: (d.spends ?? [])
      .filter((s) => s.executed === false)
      .slice(0, 8)
      .map((s) => ({
        agent: lower(s.agent),
        payee: lower(s.payee),
        amount: String(s.amount),
        reason: Number(s.reason ?? 0),
        reasonName: s.reasonName ?? null,
        at: Number(s.timestamp ?? 0),
        tx: s.txHash ? lower(s.txHash) : null,
      })),
  };
}
