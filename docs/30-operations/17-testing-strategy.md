# 17 — Testing strategy

**Status:** Draft
**Owner:** Founding team
**Last updated:** 2026-10-15

This document is the one place that says how Steward is tested: the principles, the per-language pyramid, a table that binds every invariant in doc 13 §10 to the tests that enforce it, the component test plans consolidated from each spec's §10, the end-to-end scenarios run against the local stack, the plane-boundary test, load and chaos testing, what security testing runs in CI, the CI pipeline and its flakiness policy, the synthetic fixture generator, and what "tested" means for a milestone. It consolidates; where a spec already names a test, a number, or a path, it is cited and not re-derived. SLO numbers belong to doc 16, the security program to doc 15, and milestones to doc 19; this document says which tests prove them.

## 1. Principles

1. **Tests are the executable form of the invariants.** Doc 13 §10 lists 16 invariants and every spec carries "must" statements. Each invariant **must** map to at least one test in §3; a "must" with no test is a gap to be filed, not a convention to trust. CI enforces the mapping (§3, rule I-0).
2. **Every PR adds or changes tests** (doc 18 §7); "no tests needed" requires a one-line justification in the PR description.
3. **Synthetic data only.** Every fixture comes from `tools/fixtures` (§11); a copy of customer data, however anonymised, is never a fixture (doc 18 §7, §5). Fixture rows carry a sentinel so log-leak tests (doc 08 §10, doc 11 §13) can grep for them.
4. **The local stack is the integration substrate.** `tools/stack up` (doc 18 §8) is what integration and end-to-end tests run against; a component that does not run under it is not done.
5. **Fail-closed is tested as a property, not a case.** Where a component's safety depends on classification (proxy classifier, policy validator, boundary JSON), the test generates inputs and asserts that nothing unsafe passes, rather than enumerating known-bad inputs only. Known-bad corpora are regression suites on top.
6. **Determinism before parallelism.** Generators are seeded; a failing property test prints its seed and the seed reproduces the failure locally.

## 2. The test pyramid per language

| Layer | Rust (`proxy/`, `engine/`) | Elixir (`control/`) | Java (`adapters/`) | Python / TypeScript (`sdk/`) |
|---|---|---|---|---|
| Unit | `cargo test`, next to the code | ExUnit, SQL sandbox per test; Ash actions called through their domain with `actor:` and `tenant:`; introspection tests over `Ash.Policy.Info` and `AshStateMachine.Info` (doc 07 §10) | JUnit 5 | pytest / vitest |
| Property | `proptest` (seeded; `PROPTEST_CASES` 256 on PR, 10,000 nightly) | StreamData (100 runs on PR, 2,000 nightly) | jqwik (`tries = 100` on PR, 1,000 nightly) | Hypothesis / fast-check for the error-mapping layer only |
| Golden / snapshot | `insta` snapshots under `tests/golden/` (doc 05 §10); review with `cargo insta review` | Golden verdict files under `control/test/policies/` (doc 06 §10) | — | Recorded HTTP cassettes (doc 11 §13) |
| Fuzz | `cargo fuzz` targets in `engine/fuzz/` and `proxy/fuzz/` (doc 06 §10); 10 min per target nightly, corpus checked in | — | — | — |
| Integration | `<area>/tests/integration` against the local stack or MinIO + Postgres containers (doc 18 §7) | `control/test/integration` with the fake data plane (doc 07 §10) | Testcontainers (doc 08 §10) | `sdk/<lang>/tests/integration` against the local stack (doc 11 §13) |
| UI | — | LiveView tests (`Phoenix.LiveViewTest`) for every page in doc 07 §5.6; Wallaby for the two browser-only flows (row-delta grant fetch hook, SSO login) | — | MCP inspector conformance (doc 11 §13) |
| Bench | `criterion` under `benches/`, 5 % gate (doc 18 §3) | `Benchee` for `evaluate` (doc 06 §10) and heartbeat decide | JMH for `readRows` / `apply` throughput (doc 08 §7 requirements) | — |
| E2E | `tools/e2e` (§5), language-neutral: a Python driver script per scenario | | | |

Paths: doc 18 §7 names `<area>/tests/integration`; Elixir's `mix` convention is `control/test/`, which doc 18 §7 and doc 06 §5.5 use for policy tests while doc 06 §10 and doc 07 §10 say `control/tests/integration`. **Decision:** `control/test/` for ExUnit (mix convention) with `control/test/integration/` tagged `:integration`; `tests/` elsewhere. Flagged in §13.

## 3. Invariant tests

Rule **I-0 (CI):** `tools/ci/invariants.toml` lists every invariant below with its test identifiers; a CI step greps each identifier out of the test tree and fails the build if any is missing. Adding an invariant to doc 13 §10 without a row here fails the same step (the file carries the invariant count, 16).

