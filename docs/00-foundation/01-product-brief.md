# 01 — Product brief

**Status:** Draft
**Owner:** Founding team
**Last updated:** 2026-10-15

Steward is a write-control plane for AI agents. It sits between agents and the production data they want to change, turns every write into a reviewable changeset, gates it with policy, and makes it reversible. The product is the review loop, not the storage. This document says who it is for, why it will be bought, what it deliberately leaves out, and how it makes money. Every other document in this repository is constrained by it.

## 1. The problem

Companies are deploying AI agents to do operational work: reprice products, reconcile ledgers, clean CRM records, triage tickets, adjust inventory. Every one of those jobs ends in a write to a production system. Pilots stall at exactly that point. The team that owns the data will let an agent read anything and write nothing, because:

- A bad write is invisible until something downstream breaks.
- There is no way to see what an agent is about to change before it changes it.
- There is no way to undo a batch of agent writes cleanly a week later.
- Role-based database permissions are the wrong granularity: an agent either can update the `prices` table or cannot, with nothing in between.

The result is agents that stop at "here is what I would do," and a human who copies the recommendation into the system by hand. The agent did the thinking and the human did the typing, which is backwards.

## 2. The customer

**Buyer:** the person blocking the agent rollout. Usually the owner of the data: head of RevOps, finance operations, data platform, or the DBA who inherited the ERP. They are not anti-agent; they are responsible for what happens when an agent is wrong.

**User:** that same person and their team, who become reviewers; and the engineers building agents, who get a connection string instead of a permissions argument.

**First customer profile:** a company with two or three agent pilots that have reached "it works on a copy" and stopped. Fifty to five thousand employees. Data in Postgres, Snowflake, or Salesforce. A RevOps or FinOps team that already does bulk edits through spreadsheets and dreads it.

What they say today: *"We can't let it write."*
What they say after: *"Agents write, we approve."*

## 3. The product

Steward is a control plane that owns the path from an agent's intent to a committed change. Five primitives:

| Primitive | What it is |
|-----------|------------|
| **Branch** | An isolated, cheap, short-lived overlay on a production dataset. Reads fall through to production; writes land in the overlay. One per agent task. |
| **Changeset** | The semantic diff of a branch: not "row 4312 changed" but "214 prices lowered, median −3%, two now below cost." |
| **Evidence** | What the agent looked at, queried, and reasoned before writing. Attached to every changeset so the reviewer sees *why*, not only *what*. |
| **Policy** | Assertions, written in SQL, that decide whether a changeset auto-merges, waits for a human, or is blocked. |
| **Compensation** | The inverse of every merge, recorded at merge time, so any change can be reverted later with one action. |

The user-facing surface is a queue, not a chat. Each item is one changeset with its one-line impact, a policy verdict, and approve / reject / edit. Policy auto-merges the boring majority; humans see only what is risky or new. Approved patterns become new policies, so the queue shrinks over time.

Agents do not change. They get a connection string that happens to point at a branch.

## 4. Why now

Three things converged in the last eighteen months:

1. Agents got good enough to do operational work, so the write problem is the bottleneck instead of a future concern.
2. Branchable storage became commodity: copy-on-write Postgres (Neon, Ardent, Xata), Iceberg branches and tags, DuckDB for cheap in-process diffs. The hard infrastructure exists; nobody has put a review loop on it.
3. Buyers have a mental model for this from Git. "Pull requests for data" needs no explanation to anyone who has reviewed code.

## 5. The wedge

Sell to the blocker. The pitch is **"say yes to agents without losing the ability to say no."** Land with a single stalled pilot on a single database. Expand as the customer adds agents, because every new agent is a new source of changesets and the meter grows with adoption.

Launch adapters, in order of pain: Postgres and MySQL (operational tooling), Snowflake and BigQuery (analytics teams, where latency does not matter), Salesforce and HubSpot (where most agents are actually being deployed).

## 6. What we deliberately do not build

- **A database.** Steward sits on the customer's storage. It never becomes the system of record.
- **An agent framework.** Steward is the thing every framework writes through. Favouring one would shrink the market.
- **A merge-conflict UI.** Branches are short and merge fast; conflicts are rare. Reject and retry is better than a three-way merge editor.
- **Cross-system transactions.** Each branch is scoped to one backend. Coordinating a write across Postgres and Salesforce is a problem for a later product.
- **Low-latency OLTP interposition.** Analytics and CRM first, where seconds are fine. Earn the right to sit in a transactional path.

## 7. Business model

Per-changeset pricing. Auto-merged changesets are free up to a generous tier; human-reviewed changesets are metered. The customer pays for human attention saved, and the bill grows exactly as agent adoption grows. No seat licences: reviewers are the people we want more of.

Deployment: control plane hosted by Steward; data plane deployed into the customer's cloud account so row data never leaves it. Only metadata crosses the boundary.

## 8. Moat

Two things compound:

- **Policies.** After a year a customer has hundreds of codified "what is a safe change here" rules, tuned to their data. Those are switching costs no competitor can import.
- **Evidence and audit trail.** The history of every agent write, with reasoning attached, is the compliance story and the training signal. It only exists if Steward was there from the first write.

## 9. Risks

| Risk | Mitigation |
|------|------------|
| Proxy latency unacceptable for transactional workloads | Ship analytics and CRM first; treat OLTP as a later milestone with its own latency budget |
| Branching substrates (Neon, Ardent) move up the stack and add review | Our value is policy, evidence, and the queue, not branching; partner with substrates rather than compete |
| Customers want the review loop but not the proxy (they already have a staging table) | Support "bring your own branch": accept a diff from any source and run the loop on it |
| Agents produce too many trivial changesets and the queue becomes noise | Policy auto-merge is the product, not a feature; measure queue size per customer as a health metric |

## 10. Success criteria for the first year

- Ten paying customers with at least one agent writing to production through Steward.
- Median customer auto-merges more than 80% of changesets within 90 days of onboarding.
- Zero incidents of an unreviewed changeset reaching production that policy should have held.
- At least one customer who reverted a merged changeset in production and said it saved them.

## 11. Open questions

| Question | Owner | Needed by |
|----------|-------|-----------|
| Pricing tier boundaries and whether policy-evaluation counts are metered | Founding team | Before first contract |
| Which of Neon, Ardent, or self-built branching is the Postgres substrate for M0 | Architecture | Doc 03 |
| Does "bring your own branch" belong in M1 or later | Founding team | Doc 19 |
