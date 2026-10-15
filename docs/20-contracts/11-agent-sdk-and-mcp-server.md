# 11 — Agent SDK and MCP server

**Status:** Draft
**Owner:** Founding team
**Last updated:** 2026-10-15

This document is the contract for the agent-facing client surface: the Python and TypeScript SDKs under `sdk/python/` and `sdk/typescript/`, and the MCP server under `sdk/mcp/`. An agent built on any framework gets Steward with a connection string and three calls (open a branch, explain, propose); the SDK is a thin ergonomic layer over code generated from the OpenAPI document in `contracts/` (doc 10), and the MCP server exposes the same operations as tools so an agent that speaks MCP needs no SDK at all. It formalises how rationale reaches evidence from the agent's side (resolving doc 04's two-channel question), how proxy SQLSTATEs and API error codes map to typed exceptions, how an agent waits for a verdict without blocking on humans, and what safety rules the MCP server enforces regardless of the model driving it. It does not define REST schemas (doc 10), policy semantics (doc 06), or lifecycle transitions (doc 13).

## 1. Goal and non-goals

- An agent **must** be able to use Steward with: `STEWARD_API_KEY` in the environment, one call to open a branch, ordinary SQL through the returned connection string, and one call to propose. Nothing in the agent's framework changes (doc 01 §3, §6: Steward favours no framework).
- The SDK **must not** depend on any agent framework. Framework integrations (LangGraph nodes, tool wrappers) are examples in `sdk/examples/`, never dependencies.
- The SDK **must not** touch row data except through the agent's own proxy connection. It never fetches a row delta; the row delta is served to reviewers under a grant (doc 03 §2), not to agents.
- Policy and impact-query management is not in the default agent surface (§7).

Layers, per language:

| Layer | Source | Stability |
|---|---|---|
| `steward.generated` / `@steward/sdk/generated` | Generated from `contracts/openapi/steward-v1.yaml` on every contract change; checked in (doc 03 §8) | Follows API v1; additive changes only |
| Hand-written ergonomic layer (`steward.branch`, `Changeset`, exceptions, retry, waiting) | `sdk/<lang>/src/steward/` | Semver-stable (§10) |
| MCP server | `sdk/mcp/` (TypeScript), depends on `@steward/sdk` | Tool schemas versioned with the SDK |

## 2. The core workflow

The API calls behind the workflow, at the level doc 13 names them: `POST /v1/branches` (doc 13 §6.1), `POST /v1/branches/{branch_id}/propose` (§6.3), `POST /v1/branches/{branch_id}/abandon` (§6.7), `POST /v1/branches/{branch_id}/withdraw` (§2.1), `GET /v1/changesets/{changeset_id}`, `POST /v1/merges/{merge_id}/revert` (§6.6), `GET /v1/merges/{merge_id}`. Every mutating call carries a caller-chosen idempotency key (doc 13 §8); the SDK generates one UUID per logical call and reuses it across its own retries.

### 2.1 Python

```python
import steward

client = steward.Client()  # STEWARD_API_KEY, STEWARD_API_URL from env

with client.branch(target="prod-postgres", task="reprice-q4") as branch:
    branch.explain("Q4 clearance: SKUs in 'outdoor' with stock > 90 days get -15%")
    with branch.connect() as conn:            # psycopg connection through the proxy
        conn.execute("UPDATE prices SET price = price * 0.85 WHERE sku = ANY(%s)", (skus,))
    branch.explain("Clearance repricing for 214 outdoor SKUs; margin stays above cost.")
changeset = branch.changeset                  # set by the exit-time propose
print(changeset.verdict, changeset.summary.tables)
```