| # | Invariant (doc 13 §10) | Test(s) | Layer | Owner |
|---|---|---|---|---|
| 1 | Control-plane Postgres is the only source of truth; data-plane state is a cache | `HeartbeatMatrixTest` (all 40 cells adopt the authoritative state); `routing_store_adopts_heartbeat_reply` (proxy); E2E 8 (control-plane restart) | unit, integration, e2e | Control plane, proxy |
| 2 | At most one non-superseded changeset per branch | `changesets_one_current_index_test` (doc 12 partial unique index); `BranchStateMachinePropertyTest` | unit (DB), property | Control plane |
| 3 | `proposed`/`merging` has exactly one non-superseded changeset | `BranchStateMachinePropertyTest` asserts after every step | property | Control plane |
| 4 | Exactly one verdict; re-evaluation creates a new changeset | `verdicts_changeset_id_unique_test`; `Policies.EvaluateIdempotencyTest`; `ReevaluateJobTest` (new changeset, old `superseded` with reason `reevaluated`) | unit | Policy engine |
| 5 | `applied` ⇒ persisted compensation keyed by merge ID | `merges_applied_requires_checkpoint_check_test` (doc 12 CHECK); `FakeDataPlane` script `applied_without_checkpoint` → report refused and `heartbeat.anomaly` emitted; engine `persist_failpoints` (doc 09 §10) | unit, integration | Control plane, compensation log |
| 6 | Persisted compensation is never rolled back to `proposed` | `BranchStateMachinePropertyTest` (`merging → proposed` only when `compensation_persisted = false`); `FakeDataPlane` script `crash_after_checkpoint` → branch stays `merging` | property, integration | Control plane |
| 7 | Adapter never applies without persisted compensation | `merge_worker_apply_requires_persist` (engine; failpoint before `Persist` step 7 and assert zero `Adapter.apply` calls on the adapter stub) | integration | Engine |
| 8 | Data plane never advances to `merged` itself | `HeartbeatMatrixTest` cells (`done`, `merging`) and (`merging`, `merging` with `complete`); engine has no `merged` state by construction (`BelievedState` enum test) | unit | Control plane, engine |
| 9 | No row data crosses to the control plane | Boundary test (§6); `RowDataRejectionTest` (doc 07 §10 stray `rows` key); sandbox escape tests; log sentinel tests in every component | unit, integration | All |
| 10 | No control-plane Postgres transaction open across a data-plane call | `mix xref graph --fail-above` (steward_core cannot reach the plane client, doc 07 §4); `PlaneClient.NotInTransactionTest` (client raises `CalledInsideTransaction` when `Repo.in_transaction?/0`) | static, unit | Control plane |
| 11 | At most one `pending` merge per target | `merges_one_pending_per_target_index_test` (doc 12); `TwoMergesOneTargetTest` (§4.4) | unit, integration | Control plane |
| 12 | A `block` verdict is never overridden by a review | `Reviews.DecideTest` approve on `block` → `verdict_block`; state-machine property forbids `proposed → merging` with verdict `block`; E2E 2b | unit, property, e2e | Control plane |
| 13 | No two overlays share `(branch_id, overlay_id)`; unknown pairs are dead | `routing_branch_unique_index_test` (doc 12 §8.6); `CreateRetryFreshIdsTest` (doc 13 §6.1 retry after intent row); heartbeat cell (`open`, `unknown`) → GC | unit, integration | Proxy, control plane |
| 14 | Compensation consumed by at most one merged revert; never GC'd while revertable | `reverts_partial_unique_test` (doc 12 §2.3); `open_vs_gc_race` ×1,000 (doc 09 §10); `gc_respects_retention_until` | unit, integration | Compensation log |
| 15 | Proxy answers every query from local state | `control_plane_stub_stopped` failure injection (doc 04 §10); `cargo tree -p steward-proxy` assertion that the proxy crate does not depend on the plane client crate; chaos C-2 (§8) | integration, static, chaos | Proxy |
| 16 | Every terminal transition carries a reason and a principal | `branches_terminal_reason_check_test` (doc 12 CHECK); state-machine property asserts the event payload `actor` and `reason` | unit, property | Control plane |

## 4. Component test plans

Each subsection consolidates the spec's §10 into named tests. Names are identifiers CI greps for (I-0).

### 4.1 Write proxy (doc 04 §10)

| Test | Kind | Cases |
|---|---|---|
| `driver_matrix::<driver>` | integration, `proxy/tests/integration/drivers/<driver>/` | Drivers: `psql`, psycopg3, asyncpg, SQLAlchemy sync, SQLAlchemy async, JDBC (pgjdbc), npgsql, node-postgres, Go `pgx`. Same script per driver: connect; simple query; extended query with parameters; transaction with `SAVEPOINT` and `ROLLBACK TO`; write on a frozen branch → `SD001`; `SD002` reconnect loop succeeds within 60 s; terminal-state codes `SD003`/`SD00A`/`SD00B`/`SD00C` on late connect |
| `classify_matches_ast` | proptest | Grammar-generated SQL with random comments, whitespace, casing, CTEs, multi-statement strings; property: class = class of the top-level AST node, and any data-modifying node anywhere ⇒ `write` |
| `classify_fails_closed` | proptest | Random byte mutations of valid statements; property: result ∈ {known class, `unclassifiable`}, never a panic, and a mutated `write` is never classified `read` (release blocker per doc 04 §8) |
| `classify_corpus` | regression | `tools/fixtures` synthetic agent SQL corpus; `insta` snapshot of class per statement |
| `read_your_writes` | proptest + integration | Random write sequence on a branch vs the same sequence on a scratch Postgres; every supported read equal; every unsupported form → `SD005`, never a wrong answer |
| `freeze_marker_atomicity` | integration | Concurrent writers while `FreezeWrites` lands: every write is either `seq ≤ freeze.last_seq` in the overlay or rejected `SD001`; no third case; WAL `FREEZE` record and `freeze.json` agree on `last_seq` |
| `unfreeze_excludes_span` | integration | `FREEZE`/`UNFREEZE` pair; ops between are excluded from `view()` and `ComputeChangeset` |
| `sd_code_mapping` | unit | Every `SD` code in doc 11 §4.1 is produced by exactly one path; message never contains a literal from the statement (sentinel grep) |
| `replay_harness` | `tools/loadgen replay` | Recorded synthetic sessions (statements + timings) → asserts overlay contents, evidence records, latency histograms; doubles as load (doc 03 principle 9) |
| `failure_injection::*` | integration | Kill adapter host mid-transaction (buffer kept, `SD007`); overlay volume read-only (`SD007`, nothing acknowledged); routing store corrupted (`SD007`, rebuilt from heartbeat within 60 s); control-plane stub stopped (no effect on queries) |
| `routing_store_durability` | integration | Restart proxy; routing rows survive; never purged wholesale |
| `evidence_gap_counted` | unit | Evidence append failure increments `evidence_gap`, write still acknowledged |
| Benches | criterion | connect, classify, pass-through read, single-row write, merged read (`view()` at 1k/100k net rows) |

