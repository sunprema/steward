# M0 — One branch, one merge: action items

**Goal (doc 19 §2):** an agent opens a branch on a Postgres target through the proxy, writes, proposes; the engine computes the changeset and runs policy; a human approves in the queue (or policy auto-merges); the merge applies with a compensation record; the merge can be reverted. Postgres only. Local stack only.

Each item: roadmap id, spec sections to read first, what done looks like, dependencies, size. Work top to bottom within a track; tracks run in parallel. Every PR follows `CLAUDE.md` and doc 18: one concern, tests included, local stack still works.

Status key: `[ ]` not started · `[~]` in progress · `[x]` merged (add PR #)

---

## 0. Before engineering starts (founders)

- [ ] **Q1 — Clear the 28 before-M0 questions.** Read doc 19 §5; each has a recommended answer. Answer them in one PR that edits every affected doc's "Open questions" table. Then set docs 01, 02, 03, 13 to `Accepted` in their status lines and in `docs/README.md`.
- [ ] **Q2 — Bootstrap the Elixir app.** `control/README.md` has the command. Add `ash`, `ash_postgres`, `ash_state_machine`, `reactor`, `ash_oban`, `ash_phoenix`, `boundary`. Declare the four boundaries (`Steward.Core`, `Steward.Coordinator`, `Steward.Jobs`, `StewardWeb`) with the dependency direction in `control/README.md`. Point the Repo at `control-db` (port 5433). `mix compile --warnings-as-errors` and `mix test` pass on an empty app. Commit the generated project.
- [ ] **Q3 — First local run of the scaffold.** `tools/stack/stack up` (needs Docker), `cd adapters && ./gradlew build` (needs Maven Central), `cargo build`. Fix anything the sandbox could not verify (PR #6 notes). Record the fix in the PR.

## 1. Cross-cutting (track C)

- [x] **C1 — contracts/** — `session.proto`, OpenAPI, `reasons.yaml`, `check.sh`. PR #6. *Remaining for C1:* `engine/*.proto` (`ProxyFacts`, engine ↔ proxy UDS service, doc 05 §3.1) and `adapter.proto` (doc 08 §3.1); generated stubs checked in for Rust (`tonic-build`), Elixir (`protobuf` mix task), Java (protobuf Gradle plugin); a drift check in CI that regenerates and diffs. *Elixir stubs and `mix steward.contracts.gen [--check]` are done (E13); the CI step that runs `--check` lands with C2.*
- [ ] **C2 — Build and CI** — doc 18 §1, §3, §9. GitHub Actions: `contracts/check.sh`; `cargo fmt --check`, `clippy -D warnings`, `cargo test`; `./gradlew build`; `mix format --check-formatted`, `credo --strict`, `mix test`; SDK tests. Benchmark job on a dedicated runner with the 5 % gate for `proxy/` and `engine/` (doc 17 §7). Size S.
- [x] **C3 — tools/fixtures** — retail schema, generator, loader. PR #6. *Remaining:* golden changesets and verdicts for the policy harness (doc 06 §10, doc 17 §4), agent write-pattern recordings for loadgen (doc 03 §7 p9).
- [x] **C4 — Local stack (base)** — control-db, target-db, MinIO. PR #6. *Remaining:* enable the `steward-proxy`, `steward-engine`, `steward-adapters`, `steward-control` services in `tools/stack/docker-compose.yml` as each lands; Neon pageserver profile per doc 08 §5.1 (J2).
- [ ] **C5 — tools/e2e** — doc 10 §7 A–C, doc 17 §5. Scenarios 1–3 as OpenAPI contract tests against the local stack. Depends on C4 complete. Size M.
- [ ] **C6 — tools/loadgen** — doc 04 §10, doc 16 §10. Load driver with `replay` subcommand. Depends on C3, P4. Size M.
- [~] **E13 — Fake data plane** — doc 07 §10. `fake_data_plane.ex` speaking the `Session` stream with scripted failures covering every doc 13 §6 row; lets the Elixir track run without Rust. Depends on C1. Size M. *Do this early.*
- [ ] **Fake Session server (Rust side)** — doc 19 §4. A minimal control-plane stub that accepts the `Session` stream and replies to heartbeats, so the Rust track runs without Elixir. Lives in `tools/fake-control`. Size S.

## 2. Elixir control plane (track E) — `control/`

- [ ] **E1 — Ash domains and resources** — doc 12 §0–§2, §2.4, §2.5, §10, §11; doc 07 §4, §5.0. Five domains (`Steward.Targets`, `Steward.Branches`, `Steward.Policies`, `Steward.Reviews`, `Steward.Audit`), one resource per doc 12 table, `mix ash.codegen` migrations committed and matching doc 12's DDL (add hand-written fragments for enums, `validate_boundary_json`, append-only grants). Attribute multitenancy on `org_id`. The `AppendEvent` change (in-transaction, never a notifier). `mix steward.reasons.export` reads `contracts/reasons.yaml` into the enum. Tests: `MigrationDriftTest`, `OrgIdTest` (doc 17 §4). Depends on Q2. Size L. *Start here.*
- [~] **E1b — Authorization** — doc 07 §5.0, §8; doc 15 §3.2. `Ash.Policy` on every action from the doc 15 matrix; `ApiKey` and `Principal` actors; `PolicyCoverageTest` fails if any action lacks a policy. Depends on E1. Size S.
- [~] **E2 — Branch coordinator** — doc 07 §4, §5.0, §5.3; doc 13 §2.1, §6.8, §10. `AshStateMachine` on `Branch` with exactly the doc 13 transitions; `Registry`, `PartitionSupervisor`, `Branch` GenServer calling actions; `BootSweeper`; `TerminalProcessSweep`; the `Steward.Lifecycle` Spark DSL declaring the heartbeat matrix and generating both the dispatcher and `HeartbeatMatrixTest` (40 cells). `StateMachineDeclarationTest`. Depends on E1. Size L. *Deferred out of E2:* AshOban scheduling of `TerminalProcessSweep` (no Oban setup yet; first consumer is E4), `:pg` cross-node uniqueness (one node today), the StreamData state-machine property test, and the merge-side `HeartbeatActions` (E6).
- [~] **E3 — Session host** — doc 07 §3.1, §5.3; doc 10 §5; doc 13 §6.8. elixir-grpc server on 50051 (plain TLS locally; mTLS config present), `Heartbeat.decide/3`, `HeartbeatFlusher`, per-data-plane token bucket, instruction queue with reply deadlines and re-send. Test against E13. Depends on E2, E13. Size L. *Deferred out of E3:* routing an instruction to the node that holds the stream (`:pg`; one node today), the `ChangesetReport` / `MergeOutcome` handlers (E4, E5, E6; counted in telemetry until then), the `Enrolment` service (doc 14 §6), and `HeartbeatLostScan` (needs the Oban setup).
- [ ] **E4 — Lifecycle Reactors** — doc 13 §6.1, §6.3, §6.7; doc 07 §5.0–§5.2. `CreateBranch`, `Propose`, `Abandon` reactors (`Merge`/`Revert` bodies in E6/E7) with compensable pre-checkpoint steps; `ReactorStepTest` asserting compensation and the no-undo-after-checkpoint rule; TTL and minute reconciliation as AshOban scheduled actions. Depends on E2, E3. Size M.
- [ ] **E5 — Policy engine** — doc 06 §4, §5, §8. YAML parse and validate, scope filter, versions and lifecycle (`AshStateMachine`), `policy_admin` gate with `separate_approval`, verdict combination `block > hold > auto-merge`, `policy_error` and `no_policy_coverage` handling, `ReevaluateJob`, tests-as-data harness (initially against a stub for the R6 NIF), `record_review_features/1`. Depends on E1; full harness depends on R6. Size L.
- [ ] **E6 — Merge** — doc 07 §5.0, §5.4; doc 13 §6.5, §7. `Merge` reactor body, per-target lease actions, `MergeOutcome` handling, `stale_base` recompute, `ExpiredLeaseScan`, `merge.stalled`. Depends on E3, E4. Size M.
- [ ] **E7 — Revert** — doc 13 §6.6; doc 07 §5.0, §5.2; doc 12 §4. `Revert` reactor, `POST /merges/{id}/revert`, `revert_conflict` floor in the coordinator, `compensation_records_meta` mirror, `SetRetention`/`SetLegalHold` delivery. Depends on E6. Size M.
- [ ] **E8 — Queue and reviews** — doc 07 §5.5, §5.7, §5.8. `queue_entries` read model, `Review.decide` with every error code, counters with `CounterDrain` (DELETE … RETURNING), events consumers. Depends on E4. Size M.
- [ ] **E9 — LiveView UI** — doc 07 §5.6. Queue, changeset detail (grant-fetched row delta), policy editor and test runner, target settings, audit log. AshPhoenix forms, PubSub, Presence. Depends on E5, E8, R10. Size L.
- [ ] **E10 — REST API** — doc 10 §2–§4. Every endpoint as a thin controller over one Ash action; `Ash.Error` → error envelope; idempotency store; rate limits; API keys and memberships; OIDC via `ueberauth`; `stwt_` tokens. Contract-tested against `contracts/openapi/steward-v1.yaml`. Depends on E4–E8. Size L.
- [ ] **E11 — Webhooks** — doc 10 §6; doc 12 §2.3. Delivery consumer, HMAC signing, retry ladder, suspension. Depends on E10. Size S.
- [ ] **E12 — Retention and export** — doc 12 §9; doc 13 §9; doc 07 §5.7. `RetentionJob` → `CloseOverlay` → `closed`; `IdempotencyPurge`; `AnalyticsExport` to Parquet on MinIO. Depends on E4. Size M.

## 3. Rust data plane (track R) — `engine/`, `proxy/`

- [ ] **R1 — `steward-overlay` crate** — doc 05 §4.1, §5.5; doc 12 §8.2–§8.4. WAL append with fsync, segment roll to Parquet, manifest with conditional PUT to MinIO, freeze/unfreeze markers, net-op reader, `view()`. Property tests: net-op fold golden cases; crash tests at each write step. Depends on C1. Size L. *Start here.*
- [ ] **R3 — `steward-engine` process** — doc 05 §5.1; doc 10 §5; doc 13 §6.8. gRPC over UDS for the proxy, outbound `Session` stream with jittered reconnect, heartbeat sender folding `ProxyFacts`, instruction dispatch. Test against the fake control-plane stub. Depends on C1. Size M.
- [ ] **R4 — ComputeChangeset** — doc 05 §5.2, §7. Freeze-marker wait, net-op collapse, keyed base reads via the adapter host, summary with the 256 KiB cap, row delta persist, `ChangesetReport`. Depends on R1, R3, J1. Size L.
- [ ] **R5 — Sandbox, impact, assertions** — doc 05 §5.3, §5.4, §8. Locked-down DuckDB (exact settings in doc 05 §8), impact queries, assertions returning `sample_ref` only, 20 s / 60 s budgets. Sandbox escape tests from doc 17 §4. Depends on R4. Size M.
- [ ] **R6 — Rustler NIF** — doc 06 §5.5, §8; doc 03 §8. `validate` with the shared SQL parser and allowlist; policy test mode; dirty schedulers. Depends on R5. Size M.
- [ ] **R7 — Staleness and compensation** — doc 05 §5.6. `StalenessCheck`, `ComputeCompensation` with the inverse rules, `conflicts.t`, `delta.reversible`. Property test: apply ∘ compensate = identity. Depends on R4, J2. Size M.
- [ ] **R8 — Compensation log** — doc 09 §5.1–§5.5, §8; doc 12 §8.7. `Persist` with segments-then-header atomicity and read-back, SQLite index, hash chain, `Open`/`Release`/`Keys`/`Status`/`Verify`, GC honouring `retention_until` and legal hold. Crash injection tests. Depends on R7. Size L.
- [ ] **R9 — Merge worker** — doc 13 §6.5, §6.6; doc 09 §5.3. `Merge` instruction: staleness → compensation → apply with per-row progress → `MergeOutcome`; revert overlay materialisation. Depends on R7, R8, J2. Size M.
- [ ] **R10 — Grant endpoint** — doc 10 §3.3; doc 07 §5.6; doc 09 §8. `GetRowDelta` paging, assertion samples, compensation read; ES256 grant verification; `DataPlaneAuditEvent`. Depends on R4, R8. Size M.
- [ ] **R11 — CloseOverlay and sweeps** — doc 05 §5.7; doc 13 §9. Depends on R1. Size S.
- [ ] **R2 — Compaction** — doc 05 §4.2. Depends on R1. Size S.
- [ ] **P1 — Proxy: pgwire front end and branch resolution** — doc 04 §3, §4. pgwire listener, SCRAM with API-key hash, database-name = branch id, SQLite routing store populated from the engine over UDS, `SD002`/`SD003`/`SD00A–C` errors. Driver matrix test (psql, psycopg, SQLAlchemy, node-postgres). Depends on C1, R3. Size L.
- [ ] **P2 — Proxy: statement classifier** — doc 04 §5.1. AST-based classification, fail-closed (`SD006`), unsupported list (`SD005`). Property tests. Depends on P1. Size M.
- [ ] **P3 — Proxy: write path and freeze** — doc 04 §5.2, §5.3. Writes to the overlay WAL via `steward-overlay`, BEGIN/COMMIT as atomic batches with the 64 MB cap (`SD008`), freeze enforcement (`SD001`), evidence capture with literal scrubbing and `SET steward.rationale`. Depends on P2, R1. Size L.
- [ ] **P4 — Proxy: read path** — doc 04 §5.4. Pass-through reads on the snapshot credential from the adapter; overlay-merged reads through `view()` for touched tables; clear errors for unsupported shapes. Latency benchmark (p99 < 5 ms pass-through). Depends on P3, J2. Size M.

## 4. Java adapters (track J) — `adapters/`

- [ ] **J1 — API and host** — doc 08 §3.1, §5.5, §11. `Connector` interface is in place (PR #6); add the gRPC host over UDS with an explicit adapter registry, credential resolution from env/secret files with rotation, JVM flags. Depends on C1. Size M. *Start here.*
- [ ] **J2 — Postgres adapter** — doc 08 §5.1, §5.2, §5.4, §8. Neon branch `openSnapshot` with an ephemeral read-only role; `readRows`, `currentRows`, `scanTableExpensive`; `apply` with `steward.applied_rows`, 50k/10k chunking, resumable by merge id; schema-drift table; `describe()`. Depends on J1. Size L.
- [ ] **J3 — Postgres fallback** — doc 08 §11. Pinned-LSN replica mode with snapshot age surfaced. Depends on J2. Size M.
- [ ] **J4 — Conformance suite** — doc 08 §10. JUnit over Testcontainers Postgres 16: every `Connector` method, apply-twice property (jqwik), `SNAPSHOT_LOST` and `SCHEMA_MISMATCH` cases. Depends on J1. Size M.

## 5. SDKs (track S) — `sdk/`

- [ ] **S2 — TypeScript SDK core** — doc 11 §2.2, §4, §10. Generated client from the OpenAPI doc; error mapping; retry; idempotency keys. Depends on C1. Size M. *Before S3.*
- [ ] **S3 — MCP server** — doc 11 §8. The eight tools, three resources, the safe-operations prompt, safety rules 1–6. Depends on S2. Size M.
- [ ] **S1 — Python SDK** — doc 11 §2–§7, §9–§11. Generated layer, `Client`/`Branch`/`Changeset`, `explain` on both channels, exit semantics, error mapping, non-blocking `wait`, webhook verify, `admin` namespace. Depends on C1, E10. Size M.
- [ ] **S4 — SDK tests** — doc 11 §13. Cassettes, proxy `SD` stub, local-stack integration, MCP conformance. Depends on S1–S3, C4. Size S.

## 6. Definition of done for M0 (doc 19 §2, doc 17 §12)

- [ ] E2E scenarios 1–3 (doc 17 §5) pass against `tools/stack` on every PR; 4–11 pass nightly.
- [ ] Every doc 13 §10 invariant has a test (doc 17 §3 table) and the CI rule enforcing it is on.
- [ ] Boundary test passes: no plane message or `/v1` response can carry row data.
- [ ] SLOs S1 (proxy pass-through p99 < 5 ms), S7 (zero corrupt compensation records), S9 (zero boundary rejections) hold on the local load test.
- [ ] Docs 04–13 moved to `Accepted`; open questions resolved or re-filed for M1.

---

## Done

| Item | PR | Notes |
|------|----|-------|
| Design documents 01–19 | #1–#5 | All Draft; see Q1 |
| C1 (contracts base), C3, C4 (base), workspace skeletons, `CLAUDE.md` | #6 | Remaining parts listed above |