```python
class Client:
    def __init__(self, api_key: str | None = None, api_url: str | None = None,
                 task_id: str | None = None, timeout: float = 30.0) -> None: ...
    def branch(self, target: str, task: str | None = None, *,
               on_exit: Literal["propose", "abandon", "keep"] = "propose",
               on_error: Literal["abandon", "propose", "keep"] = "abandon",
               ttl: timedelta | None = None, task_id: str | None = None) -> Branch: ...
    def get_branch(self, branch_id: str) -> Branch: ...
    def get_changeset(self, changeset_id: str) -> Changeset: ...
    def revert(self, merge_id: str, *, task: str | None = None) -> Branch: ...
    def merge(self, merge_id: str) -> Merge: ...
    admin: Admin   # §7; raises Forbidden unless the key holds the capability

class Branch:
    id: str; target: str; state: BranchState; connection_string: str
    def connect(self, **driver_kwargs) -> psycopg.Connection: ...   # extra "psycopg"
    def engine(self, **kwargs) -> sqlalchemy.Engine: ...           # extra "sqlalchemy"
    def explain(self, rationale: str) -> None: ...
    def propose(self, rationale: str | None = None) -> Changeset: ...
    def abandon(self, reason: str | None = None) -> None: ...
    def withdraw(self) -> None: ...   # proposed → open (doc 13 §2.1)
    changeset: Changeset | None

class Changeset:
    id: str; branch_id: str; status: Literal["computing", "evaluated", "superseded"]
    verdict: Literal["auto-merge", "hold", "block"] | None
    reason: Literal["policies", "policy_error", "no_policy_coverage", "revert_conflict"] | None
    summary: Summary            # doc 05 §5.2 summary layer: tables, columns, truncated, conflicts_count, reversible
    impact: dict[str, Metric]   # name → {value: float | None, error: str | None}
    fired_assertions: list[AssertionResult]   # status, count, denominator, sample_ref, error_code
    review: Review | None       # decision, allow_retry, note, when a human has decided
    merge: Merge | None
    def wait(self, timeout: float = 300.0, *, until_decided: bool = False) -> "Changeset": ...
    def refresh(self) -> "Changeset": ...
```

`BranchState` is exactly doc 02 §4: `open`, `proposed`, `merging`, `merged`, `rejected`, `abandoned`, `closed`.

### 2.2 TypeScript

```typescript
import { Steward } from "@steward/sdk";
const steward = new Steward();   // STEWARD_API_KEY, STEWARD_API_URL

const changeset = await steward.branch({ target: "prod-postgres", task: "reprice-q4" },
  async (branch) => {
    await branch.explain("Q4 clearance for outdoor SKUs, -15%");
    const pool = new Pool(branch.poolConfig());      // optional peer dep "pg"
    await pool.query("UPDATE prices SET price = price * 0.85 WHERE sku = ANY($1)", [skus]);
    await pool.end();
  });
// branch() resolves to the Changeset produced by the exit-time propose

await using branch = await steward.openBranch({ target: "prod-postgres" }); // explicit-resource form
```

```typescript
interface BranchOptions { target: string; task?: string; ttlSeconds?: number; taskId?: string;
  onExit?: "propose" | "abandon" | "keep"; onError?: "abandon" | "propose" | "keep"; }
interface Branch extends AsyncDisposable {
  readonly id: string; readonly target: string; readonly state: BranchState;
  readonly connectionString: string;
  poolConfig(): PoolConfig;                         // host, port, database = branch id, user, password, ssl
  explain(rationale: string): Promise<void>;
  propose(rationale?: string): Promise<Changeset>;
  abandon(reason?: string): Promise<void>;
  withdraw(): Promise<void>;
}
interface Changeset { id: string; verdict: "auto-merge" | "hold" | "block" | null; reason: VerdictReason | null;
  summary: Summary; impact: Record<string, Metric>; firedAssertions: AssertionResult[];
  review: Review | null; merge: Merge | null;
  wait(opts?: { timeoutMs?: number; untilDecided?: boolean }): Promise<Changeset>; }
```

### 2.3 Exit semantics

| Exit | Default | Why |
|---|---|---|
| Clean exit, writes made | `propose` | The three-call promise: the agent should not need a fourth call |
| Clean exit, no writes | `abandon` | An empty changeset costs a reviewer a look under `no_policy_coverage` (doc 06 §5.1) and meters nothing useful |
| Exception | `abandon` | See below |
| Interpreter / process death | nothing; TTL (doc 13 §6.7) abandons | The overlay is kept for retention so the task can be inspected |