### 4.2 Changeset engine (doc 05 §10)

| Test | Kind | Cases |
|---|---|---|
| `netop_fold_golden` | insta, `engine/tests/golden/` | Every row of the doc 05 §5.2 fold table; sequences of 3–5 ops per key; invalid sequences (`insert`→`insert`, `delete`→`delete`, `delete`→`update`) → `overlay_invalid` |
| `apply_then_compensate_is_identity` | proptest | Random overlay + random base; `apply(compensation(delta, base), apply(delta, base)) == base` on touched columns |
| `collapse_is_associative` | proptest | `collapse(a ++ b) == collapse(collapse(a) ++ b)` |
| `sql_contract_pinned` | golden | Fixture changeset; pinned results for every relation in doc 05 §5.2; the same fixtures feed `control/test/policies/` through the NIF |
| `sandbox_escape::<attempt>` | integration with syscall trace (`strace`/`seccomp` log in CI) | Attempts, each **must** be refused with no file or socket opened: filesystem (`read_parquet('/etc/passwd')`, `read_text`, `COPY ... TO`, `glob`), network (`read_parquet('https://…')`, `httpfs`), extension load (`INSTALL`, `LOAD`, community extensions), config (`SET memory_limit`, `PRAGMA`, `CREATE SECRET`, `ATTACH`), multi-statement input, non-`SELECT` top level, memory bomb (`SELECT range(1e9) ...` cross join → sandbox cap error, engine RSS unchanged), infinite query (cross join without predicate → interrupted within timeout + 1 s) |
| `wal_crash::<point>` | integration (failpoints) | Crash after record write before fsync (record absent, never acknowledged); crash mid-record (crc32c truncates prefix, doc 12 §8.2); crash after segment PUT before manifest update (WAL not truncated, `view()` still complete); crash after manifest before WAL truncate (idempotent re-roll) |
| `staleness::<case>` | integration vs local-stack Postgres | Concurrent edit to touched column → `stale_base`; to untouched column → ok; to key column → `stale_base`; insert key now exists → `stale_base`; delete row now missing → `stale_base`; `last_modified` path via CRM stub (`SystemModstamp > snapshot.ts` → conflict); canonical comparison cases (NaN=NaN, decimal by value, timestamp UTC) |
| `conflicts_relation_only_in_dp` | unit | `conflicts.t` rows persisted locally; report carries only `conflicts_count` + `conflicts_ref` |
| `freeze_marker_wait` | integration | Marker absent → poll, then `freeze_marker_missing` at 120 s |
| `compute_idempotent` | integration | Recompute same `(changeset_id, overlay_id)` → identical `row_delta_digest` |
| `compaction_racing_appends` | integration | Appends during `Compact`; no acknowledged op lost |
| `summary_cap_and_allowlist` | unit | 256 KiB truncation order; `distinct_values` absent unless allow-listed |
| Benches | criterion | `view()`; compute at 1k/100k/1M rows; `compensation.rs` at 1k/100k (doc 09 §10) |

### 4.3 Policy engine (doc 06 §10)

**Tests-as-data harness.** A policy test is a YAML file under `control/test/policies/<target>/<policy>/<test>.yaml` (doc 06 §5.5); the harness is tested by its own suite under `control/test/policies/_harness/`. Format:

```yaml
policy: prices-below-cost          # slug, must exist in the fixture policy set
name: one row below cost blocks
fixture:
  principal: agent:pricing-bot
  proposed_at: 2026-10-14T10:00:00Z
  tables:
    prices:
      key: [sku]
      columns: { sku: text, price: numeric, cost: numeric }
      before: [{ sku: A1, price: 10, cost: 8 }, { sku: A2, price: 12, cost: 9 }]
      after:  [{ sku: A1, price: 7,  cost: 8 }, { sku: A2, price: 12, cost: 9 }]
  impact: { "margin.total": 42.0 }        # optional; pre-populates impact.metrics
expect:
  outcome: block                           # auto-merge | hold | block (this policy alone)
  fired: [price-below-cost]
  counts: { price-below-cost: 1 }
  errors: {}                               # optional: assertion_id → error_code
```

`policy_tests.fixture` holds `rows` legitimately (synthetic); it is outside the boundary trigger's table list (doc 12 §2.4) and §6 names it as the one carve-out.

| Test | Kind | Cases |
|---|---|---|
| `_harness/*` | data | Every `expect` form (`zero_rows`, `max_rows`, `max_fraction`, `true`); inserts/updates/deletes; joins to `before.*`; the six worked examples of doc 06 §4.2 each with a passing and a failing fixture |
| `golden_verdicts` | golden | `tools/fixtures` changesets × reference policy set → pinned verdicts, diffed in CI |
| `ScopeMatchingPropertyTest` | StreamData | Principals, tables, columns, time windows across DST transitions |
| `VerdictCombinationTest` | unit | Full status matrix; precedence `block > hold > auto-merge`; `block` + `policy_error` → `block` with the error noted; `hold` + `policy_error` → `hold`, reason `policy_error`; no coverage → `hold`, reason `no_policy_coverage` (and `auto-merge` when the target setting is flipped); revert conflict floor applied by the coordinator, reason `revert_conflict` (doc 07 §5.2) |
| `ActivationPreconditionsTest` | unit | `no_tests`, `tests_failing`, `static_check_failed`, `not_draft`; capability `policy_admin` required; agents never `policy:write` |
| `validate_fuzz` | cargo fuzz (`engine/fuzz/validate.rs`) | Any input that passes `validate` but whose AST references a non-allowlisted relation or function, or that panics, fails the build; corpus: `COPY ... TO`, `read_csv`, `ATTACH`, nested-CTE smuggling, comment-hidden statements |
| `EvaluateIdempotencyTest`, `ReevaluateJobTest` | unit | Existing verdict returned; superseded changesets skipped |
| `evaluate_integration` | integration | Real engine via local stack; data plane killed mid-evaluation keeps `computing`; activation triggers re-evaluation and supersession; mirror digest check (`mix steward.policies.export`) |
| `EvaluateBench` | Benchee | 1,000 changesets × 200 active policies; control-plane p99 < 500 ms (doc 06 §7) |

### 4.4 Control plane (doc 07 §10)

| Test | Kind | Cases |
|---|---|---|
| `BranchStateMachinePropertyTest` | StreamData | Random trigger sequences (create, propose, withdraw, verdicts, reviews, merge outcomes, `stale_base`, `snapshot_lost`, abandon, TTL, retention); asserts every transition is a row of doc 13 §2.1 and no other transition ever occurs (the test carries the transition table literally; a doc change must change it); invariants 2, 3, 4, 6, 11, 12, 16 after every step; `lock_version` conflict never produces a partial write |
| `HeartbeatMatrixTest` | unit, generated | Generated by the `Steward.Lifecycle` Spark DSL from the same declaration that compiles `Heartbeat.decide/3` (doc 07 §5.0): all 40 cells (5 believed × 8 authoritative) of doc 13 §6.8, reply and actions, diffed against the committed expectation table in `control/test/support/heartbeat_matrix.exs`; `:alert` cells write `heartbeat.anomaly` and never auto-repair; a missing or duplicate cell is a compile error from the DSL verifier |
| `PolicyCoverageTest` | unit | Every Ash action has a policy: walks every resource of every domain with `Ash.Policy.Info.policies/1`, fails any action with zero policies and any resource without the authorizer; a table-driven companion transcribes doc 15 §3.2 (capability × operation → `:ok` or `Ash.Error.Forbidden`) so a matrix change must change the test |
| `ReactorStepTest` (×5) | unit, fake data plane | For `CreateBranch`, `Propose`, `Merge`, `Revert`, `Abandon`: inject a failure at each pre-checkpoint step and assert every earlier step's `undo` ran and the record is back at its starting state with the expected reason; inject a failure at each post-checkpoint step and assert nothing was undone, the checkpoint row is intact, and the next heartbeat or sweep repairs it (doc 07 §5.0 reactor rule) |
| `StateMachineDeclarationTest` | unit | `AshStateMachine.Info.transitions/1` on `Branch`, `Changeset`, `Merge`, `PolicyVersion` equals the doc 13 §2.1 / doc 06 §5.2 tables literally |
| `TwoReviewersTest` | concurrency | Parallel `Review.decide`; exactly one review row; loser gets `already_reviewed` |
| `TwoMergesOneTargetTest` | concurrency | Two `auto-merge` verdicts on one target; one lease; second waits with `merge_wait`; second's staleness check at merge time catches overlap (`stale_base`) |
| `LeaseNeverBypassedTest` | unit | Expired lease with `pending` merge is not re-acquired; `target.lease_expired` emitted |
| `BootSweep100kTest` | integration, nightly | 100k non-terminal rows → process count = rows; ready ≤ 15 s (doc 07 §7) |
| `HeartbeatStormTest` | integration, nightly | 100k heartbeats in 1 s → token bucket rejections with `retry_after_ms`, zero dropped transitions |
| `Steward.Schema.OrgIdTest` | unit | Every resource in every domain has `org_id` non-nullable with attribute multitenancy on it; allow-list exactly `orgs`, `oban_jobs`, `schema_migrations`; generated migrations with `references(` carry `with: [org_id: :org_id]` (doc 12 §10) |
| `CrossOrgQueryTest` | unit | Action or query without a tenant raises `Ash.Error.Invalid.TenantRequired`; a principal of org A cannot read, decide on, or grant org B's changeset (`not_found`, never `forbidden`) |
| `MigrationDriftTest` | CI | `mix ash.codegen --check` passes and the schema the migrations produce matches doc 12's DDL (doc 12 §0) |
| `AuditImmutabilityTest` | unit | `UPDATE`/`DELETE` on `events`, `audit_log`, `reviews`, `verdicts`, `verdict_assertions`, `review_features` as `steward_app` → permission error and trigger error (doc 12 §2.5) |
| `RowDataRejectionTest` | unit | Summary with stray `rows` key rejected by the embedded Ash resource and by `validate_boundary_json` |
| `FakeDataPlane` scripts | integration | Every failure row of doc 13 §6: slow, lost reply, `stale_base`, `SNAPSHOT_LOST`, crash before/after compensation checkpoint, `applied_without_checkpoint` |
| `CounterDrainTest`, `CounterRebuildTest` | unit | Drain is exact under concurrent inserts; rebuild equals drained totals |
| LiveView tests | UI | Queue page mount, PubSub `entry_added`/`entry_removed`, "already decided by" on race, grant minting only for `reviewer` |

### 4.5 Adapters (doc 08 §10)

Conformance suite `adapters/conformance/` (JUnit 5, parameterised over `ConnectorFixture`); every adapter **must** pass it in CI:

| Case | Asserts |
|---|---|
| `describeIsStable` | Same result across calls; primary key named for every governed table |
| `openSnapshotIdempotent` | Second open on (target, branch) returns an equal handle |
| `snapshotIsolation` | Writes after open invisible to `readRows` on `TRUE_SNAPSHOT`, visible to `currentRows`; `TIMESTAMP_BOUNDED` reports post-timestamp rows absent |
| `readRowsMissingKeys` | Present subset, no error; `> maxReadKeys` → `KEY_LIMIT_EXCEEDED` |
| `applyTwiceEqualsOnce` (jqwik) | `apply(M,d); apply(M,d)` same state and confirmed set; interrupted-then-resumed same state; `apply(M1,d); apply(M2,d)` is not a no-op where `d` has inserts |
| `applyHonoursTouched` | Update writes only `touched` ∪ key columns |
| `schemaDrift::<case>` | Every row of doc 08 §5.4: tolerated vs `SCHEMA_MISMATCH` before any write |
| `snapshotLost` | Fixture drops the snapshot → `SNAPSHOT_LOST` |
| `rateLimited` (Salesforce mock) | Quota below next batch → `RATE_LIMITED` with `retryAfter` |
| `noRowValuesInLogs` | Captured logs contain no sentinel |
| `credentialRotation` | `AUTH_FAILED` triggers re-resolve; one retry, no merge failure |