**Decision: abandon on exception by default, with `on_error="propose"` as an opt-in.** An exception mid-task means the overlay is a prefix of what the agent intended; proposing it would either auto-merge a partial change (the incident doc 01 §10 names) or spend a reviewer on unfinished work. Abandoning keeps the overlay for the retention window (doc 13 §2), so nothing is lost for debugging; the abandon call carries the exception type as `reason`, never its message. `on_error="propose"` is for agents that checkpoint their own progress and want a human to decide; `"keep"` leaves the branch `open` for a later `get_branch` (interactive and notebook use).

A write that raises `BranchFrozen` because a second client proposed the same branch (doc 13 §6.2 failure 6) is an exception and abandons by default; `on_error="keep"` is the option for multi-process agents.

## 3. Rationale and evidence

There are two rationale channels and they are both evidence (doc 02: evidence is for humans, never for policy). This section fixes what each one is.

| Channel | Carrier | Scope | Where it lands | Crosses the plane boundary? |
|---|---|---|---|---|
| Per-statement rationale | `SET steward.rationale = '<text>'` on the proxy connection (doc 04 §5.5) | Every subsequent statement on that connection until reset | Data-plane evidence log, stamped on each statement record | No |
| Changeset rationale | `rationale` field of `POST /v1/branches/{id}/propose` (doc 13 §6.3) | The whole changeset | Control-plane metadata, shown at the top of the review | Yes (bounded text, doc 03 §2) |

`branch.explain(text)` **must** do both, in this order:

1. If the branch has at least one open proxy connection created by the SDK (`connect()`, `engine()`, or a pool built from `poolConfig()` with the SDK's connect hook), issue `SET steward.rationale = $1` on each. Text is truncated to 4,000 bytes with a `…` marker (doc 04 §5.5: under 4 KB). Connections the agent built itself from `connection_string` are not visible to the SDK; the agent **may** issue the `SET` itself.
2. Append the text to the branch's staged rationale list in SDK memory.

At propose, the SDK sends the staged list joined by blank lines as the changeset rationale, unless `propose(rationale=...)` supplies one, which replaces it. The SDK's `Changeset` exposes `rationale` (changeset-level) and the reviewer sees per-statement rationale on the evidence timeline (doc 07 §5.6); the SDK does not read evidence back.

**Decision.** The per-statement channel annotates writes ("why this `UPDATE`"); the propose-time channel summarises the changeset ("what this task did and why"). Both are evidence; neither reaches policy. This resolves the question doc 04 §2 defers to this document. Doc 15 owns the scrubbing rules for what crosses; this document only sets the size cap and the "never log the text" rule, which the SDK follows (rationale never appears in SDK logs or exception messages).

Statement evidence (fingerprints, tables, row counts) is captured by the proxy with no SDK involvement.

## 4. Error mapping

All SDK exceptions derive from `StewardError` with fields `code: str`, `retryable: bool`, `branch_id?`, `request_id?`. Messages never include SQL text, parameters, rationale, or row values.

### 4.1 Proxy SQLSTATEs (doc 04)

The SDK wraps the driver's error when its SQLSTATE is in the `SD` class (doc 04 §12 proposes the class; doc 10 records the table). Drivers surface the SQLSTATE differently (`psycopg.Error.sqlstate`, `pg` `DatabaseError.code`); the hand-written layer normalises.

| SQLSTATE | Proxy name | Exception (New: class names) | Retryable |
|---|---|---|---|
| `SD001` | `branch_frozen` | `BranchFrozen` | No; branch is `proposed` or later |
| `SD002` | `branch_not_routable` | `BranchNotRoutable` | Yes; the SDK retries connect for up to 60 s with 1 s → 5 s backoff (doc 13 §6.1 failure 6) |
| `SD003` | `branch_merged` | `BranchTerminal` with `state = merged` (from the code, not the message) | No |
| `SD00A` | `branch_rejected` | `BranchTerminal` with `state = rejected` | No |
| `SD00B` | `branch_abandoned` | `BranchTerminal` with `state = abandoned` | No |
| `SD00C` | `branch_closed` | `BranchTerminal` with `state = closed` | No |
| `SD004` | `base_snapshot_gone` | `BaseSnapshotGone` | No; the agent creates a new branch (doc 13 §6.2 failure 3) |
| `SD005` | `unsupported_statement` | `UnsupportedStatement` with `reason` from the message | No |
| `SD006` | `unclassifiable` | `UnclassifiableStatement` | No |
| `SD007` | `proxy_unavailable` | `ProxyUnavailable` | Yes; statement-level retry is the agent's; the SDK retries connect |
| `SD008` | `transaction_too_large` | `TransactionTooLarge` | No; transaction is aborted until `ROLLBACK` |
| `SD009` | `statement_too_large` | `StatementTooLarge` | No; add a predicate |
| `28P01` | invalid_password | `AuthenticationFailed` | No |
| `23505` | unique_violation | passed through unchanged: it is the target's semantics, not Steward's |
| `53300` | too_many_connections | `ProxyUnavailable` | Yes |

### 4.2 API error codes

| API code (doc 13 / doc 07) | Exception | Retryable |
|---|---|---|
| `branch_not_routable` (first query after create) | `BranchNotRoutable` | Yes, as above |
| `idempotency_conflict` | `IdempotencyConflict` | No |
| `changeset_superseded` | `ChangesetSuperseded` | No; refresh and re-read |
| `already_reviewed` | `AlreadyReviewed` | No |
| `merge_in_progress` (abandon of `merging`) | `MergeInProgress` | No |
| `verdict_block`, `self_approval` | `ReviewRefused` | No (admin namespace only) |
| `stale_transition` | `StaleTransition` | Yes, once, after `refresh()` |
| `compute_failed`, `data_plane_unreachable` | `DataPlaneUnavailable` | Propose: yes with the same idempotency key, 3 attempts |
| `forbidden` | `Forbidden` | No |
| HTTP 401 | `AuthenticationFailed` | No |
| HTTP 429, 503 | `Unavailable` with `retry_after` | Yes |
| HTTP 5xx, timeout before response | `Unavailable` | Yes with the same idempotency key (doc 13 §6.1 "retry with fresh IDs" is the control plane's job; the SDK reuses its key) |

Retry policy for API calls: exponential backoff 0.5 s × 2ⁿ with full jitter, cap 10 s, 5 attempts, only for `retryable` errors, and always with the original idempotency key. Non-idempotent reads (`GET`) retry the same way without a key.

## 5. Waiting for verdicts

`POST /v1/branches/{id}/propose` is asynchronous and always answers `202 {changeset_id, state: "computing"}` (doc 10 §4, doc 13 §6.3); `propose()` then polls `GET /v1/changesets/{id}` with backoff 1 s → 2 s → 5 s → 10 s (cap) until `evaluated` or `timeout`, which raises `ChangesetTimeout` and leaves the branch `proposed`.

`wait()` semantics, by verdict at the time of the call:

| Verdict | `wait()` default | `wait(until_decided=True, timeout=T)` |
|---|---|---|
| `auto-merge` | Polls until `merge.status` is `applied` or `failed`, or the branch returns to `proposed` (`stale_base`, doc 13 §6.5); returns the refreshed changeset | Same |
| `hold` | **Returns immediately** with `verdict == "hold"` | Polls until a review decision, abandon, TTL, or supersession, up to `T`; raises `ChangesetTimeout` after `T` |
| `block` | Returns immediately | Returns immediately |

**Decision: an agent must not block on humans by default.** A reviewer may take hours (doc 13 §12 contemplates days); an agent loop that blocks holds a process, a framework thread, and often an LLM context open for nothing. The default returns `hold` and the agent ends its task, records `changeset.id`, and lets a later run or a webhook pick up the outcome. `until_decided=True` with a deadline is the opt-in for long-lived agents. Polling for `until_decided` uses 5 s → 60 s backoff (cap) so a day-long wait costs ~1,500 requests, not 86,000.

After `stale_base`, `wait()` returns a changeset with `summary.conflicts_count > 0` and `verdict` at least `hold` (doc 13 §6.5); after reject-with-retry the branch is `open` again and `changeset.review.allow_retry` is `true` with `review.note` populated, which is how the reviewer note reaches the agent (doc 13 §5).

**Webhook helper.** For long-lived agents, `client.webhooks.verify(headers, body) -> Event` validates the signature on events doc 10 defines for `changeset.evaluated`, `review.decided`, `merge.applied`, `branch.abandoned`, and returns a typed event with the changeset id; the agent then calls `get_changeset`. The SDK never runs a server.

## 6. Reverts and merges

```python
branch = client.revert(merge_id, task="undo-reprice-q4")   # POST /v1/merges/{id}/revert
changeset = branch.changeset        # already proposed (doc 13 §6.6 step 6)
changeset.wait()                    # hold at least if conflicts; else per policy
merge = client.merge(merge_id); merge.status   # pending | applied | compensated | failed
```

`revert()` returns a `Branch` already in `proposed` with `revert_of == merge_id`; `explain()` on it before `wait()` is allowed only for the changeset rationale channel (there is no proxy connection to a revert branch). Revert requires `target_admin` (doc 07 §8), so by default it is in `admin` (§7) and the top-level `client.revert` is a convenience that raises `Forbidden` for an agent key. `Merge` exposes `id`, `changeset_id`, `status`, `applied_rows`, `total_rows` (from `merge_progress`), `compensation: "complete" | "partial" | "consumed" | "expired" | "corrupt" | None` (doc 09 §4 index status), and `revertable: bool`.

## 7. Admin namespace

Agents **must not** hold the `policy:write` scope or the `policy_admin` capability in M0 (doc 06 §8). The SDK therefore keeps everything that needs a capability beyond "branch on this target" out of the default surface and under `client.admin`, which is identical code with a different key: policy CRUD, `activate`, `retire`, `run_tests`, impact-query registration, target settings (`branch_ttl`, `uncovered_changeset_verdict`), review decisions, revert. The namespace exists for CI and automation (§12.3) and the key used **should** be a service principal, not an agent's. The MCP server does not expose any admin operation (§8).

## 8. The MCP server

`steward-mcp` is a Model Context Protocol server exposing the §2 workflow as tools. **Decision: implemented in TypeScript**, published to npm, with a PyPI `steward-mcp` package that is a launcher requiring Node ≥ 20 (open in §14). Reasons: the MCP reference implementation and streamable HTTP transport are TypeScript-first; every major MCP host launches stdio servers through `npx`; and one implementation means one conformance suite. It depends on `@steward/sdk` so error mapping and retry are not duplicated.

Transport: `stdio` (default) and streamable HTTP (`--http :8765`). Auth: `STEWARD_API_KEY` in the server's environment; over HTTP the server additionally requires a bearer token equal to that key, so a model never sees the key. `STEWARD_TASK_ID` seeds the task id (§9).

### 8.1 Tools

All inputs and outputs are JSON Schema in `sdk/mcp/schema/`; the shapes below name the fields.

| Tool | Input | Output | Notes |
|---|---|---|---|
| `steward_open_branch` | `{target, task?}` | `{branch_id, target, state, base_snapshot_fidelity}` | Refuses with `one_branch_per_session` if a branch is open (New: MCP-level code) |
| `steward_run_sql` | `{sql, params?: [...], max_rows?: int ≤ 1000}` | `{columns, rows, row_count, truncated, command_tag}` | The only tool that touches data; executes on the open branch through the proxy |
| `steward_explain` | `{rationale}` | `{accepted: true}` | Both channels (§3) |
| `steward_propose` | `{rationale?}` | `{changeset_id, verdict, reason, summary, impact, fired_assertions}` | Freezes writes |
| `steward_get_changeset` | `{changeset_id}` | Same as propose plus `review`, `merge` | |
| `steward_wait_verdict` | `{changeset_id, until_decided?: bool, timeout_s?: int ≤ 600}` | Same as get | Caps at 600 s so the host's tool timeout is not exceeded; default returns on `hold` |
| `steward_abandon` | `{reason?}` | `{state: "abandoned"}` | Closes the session's branch |
| `steward_revert` | `{merge_id, task?}` | `{branch_id, changeset_id, verdict, ...}` | Needs `target_admin`; otherwise returns `forbidden` as a tool error |

Tool errors are returned as MCP tool results with `isError: true` and `{code, retryable, message}` using the §4 codes, never as protocol errors, so the model can read and react.

### 8.2 Resources and prompts

| URI | Content |
|---|---|
| `steward://targets` | Targets the key may branch on: id, kind, fidelity, `branch_ttl` |
| `steward://branches/{id}` | Branch metadata: state, target, opened_at, changeset ids |
| `steward://changesets/{id}` | Summary, impact, verdict, reasons, fired assertions, review, merge progress. **Never** the row delta, sample keys, or conflicts values (doc 13 invariant 9; doc 05 §5.4) |

Prompt `steward_safe_operations`: a system-prompt snippet that explains that writes land on a branch, that reads see the base snapshot plus the branch's own writes, that DDL, `COPY`, sequences and tables without primary keys are refused (doc 04 §5.2), that the model should call `steward_explain` before writes and `steward_propose` once, and that `hold` means "a human will decide; stop and report the changeset id."

### 8.3 Safety rules enforced by the server

These hold whatever the model does and **must not** be configurable by a tool input:

1. One open branch per MCP session by default (`--max-branches` for hosts that multiplex).
2. `steward_run_sql` sends the statement to the proxy unchanged; the proxy's classifier (doc 04 §5.2) is the authority and `SD005`/`SD006` are surfaced as tool errors. The server adds a pre-check that rejects statements whose first keyword is DDL (`CREATE`, `ALTER`, `DROP`, `TRUNCATE`, `GRANT`, `REVOKE`) with `ddl_not_allowed` (New) to save a round trip; it is not the safety boundary.
3. Row cap 1,000 rows and size cap 256 KiB per result; beyond either, `truncated: true` and the server appends `LIMIT` advice. The cap bounds model context, not data access.
4. No multi-statement strings (doc 04 rejects mixed ones; the server rejects all so a model cannot smuggle a write into a "read").
5. Results and rationale are never logged by the server; logs carry branch id, statement class, row count, duration.
6. No admin operations, no policy tools, no grant minting.

## 9. Observability from the agent side

Every API request from the SDK carries `User-Agent: steward-sdk-python/1.2.0` (or `-typescript`, `steward-mcp`) and `task_id` (New: a caller-chosen string ≤ 128 bytes, defaulting to a UUID per `Client`). The principal is implied by the API key and is never set by the client. The control plane stores `task_id` on the branch; it appears in evidence metadata and the queue so a reviewer can group changesets from one agent run. The SDK also sets `application_name = steward-sdk:<task_id>` on proxy connections it opens. OpenTelemetry spans are emitted when an OTel SDK is installed, carrying the API's `request_id` and no row data.

## 10. Versioning

- SDK major version = API major version (`1.x` ↔ `/v1`). Generated code is regenerated on every change to `contracts/openapi/steward-v1.yaml` and checked in; a regeneration that removes or renames a field is a contract change and requires asking (doc 18 §5).
- The hand-written layer is semver: additive = minor; removal or default change (for example the §2.3 exit defaults) = major, preceded by a deprecation warning for one minor.
- The MCP tool names and schemas are versioned with the SDK; a tool input field is never removed within a major.
- The SDK sends `Steward-Api-Version: 2026-10-15` (doc 10 defines the header) and refuses to start against a server whose reported version is a different major.

## 11. Packaging

| Package | Registry | Runtime | Required deps | Extras / optional peers |
|---|---|---|---|---|
| `steward-sdk` | PyPI | Python ≥ 3.10 | `httpx` | `psycopg` (`steward-sdk[psycopg]`), `sqlalchemy` (`[sqlalchemy]`), `opentelemetry-api` (`[otel]`) |
| `@steward/sdk` | npm | Node ≥ 20 (global `fetch`) | none | `pg` peer for `poolConfig()` typing |
| `steward-mcp` | npm | Node ≥ 20 | `@steward/sdk`, `@modelcontextprotocol/sdk` | — |
| `steward-mcp` | PyPI | Python ≥ 3.10 + Node ≥ 20 | — | Launcher only; execs the npm package |

Both SDKs ship sync and async clients (Python: `Client` / `AsyncClient`; TypeScript is async only). The connection string the SDK hands to drivers is exactly the one the API returns (doc 04 §3.1): `postgresql://<principal_id>:<api_key>@<proxy-host>:5432/<branch_id>?sslmode=require`; the SDK never rewrites it except to add `application_name`.

## 12. Examples

### 12.1 LangGraph-style agent, Python

```python
from langgraph.graph import StateGraph
import steward

client = steward.Client(task_id="reprice-q4-2026-10-15")

def reprice(state):
    with client.branch(target="prod-postgres", task="reprice-q4") as branch:
        branch.explain("Plan: find outdoor SKUs with stock older than 90 days; cut 15%.")
        with branch.connect() as conn:
            skus = [r[0] for r in conn.execute(
                "SELECT sku FROM inventory WHERE category = 'outdoor' AND received_at < now() - interval '90 days'")]
            branch.explain(f"{len(skus)} SKUs qualify; applying -15% while price stays above cost.")
            conn.execute("UPDATE prices SET price = round(price * 0.85, 2) WHERE sku = ANY(%s) AND price * 0.85 > cost", (skus,))
    cs = branch.changeset                       # proposed on exit
    cs = cs.wait()                               # returns immediately on hold
    return {**state, "changeset_id": cs.id, "verdict": cs.verdict,
            "fired": [a.assertion_id for a in cs.fired_assertions]}

graph = StateGraph(dict); graph.add_node("reprice", reprice); graph.set_entry_point("reprice")
```

The node ends on `hold` with the changeset id in state; a scheduled follow-up node calls `client.get_changeset(id)` and, on `review.allow_retry`, reopens with `client.get_branch(cs.branch_id)`.

### 12.2 The same task through MCP

Host configuration (stdio):

```json
{ "mcpServers": { "steward": { "command": "npx", "args": ["-y", "steward-mcp"],
  "env": { "STEWARD_API_KEY": "stw_...", "STEWARD_TASK_ID": "reprice-q4" } } } }
```

Tool sequence the model produces: `steward_open_branch{target:"prod-postgres"}` → `steward_explain{"Plan: ..."}` → `steward_run_sql{sql:"SELECT sku FROM inventory WHERE ..."}` (≤ 1,000 rows) → `steward_run_sql{sql:"UPDATE prices SET ... WHERE sku = ANY($1) AND price*0.85 > cost", params:[[...]]}` → `steward_explain{"214 SKUs ..."}` → `steward_propose{}` → on `verdict: "hold"` the model reports the changeset id and stops, as the `steward_safe_operations` prompt instructs.

### 12.3 CI script reverting a merge, TypeScript

```typescript
import { Steward } from "@steward/sdk";
const steward = new Steward({ apiKey: process.env.STEWARD_ADMIN_KEY, taskId: `ci-revert-${process.env.GITHUB_RUN_ID}` });
const branch = await steward.admin.revert(process.argv[2], { task: "ci-revert" });
const cs = await branch.changeset!.wait({ untilDecided: true, timeoutMs: 15 * 60_000 });
if (cs.verdict === "hold") { console.log(`held: ${cs.id}; conflicts=${cs.summary.conflictsCount}`); process.exit(2); }
if (cs.verdict === "block") { console.error(`blocked: ${cs.firedAssertions.map(a => a.assertionId)}`); process.exit(1); }
console.log(`reverted; merge ${cs.merge!.id} ${cs.merge!.status}`);
```

## 13. Testing

- **Contract tests against a recorded API.** `sdk/python/tests/cassettes/` and `sdk/typescript/tests/cassettes/` hold VCR-style recordings produced against the local stack for every endpoint the SDK calls, including each error code in §4.2. Recordings are regenerated by `tools/sdk-record` whenever `contracts/openapi/` changes; CI fails if a cassette's request shape no longer validates against the OpenAPI document.
- **Proxy error mapping.** A fixture proxy stub in `sdk/testing/` returns each `SD` SQLSTATE and asserts the exception class, `retryable`, and that no message contains the sentinel literal in the statement.
- **Local stack.** `tools/stack up` (doc 18 §8); `sdk/<lang>/tests/integration` runs §12.1 end to end: open, write, explain, propose, `hold` under the default `no_policy_coverage`, then an admin approve and `wait()` to `applied`, then §12.3's revert. Exit semantics are tested by raising inside the context and asserting `abandoned` with the exception type as reason.
- **MCP conformance.** `sdk/mcp/tests` runs the MCP inspector's conformance suite over stdio and HTTP, then the safety rules: a second `steward_open_branch` is refused, `CREATE TABLE` is refused before the proxy is called, a 5,000-row `SELECT` returns 1,000 rows with `truncated: true`, a multi-statement string is refused, and server logs captured during the run contain no result values.
- **Driver matrix** is doc 04 §10's job; the SDK tests only the drivers it wraps (psycopg, SQLAlchemy, `pg`).

## 14. Alternatives considered

- **One SDK per framework (LangChain tool, CrewAI tool, OpenAI function).** Rejected: doc 01 §6 says favouring a framework shrinks the market; the MCP server covers tool-using models and the generic SDK covers code, and framework adapters are 20-line examples.
- **Fully hand-written SDKs.** Rejected: the API surface will move during M0 and generated code keeps the SDK honest against `contracts/`; the ergonomic layer is where stability lives.
- **Rationale only through the proxy (`SET`) or only through the API.** Rejected: the `SET` never crosses the plane boundary, so the review summary would have no rationale; the API alone cannot annotate individual writes. Both, with a stated split (§3).
- **Blocking `wait()` on `hold` by default.** Rejected (§5): it costs the agent a process for hours and encourages agents that poll humans.
- **MCP server in Python.** Rejected (§8): hosts launch via `npx`, the reference transport implementation is TypeScript, and one implementation is one conformance suite.
- **Separate `steward_read_sql` / `steward_write_sql` tools.** Deferred to open questions: the proxy's classifier is the authority either way, and a split only helps if the host can grant tools separately.

## 15. Open questions

| Question | Owner | Needed by |
|---|---|---|
| Auto-propose on clean exit (§2.3) versus requiring an explicit `propose()`: auto keeps the three-call promise; explicit avoids proposing after an agent that merely exited early without raising. Recommendation: auto, with `on_exit="keep"` documented prominently | Founding team | Before SDK 1.0 |
| Split `steward_run_sql` into `steward_read_sql` and `steward_write_sql` so a host can expose read-only tools to some models? Recommendation: ship one tool in M0, add a `read_only: true` server flag that makes writes fail before the proxy | Product, proxy lead | M0 MCP release |
| Reviewer note delivery: doc 13 §5 says it rides "the propose response that was rejected", but propose has returned before the review exists; this document delivers it via `GET /v1/changesets/{id}` `review.note` and webhooks. Confirm | Control plane lead | Doc 10 |
| Ship the PyPI `steward-mcp` launcher at all, given it requires Node? Alternative: document `npx steward-mcp` only | Founding team | M0 MCP release |
| `task_id`: field name and whether it is a branch attribute or evidence metadata in doc 12 | API lead | Doc 10, doc 12 |
| Webhook event names and signature scheme (§5) are assumed; doc 10 defines them | API lead | Doc 10 |