Fixtures per doc 08 §10: Testcontainers Postgres 16 + Neon-compatible pageserver (substrate) and plain Postgres (fallback); Iceberg REST catalog over MinIO; Snowflake nightly against a per-run schema; Salesforce via WireMock recordings on PR, scratch org nightly. `adapters/tests/integration` exercises the gRPC surface from a Rust client, including handle re-validation after host restart.

### 4.6 Compensation log (doc 09 §10)

| Test | Cases |
|---|---|
| `persist_failpoints::<step>` | Failpoints (`fail` crate) after each body segment PUT, after partial-keys PUT, after header PUT, after read-back verify, before and after index commit, mid-GC; after kill + restart: no checkpoint without a valid record; `Persist(M1)` retried converges to exactly one valid record; chain heads consistent; repair leaves no header without row and no row without header |
| `checksum_tamper` | Flip a byte in a segment and in a header: `Open` refuses, `Verify` marks `corrupt`, `VerifyChain` locates the break; `corrupt` is never GC'd |
| `open_vs_gc_race` | 1,000 iterations; exactly one winner each time |
| `gc_idempotent` | GC twice with a crash between; same end state; reservation taken between runs survives |
| `gc_rules` | Each of the five conditions of doc 09 §5.5 individually blocks GC; orphan (`merge_applied = 0`) expires after 7 days; headers retained |
| `chain_verification` | `VerifyChain` over N records; a forced `prev_hash` mismatch refuses `Persist` |
| `inverse_rules_conformance` | Module and doc 05 produce byte-identical bodies |
| `partial_record` | Fixture adapter withholds before-images for one column → `partial`, keys file present, `delta.reversible = 'partial'` in summary, `hold` floor on the revert verdict |
| `grant_tests` | Expired, wrong-scope, replayed grants refused; each accepted read yields one audit event |
| `apply_then_revert_e2e` | Property through the whole path (E2E 4) |

### 4.7 SDK and MCP server (doc 11 §13)

| Test | Cases |
|---|---|
| `cassettes/*` (Python `pytest-recording`, TypeScript `polly`-style) | Every endpoint and every error code in doc 11 §4.2; regenerated by `tools/sdk-record` on `contracts/openapi/` change; request shapes validated against the OpenAPI document |
| `proxy_error_mapping` | Stub proxy returns each `SD` code → exception class, `retryable`, no sentinel in message |
| `exit_semantics` | Clean exit with writes → `propose`; clean exit without writes → `abandon`; exception → `abandon` with the exception type as reason, never the message; `on_error="keep"` leaves `open`; `BranchFrozen` from a second proposer → abandon by default |
| `idempotency_reuse` | Retries reuse the original key; 5 attempts, full jitter, cap 10 s |
| `wait_semantics` | `hold` returns immediately; `until_decided` polls 5 s → 60 s; `stale_base` surfaces `conflicts_count > 0` |
| `mcp_conformance` | MCP inspector suite over stdio and HTTP; tool input/output JSON Schema in `sdk/mcp/schema/` validated against every tool result |
| `mcp_safety` | Second `steward_open_branch` → `one_branch_per_session`; `CREATE TABLE` → `ddl_not_allowed` before any proxy call; 5,000-row `SELECT` → 1,000 rows, `truncated: true`; 256 KiB size cap; multi-statement string refused; no tool input can change a cap; no admin tool exposed; logs contain no result values |

## 5. Integration and end-to-end

**Local stack** (`tools/stack up`, Docker Compose, doc 18 §8): metadata Postgres 16; target Postgres 16 on a Neon-compatible pageserver (profile `neon`, default) or a plain replica with paused replay (profile `fallback`); MinIO as the object store; `steward-proxy`, `steward-engine`, and the adapter host in one pod-equivalent network namespace; the control plane release (all four umbrella apps) with a fake OIDC provider; an optional Iceberg REST catalog (profile `iceberg`). `tools/stack` **must** also expose chaos hooks (`kill <service>`, `partition session`, `fill wal`, `gc-branch <overlay_id>`) used by §8, and `tools/stack reset` for a clean database between scenarios. Every scenario seeds from `tools/fixtures --seed <n>` and runs with a fresh org.

E2E scenarios (`tools/e2e/<nn>_<name>.py`), each run against both stack profiles on PR for 1–3 and nightly for all:

| # | Scenario | Expected final state |
|---|---|---|
| 1 | Doc 10 §7 A: agent branch, auto-merged | Branch `merged`, reason `merge_applied`; one changeset `evaluated`, verdict `auto-merge`; merge `applied`; compensation `complete`; target rows updated; `reviewed_changesets` counter unchanged |
| 2 | Doc 10 §7 B: held, approved | Verdict `hold`, reason `policies`; queue entry created then deleted; review `approved`; merge `applied`; grant fetched row delta directly from the data plane; `reviewed_changesets` +1 |
| 2b | Held, approve attempted on `block` | `verdict_block` refused; branch `rejected`, reason `verdict_block` |
| 2c | Reject with retry | Branch back to `open`, changeset `superseded` reason `reject_with_retry`, proxy unfrozen, `review.note` visible via `GET /v1/changesets/{id}` |
| 3 | Doc 10 §7 C: clean revert | Revert branch auto-proposed, `conflicts_count = 0`, verdict per policy; on merge: original merge `compensated`, record `consumed`, target equals pre-merge state |
| 4 | Revert with conflict | A later merge touched 3 keys; revert changeset `conflicts_count = 3`, verdict `hold`, reason `revert_conflict`; after approval, only the non-conflicting keys restored per the staleness rules; conflict values never present in control-plane rows |
| 5 | `stale_base` | Out-of-band edit after propose; merge `failed`, reason `stale_base`; branch `proposed`; new changeset with `conflicts_count > 0` and verdict at least `hold`; lease released |
| 6 | TTL expiry | `branch_ttl_s` = 60; branch `abandoned`, reason `ttl_expired`; proxy rejects writes with `SD00B` within one heartbeat; overlay kept until retention, then `closed` |
| 7 | Data-plane restart mid-merge | Kill `steward-engine` after the compensation checkpoint at 40 % apply; on restart apply resumes from `applied_rows`; merge `applied`; exactly one compensation record; branch `merged` |
| 7b | Data-plane restart before checkpoint | Kill before `Persist` step 7; merge `failed`, reason `compensation_failed` or `data_plane_unreachable`; branch `proposed`; stray segments GC'd as header-less prefix |
| 8 | Control-plane restart mid-propose | Kill the control plane between propose step 1 and step 9; after boot sweep the GenServer resumes compute with the same changeset id; verdict recorded once; agent's poll converges |
| 9 | `heartbeat_lost` | Partition the Session stream for 6 min on an `open` branch and a `merging` branch; both flagged `heartbeat_lost`; `merging` holds the lease and alerts; on reconnect flags clear, no transition lost; writes on the `open` branch never failed |
| 10 | Create-retry orphan | Drop the reply at doc 13 §6.1 step 5; retry with the same key yields fresh B2/O2; O1 heartbeats `unknown` and is GC'd |
| 11 | SDK §12.1 and §12.3 | Doc 11 §13's integration script end to end, Python and TypeScript |

Every scenario ends with `tools/e2e/assert_invariants` which runs the doc 12 drift checks (`merges.state = compensated ⇔ status = consumed`, counters vs rebuild, no process for a terminal branch).

## 6. The boundary test

`tools/boundary-test` runs on every PR that touches `contracts/`, `control/`, or `engine/` and nightly. It **must**:

1. Parse `contracts/proto/steward/plane/v1/session.proto` and assert, per message, that every field type is in the allow-list `{scalar, enum, timestamp, bounded string ≤ 1 KiB, bytes of fixed length 32 (digests), repeated of those ≤ 1,000}`; any `repeated` of a message that itself contains unbounded strings or `map` types fails. `ComputeChangeset.assertions[].sql` and `impact_queries[].sql` are the explicit exceptions (downward, customer-authored SQL, doc 06 §8) and are listed by name in the test.
2. For every JSON schema under `contracts/events/`, `contracts/openapi/` components, and doc 12 §5 (`changeset-summary/1`, `changeset-impact/1`, `event-envelope/1`), assert `additionalProperties: false` at every object level and no property named in the `validate_boundary_json` deny-list (`rows`, `row`, `sample_keys`, `before_image`, `after_image`, `values`, `key`, `keys`).
3. Generate, for each schema, a valid instance (seeded) and 50 mutants that insert a deny-listed key at a random depth or a string over the length cap; assert the embedded Ash resource rejects each mutant and that inserting it through the Repo (bypassing the action, in the test only) trips `validate_boundary_json()` on every table in doc 12 §2.4.
4. Replay every `DataPlaneMessage` from the §5 scenarios' recorded streams through a decoder and assert message size ≤ 1 MiB (4 MiB for `ComputeChangeset`), matching the gRPC limits of doc 10 §5.
5. Carve-out list (exactly): `policy_tests.fixture` (synthetic rows, control-plane-authored), `ComputeChangeset.assertions[].sql`, `ComputeChangeset.impact_queries[].sql`, `Summary.distinct_values` when allow-listed (doc 05 §5.2). Any new carve-out is a `contracts/` change (doc 18 §5).

## 7. Load and performance

`tools/loadgen` drives the write patterns of doc 03 principle 9 through the real proxy, engine, adapter host, and target. Doc 16 owns the SLOs; this document names the scenarios and what each measures against the spec figure it cites.

| Scenario | Pattern | Measures | Spec figure |
|---|---|---|---|
| `L1 burst_updates` | 500 single-row `UPDATE`s in a loop per branch, 50 branches | pass-through read p99, single-row write p99, writes/s per branch | doc 04 §7: < 5 ms, < 5 ms, 2,000/s |
| `L2 bulk_insert_select` | one `INSERT ... SELECT` of 100k rows per branch | merged-read latency, batched rows/s, compute at 100k | doc 04 §7 20,000 rows/s; doc 05 §7 ≤ 10 s |
| `L3 read_heavy` | 90 % reads with pushdown over touched tables | merged read p99 with ≤ 100k snapshot rows | doc 05 §5.5 p99 ≤ 25 ms (cached); doc 04 §7 < 50 ms |
| `L4 compute_scale` | overlays of 1k / 100k / 1M / 10M net rows | `engine_changeset_duration_seconds` by bucket | doc 05 §7 table (10M is estimate; promoted only after this run) |
| `L5 heartbeat_scale` | 100k non-terminal branches, fake data plane | heartbeat p99, boot sweep, memory per GenServer | doc 07 §7: ≤ 20 ms, ≤ 15 s, ~5 KB |
| `L6 merge_share` | 1k and 100k-row merges on Postgres | `compensation_persist_share_of_merge` | doc 09 §7: < 20 %, 1k p99 < 300 ms |
| `L7 evaluate` | 1,000 changesets × 200 policies | control-plane evaluate p99 | doc 06 §7 < 500 ms |
| `L8 adapter_throughput` | keyed reads and apply via host → Postgres | rows/s | doc 08 §7 ≥ 20,000 read, ≥ 5,000 apply |

**Regression gate.** `proxy/benches/`, `engine/benches/` (including `compensation.rs`) run on every PR touching those directories; > 5 % regression on any benchmark median fails (doc 18 §3). Benchmarks run on a dedicated self-hosted runner (fixed instance type, no other jobs, CPU governor pinned); each benchmark runs 5 times and the comparison uses the median of medians against the `main` baseline recorded on the same runner within the last 7 days; a baseline older than that is regenerated before comparison. Noise above 2 % between two runs of `main` marks the runner unhealthy and blocks the gate rather than passing it. L1–L8 run nightly against the local stack on the same runner; results go to doc 16's dashboards, and a nightly breach of a **Requirement** figure opens an issue automatically.

## 8. Chaos and resilience

Run weekly in staging (doc 14) and on demand via `tools/stack` hooks locally. Each experiment names the heartbeat-matrix cell or failure row that predicts the outcome; the assertion is the prediction.

| # | Fault | Predicted self-correction |
|---|---|---|
| C-1 | Kill `steward-engine` mid-compute | Changeset stays `computing`; coordinator retries same id (3 attempts / 5 min, doc 07 §5.2); after budget `compute_failed`, branch `open` |
| C-2 | Partition the Session stream for 10 min under write load | Zero failed queries on `open` branches (invariant 15); freezes land on reconnect; `heartbeat_lost` after 5 min, cleared on reconnect |
| C-3 | Fill the WAL volume | Writes fail `SD007`, nothing acknowledged is lost; reads continue; alert; recovery on free space |
| C-4 | GC the Neon branch under a live snapshot | Reads fail `SD004`; heartbeat carries `base_snapshot_gone`; branch `abandoned`, reason `snapshot_lost`, from whichever non-terminal state it was in; never `merging → proposed` |
| C-5 | Kill the control-plane node during a merge apply | Boot sweep rebuilds the GenServer; heartbeat (`merging`, `merging`) renews the lease and advances to `merged` when complete |
| C-6 | Corrupt the routing store file | `SD007` on new connections; file renamed aside; rebuilt within 60 s; alert |
| C-7 | Fail the metadata Postgres primary | Transitions 503; heartbeats answered `stale: true`; data plane does nothing destructive; queries unaffected |
| C-8 | Stop the adapter host during apply above 50k rows | Chunks committed stay in `applied_rows`; resume skips them; merge `applied` |

An experiment whose outcome lands in an "alert" cell of doc 13 §6.8 is a bug: the cell is unreachable by design, and the chaos run fails.

## 9. Security testing

Doc 15 owns the program; this is what runs in CI:

| Check | Tool | When | Blocks merge |
|---|---|---|---|
| Dependency audit | `cargo deny` (advisories, licences), `mix deps.audit` + `mix hex.audit`, Gradle `dependencyCheck`, `pip-audit`, `npm audit` | Every PR; nightly full | Yes on known-critical; licence violations always |
| Classifier fuzz | `proxy/fuzz/classify.rs` | 10 min nightly; 1 min smoke on proxy PRs | Yes on any `write` misclassified as `read` or any panic |
| SQL validator fuzz | `engine/fuzz/validate.rs` (doc 06 §10) | Same cadence | Yes |
| Sandbox escape suite | §4.2 with syscall trace | Every engine PR | Yes |
| Boundary test | §6 | PRs touching `contracts/`, `control/`, `engine/`; nightly | Yes |
| Secret scanning | `gitleaks` on the diff; pre-commit hook | Every PR | Yes |
| Log sentinel tests | Per-component (§4) | Every PR | Yes |
| Never-logged assertions | Grep of structured logs from E2E runs for API keys, grant JWTs, rationale text, SQL literals | Nightly | Opens an issue; blocks release |
| Grant tests | §4.6 and control-plane grant minting tests | Every PR | Yes |
| mTLS and SAN mismatch | `SessionAuthTest`: wrong SAN closes the stream | Every PR | Yes |

## 10. CI pipeline

| Stage | Contents | Runs on | Blocks merge |
|---|---|---|---|
| 1 Lint & build | `cargo fmt`/`clippy -D warnings`, `mix format --check-formatted`/`credo --strict`/`dialyzer`, Gradle build, `ruff`/`mypy`, `eslint`/`tsc`; generated code drift (`contracts/gen/`, `reasons.yaml`, policy mirror digests) | Every PR | Yes |
| 2 Unit + property (PR budget) | All unit tests; property tests at PR case counts (§2); golden diffs | Every PR | Yes |
| 3 Component integration | `<area>/tests/integration` with containers (MinIO, Postgres, Testcontainers); fake data plane; Salesforce WireMock | Every PR touching the area (path filter) | Yes |
| 4 Boundary & security | §6, §9 PR-cadence checks | Per path filters above | Yes |
| 5 Benchmarks | `proxy/`, `engine/` criterion with the 5 % gate | PRs touching `proxy/` or `engine/` | Yes |
| 6 E2E smoke | Scenarios 1–3 on the `neon` profile | Every PR | Yes |
| 7 Nightly | Full property counts; all fuzz targets; full driver matrix (9 drivers); all E2E scenarios on both profiles; Snowflake and Salesforce scratch-org suites; L1–L8; `BootSweep100kTest`, `HeartbeatStormTest`; never-logged grep | `main`, nightly | Opens issues; a red nightly blocks the next release tag |
| 8 Weekly | Chaos C-1..C-8 in staging; counter and compensation drift jobs | Weekly | Blocks release |

Required checks per doc 18 §3: build, tests, lint, and for `proxy/` and `engine/` the benchmark suite. Stages 1–6 **must** complete in ≤ 25 min on a PR; path filters keep untouched areas out.

**Flakiness policy.** A test that fails and passes on retry without a code change is flaky. It is quarantined the same day (tagged `:quarantine` / `#[ignore = "flaky: #NNN"]` / `@Disabled("flaky: #NNN")`) with an issue that names the owner; a quarantined test still runs nightly and reports. Quarantine lasts at most 7 days: by then it is fixed, rewritten, or deleted with a justification in the PR. More than 5 tests in quarantine at once blocks new feature PRs for the owning area until the count is below 5. Disabling a failing test without an issue is forbidden (doc 18 §5).

## 11. Test data

`tools/fixtures` is the single generator (doc 18 §7). It is a Python package with a CLI; every test in every language consumes its output as Parquet, SQL, or JSON.

**Retail schema** (used by every example in docs 06, 10, and 11; doc 11 §12 adds `inventory`, doc 06 §4.2 adds `ledger_entries`):

```sql
CREATE TABLE products  (sku text PRIMARY KEY, name text, category text, cost numeric(12,2));
CREATE TABLE prices    (sku text PRIMARY KEY REFERENCES products, price numeric(12,2), currency text, updated_at timestamptz);
CREATE TABLE inventory (sku text PRIMARY KEY REFERENCES products, qty int, received_at timestamptz);
CREATE TABLE customers (id uuid PRIMARY KEY, name text, email text, segment text);
CREATE TABLE invoices  (id uuid PRIMARY KEY, customer_id uuid REFERENCES customers, status text, total numeric(12,2), issued_at timestamptz);
CREATE TABLE ledger_entries (id bigint PRIMARY KEY, account text, amount numeric(14,2), posted_at timestamptz);
```

Every string column embeds the sentinel `ZQX-<seed>` so log-leak tests can grep for it; every numeric column is generated so that `price < cost` rows exist at a known rate (default 2 %) for the policy examples.

| Size | Base rows (products/prices) | Customers / invoices | Purpose |
|---|---|---|---|
| `s` | 1k | 500 / 5k | Unit, golden, policy tests |
| `m` | 100k | 20k / 200k | Integration, E2E, L1–L3 |
| `l` | 1M | 200k / 2M | Nightly load, L4 |
| `xl` | 10M | 1M / 10M | L4 10M bucket only; generated on the runner, never checked in |

**Write patterns** (doc 03 principle 9), each a named generator producing an overlay or a statement script: `burst_updates` (hundreds of small `UPDATE`s in a loop), `bulk_insert_select` (one large `INSERT ... SELECT`), `read_heavy_interleaved`, `insert_update_delete_chains` (3–5 ops per key for the fold table), `delete_heavy`, `noop_updates`, and `revert_shaped` (an overlay that is a compensation body). The SQL corpus for classifier regression is `fixtures sql-corpus`.

**Determinism.** Every invocation takes `--seed`; output for a given `(seed, schema version, generator version)` is byte-identical and its SHA-256 is pinned in `tools/fixtures/MANIFEST`; CI fails if regenerating changes a digest without a version bump. Sizes `s` and `m` are checked in as Parquet (≤ 50 MB); `l` and `xl` are generated on demand.

## 12. Definition of done for a milestone (testing side)

A milestone in doc 19 is testing-complete when all of the following hold:

1. Every invariant in §3 has its named tests present and green (rule I-0).
2. Every component in scope passes its §4 plan; adapters in scope pass the conformance suite on their real backend (nightly) and their mock (PR).
3. E2E scenarios in scope for the milestone pass on both stack profiles for three consecutive nightlies.
4. The boundary test passes and the carve-out list is unchanged or the change is recorded in `contracts/`.
5. Every **Requirement** figure the milestone claims (docs 04–09 §7) has a loadgen scenario that measures it and has met it on the dedicated runner; **Estimate** figures the milestone promotes to requirements are re-labelled in the spec with the measured value.
6. Benchmarks have a `main` baseline and the 5 % gate is active.
7. Chaos C-1..C-8 that apply to the milestone's components have run once in staging with predicted outcomes.
8. Quarantine count is zero for the milestone's areas.
9. `tools/fixtures` covers every schema and pattern the milestone's examples use.
10. The never-logged grep over a full nightly E2E run finds nothing.

## Alternatives considered

- **A single cross-language BDD suite (Cucumber) for all components.** Rejected: each language's native framework integrates with its sandboxing, property-testing, and snapshot tooling; the shared layer is the fixture format and the E2E scripts, not a test DSL.
- **Mocking the data plane in E2E instead of running the real one.** Rejected: the fake data plane is for control-plane integration tests; E2E exists to catch the real proxy/engine/adapter interplay and the heartbeat protocol, which a fake would encode assumptions about.
- **Running benchmarks on shared CI runners with a wider gate (10–15 %).** Rejected: a wide gate hides the regressions the 5 % gate in doc 18 §3 exists to catch; a dedicated runner with noise detection is cheaper than debugging hot-path regressions after the fact.
- **Model-based testing of the state machine with a separate formal spec (TLA+).** Deferred: the StreamData property test carries the doc 13 transition table literally and is cheaper to keep in sync; a TLA+ model is worth it if the lifecycle gains concurrent merges (doc 13 §11).
- **Recording cassettes from production for SDK tests.** Rejected: synthetic-only rule; cassettes come from the local stack.

## Open questions

| Question | Owner | Needed by |
|---|---|---|
| Confirm `control/test/` (mix convention) over `control/tests/` as written in docs 06 §10 and 07 §10; doc 18 §7's `<area>/tests/integration` would then have one exception | Control plane lead | Before M0 |
| Dedicated benchmark runner: cloud instance type and whether it is also the nightly loadgen host (shared load would add noise) | Infrastructure lead | Doc 14 |
| Neon-compatible pageserver container for the local stack: is one available for CI, or does the `neon` profile require the fallback replica path in CI until M0 substrate confirmation (doc 08 §12) | Adapters lead | Before M0 |
| Syscall tracing for sandbox escape tests in CI: `strace` on the runner or a `seccomp` audit profile in the engine container | Engine lead | Before M0 |
| Snowflake and Salesforce nightly accounts: who owns the credentials and the per-run cleanup | Adapters lead | M1 |
| Should E2E scenarios 4–10 also run on PRs touching `control/` and `engine/` (cost ~10 min) rather than nightly only | Founding team | Before M0 |
| Chaos in staging requires doc 14's staging environment; until it exists, is the local stack an acceptable substitute for C-1..C-8 | Infrastructure lead | Doc 14 |
