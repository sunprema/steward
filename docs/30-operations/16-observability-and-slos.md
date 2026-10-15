# 16 — Observability and SLOs

**Status:** Draft
**Owner:** Founding team
**Last updated:** 2026-10-15

This document consolidates every §7 (performance) and §9 (observability) section of docs 04–09 into one set of SLOs, one metrics catalogue, one logging and tracing contract, the dashboards, and the small set of alerts that page. It decides what Steward's on-call sees for its own control plane, what each customer's data plane emits so it works with the customer's stack, and what a target admin sees in the product. Numbers stated here are the numbers in the component specs; where a spec left a number open, this document fills it and says so. Doc 15 owns the never-log list; doc 17 owns how the load scenarios here are run; doc 14 owns where the collectors are deployed.

## 1. Philosophy

Three kinds of signal, kept apart because they have different audiences:

| Signal | Question | Audience | Examples |
|---|---|---|---|
| System health | Is Steward up and within budget? | Steward on-call | API 5xx, heartbeat lag, Oban age, proxy p99 |
| Product health | Is the review loop working? | Founders, customer success, the customer | queue depth, auto-merge ratio (doc 01 §10: > 80% within 90 days), held > 7 days (doc 13 §12), partial-compensation ratio (doc 09 §9) |
| Customer-facing | What does a target admin see? | Target admin, reviewer | per-target health, heartbeat status, data-plane version, merge progress |

Rules that follow:

- **The on-call surface is small.** At most ten conditions page Steward's on-call (§7). Everything else is a dashboard panel or a ticket. A product metric never pages: a deep queue is a conversation with the customer, not an incident.
- **Metadata only crosses the boundary**, for telemetry as for everything else (doc 03 §2). Steward's view of a customer's data plane is derived from what already rides the `Session` stream (doc 10 §5): heartbeats, `ChangesetReport`, `MergeOutcome`, `InstructionResult`. Raw data-plane metrics stay in the customer's cloud and go to the customer's own stack.
- **Zero-tolerance invariants are SLOs with a target of zero**, and any increment pages. They are the product promise, so they get the loudest signal.
- **Measure before optimising** (doc 03 principle 9). Every number in §2 has a load scenario in §10 that produces it.

## 2. SLOs

All SLOs use a 30-day rolling window. "Per data plane" SLOs are computed per customer deployment and shown to that customer; "global" SLOs are Steward's own. Latency SLIs exclude customer-controlled time (target latency, customer SQL) wherever the spec does; the customer-visible wall clock is reported alongside but is not an SLO.

| ID | SLO | SLI (what, where) | Target | Scope | Source |
|---|---|---|---|---|---|
| S1 | Proxy pass-through read added latency | p99 of `proxy_statement_duration_seconds{class="read",route="pass_through"}` per 5-min window | < 5 ms in 99% of windows | Per data plane | doc 04 §7 |
| S2 | Proxy single-row write added latency | p99 of `proxy_statement_duration_seconds{class="write",route="overlay"}`, autocommit, incl. WAL fsync | < 5 ms in 99% of windows | Per data plane | doc 04 §7 |
| S3 | Branch create end to end | p99 of `steward_api_request_duration_seconds{route="POST /v1/branches",status="201"}` (covers doc 13 §6.1 steps 1–8 incl. overlay init) | ≤ 1 s | Global, broken out per org | doc 07 §7, doc 03 §5 |
| S4 | Propose-to-verdict platform latency, by overlay bucket | `control_plane_ms + data_plane_ms − (impact_ms + assertions_ms)` per evaluated changeset (doc 12 §7 `changeset_facts` plus `engine_changeset_duration_seconds{phase}`), p95 per bucket | 1k: ≤ 1.5 s · 100k: ≤ 10.5 s · 10M: ≤ 10.5 min (Postgres column of doc 05 §7 + doc 06 §7's 500 ms) | Per data plane | docs 05 §7, 06 §7 |
| S5 | Heartbeat freshness | `steward_branches_heartbeat_stale_total{data_plane_id} / steward_branches_nonterminal{data_plane_id}` where stale = `now − last_heartbeat_at > 60 s` | ≥ 99.5% of non-terminal branches fresh | Per data plane | doc 13 §6.8 (`heartbeat_lost` at 5 min is the alert, not the SLO) |
| S6 | Merge applies without manual intervention | merges reaching `applied` with no `merge.stalled` event and no `target.lease_expired` event / all merges that passed the compensation checkpoint (`merge_facts`) | ≥ 99.5% | Per data plane | doc 13 §6.5 |
| S7a | API availability | `1 − 5xx / all` on `/v1/*` excluding `503` returned during a declared Postgres failover window ≤ 5 min | 99.9% | Global | doc 07 §6 |
| S7b | Proxy availability | `1 − (SD007 statements + SD007 connection refusals) / (statements + connections)` | 99.95% | Per data plane | doc 04 §6; the proxy has no control-plane dependency (doc 13 invariant 15), so this is purely data-plane health |
| S7c | Review UI availability | LiveView mount success ratio on queue and changeset pages | 99.9% | Global | doc 07 §5.6 |
| S8 | Compensation durability | `steward_plane_compensation_status_total{status="corrupt"}` and `compensation_chain_verify_failures_total` | **Zero** | Per data plane, zero-tolerance | doc 09 §9 |
| S9 | Boundary invariant | `steward_boundary_rejections_total` = rejections by `validate_boundary_json()` (doc 12 §2.4) + Ecto embedded-schema rejections (doc 07 §8) + `steward_plane_oversize_total` (doc 10 §5) | **Zero** in production | Global, zero-tolerance | doc 12 §2.4, doc 13 invariant 9 |
| S10 | No unreviewed held changeset merges | weekly SQL: merges whose changeset verdict was `hold` and whose branch has no `review` with `decision = approved`, or whose verdict was `block` | **Zero** | Global, zero-tolerance | doc 01 §10, doc 13 invariants 12 |

Component latency budgets that are requirements in a spec but too internal to be customer SLOs are tracked as dashboard thresholds and ticket alerts, not SLOs: heartbeat handling p99 ≤ 20 ms, review decision tx p99 ≤ 100 ms, propose control-plane portion p99 ≤ 200 ms (doc 07 §7); policy evaluate control-plane p99 < 500 ms (doc 06 §7); compensation persist < 20% of merge wall time and < 300 ms p99 at 1k rows (doc 09 §7); `view()` p99 ≤ 25 ms cached (doc 05 §5.5).

Reference PromQL for S1 (the pattern every latency SLI follows):

```promql
# SLI: good windows / all windows, 30d
sum_over_time((
  histogram_quantile(0.99,
    sum by (data_plane_id, le) (rate(proxy_statement_duration_seconds_bucket{class="read",route="pass_through"}[5m]))
  ) < bool 0.005
)[30d:5m]) / count_over_time(vector(1)[30d:5m])
```

Reference SQL for S4 (run by `AnalyticsExport`'s destination, doc 12 §7):

```sql
SELECT overlay_bucket,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY control_plane_ms + data_plane_ms - impact_ms - assertions_ms) AS p95_ms
FROM changeset_facts
WHERE evaluated_at >= now() - interval '30 days' AND superseded = false
GROUP BY overlay_bucket;
```

`impact_ms` and `assertions_ms` are **New** columns on `changeset_facts`; doc 12 §7 has `compute_ms`, `control_plane_ms`, `data_plane_ms` only.

**Error-budget policy.**

- S1–S7 use multi-window burn-rate alerting: fast burn (14.4× over 1 h and 5 min) pages; slow burn (6× over 6 h and 30 min) tickets.
- S8–S10 have no budget: any non-zero increment pages immediately (§7) and opens an incident with a written post-mortem.
- When a component's 30-day budget is exhausted, that component's owning lead **must** prioritise reliability work and the component **must not** ship non-reliability changes until the budget is back above 25%. Hot-path optimisations in `proxy/` and `engine/` **must** cite the §10 scenario that motivated them (doc 03 principle 9).
- Per-data-plane SLOs that are missed because of the customer's own infrastructure (object store down, target slow, Salesforce quota) are annotated as such from the error code (`object_store_unavailable`, `adapter_unavailable`, `RATE_LIMITED`) and excluded from Steward's budget but still shown to the customer.

## 3. Metrics catalogue

**Labelling rule.** A label **must** have bounded cardinality for the lifetime of a deployment. Allowed: `target_id`, `target_kind`, `data_plane_id`, `org_id` (control plane only), and enumerations (`class`, `route`, `outcome`, `code`, `phase`, `overlay_bucket`, `op`, `kind`, `state`, `status`, `from`, `to`). Never: `branch_id`, `changeset_id`, `merge_id`, `principal_id`, `policy_id`, `assertion_id`, `request_id`. Per-entity facts belong in logs, traces, and the analytics store, which are keyed by ID. This overrides doc 04 §9 ("all labelled by `branch_id`") and doc 08 §9 (`adapter_apply_rows_total{merge_id}`); doc 05 §9 already states the rule. Per-merge progress reaches the UI through the heartbeat's `merge_progress`, not through a metric label.

`overlay_bucket` is one of `1k | 10k | 100k | 1m | 10m` (doc 05 §9), assigned by net rows at the first power-of-ten boundary at or above the count.

### 3.1 Write proxy (doc 04 §9), data plane

| Metric | Type | Labels | Feeds |
|---|---|---|---|
| `proxy_statements_total` | counter | `class, route, outcome, code` | S7b; Data-plane dashboard |
| `proxy_statement_duration_seconds` | histogram | `class, route` | S1, S2 |
| `proxy_overlay_bytes`, `proxy_overlay_rows` | gauge | `target_id` (summed over branches) | Capacity |
| `proxy_freeze_rejections_total` | counter | `target_id` | Data-plane dashboard (expected traffic, not an alert) |
| `proxy_unroutable_connections_total` | counter | `target_id` | Ticket if sustained > 60 s after create (doc 13 §6.1 failure 6) |
| `proxy_unsupported_statements_total` | counter | `reason` | Product: what agents hit (doc 04 §12) |
| `proxy_unclassifiable_statements_total` | counter | — | Data-plane rule: > 0 is a bug (doc 04 §6) |
| `proxy_evidence_gap_total` | counter | `target_id` | Data-plane dashboard |
| `proxy_heartbeat_age_seconds` | gauge | instance | Data-plane dashboard; backoff to 60 s is normal (doc 04 §5.6) |
| `proxy_routing_rows`, `proxy_connections{state}` | gauge | — | Capacity (ceilings 5,000 and 1,000, doc 04 §7) |
| `proxy_overlay_roll_lag_seconds` | gauge | — | Data-plane rule at > 15 min (doc 04 §6) |

### 3.2 Changeset engine (doc 05 §9), data plane

| Metric | Type | Labels | Feeds |
|---|---|---|---|
| `engine_changeset_duration_seconds` | histogram | `phase, overlay_bucket` | S4 |
| `engine_duckdb_memory_high_water_bytes` | gauge | `instance=compute\|sandbox` | Capacity (8 GiB / 2 GiB caps, doc 05 §7) |
| `engine_sql_timeouts_total`, `engine_sql_errors_total` | counter | `kind`, `kind, code` | Policy health |
| `engine_compaction_lag_segments`, `engine_compaction_duration_seconds` | gauge, histogram | `target_id` | Ticket at lag > 10 min (doc 05 §7) |
| `engine_object_store_requests_total`, `engine_object_store_latency_seconds` | counter, histogram | `op, outcome` | Data-plane dashboard; budget exclusion |
| `engine_base_read_rows_total`, `engine_base_read_duration_seconds` | counter, histogram | `target_id, kind` | S4 attribution |
| `engine_view_latency_seconds` | histogram | — (emitted by proxy) | Dashboard threshold p99 ≤ 25 ms |
| `engine_computations_inflight`, `engine_queue_depth` | gauge | — | Capacity (max 2 concurrent, doc 05 §7) |
| `engine_failures_total` | counter | `code` | Three signals; budget exclusion |
| `engine_disk_free_ratio` | gauge | `volume` | **New**; data-plane rule at < 10% (doc 05 §6) |

### 3.3 Policy engine (doc 06 §9), control plane

| Metric | Type | Labels | Feeds |
|---|---|---|---|
| `steward_verdicts_total` | counter | `target_id, outcome, reason` | Product; `steward_auto_merge_ratio` recording rule |
| `steward_policy_error_total` | counter | `target_id` | Product; ticket at > 1% of verdicts over 1 h (doc 06 §9's `steward_policy_error_rate`, renamed to a counter plus recording rule) |
| `steward_evaluate_duration_seconds` | histogram | `phase=control\|data` | Ticket on control p99 > 500 ms (doc 06 §7); unit changed from `_ms` to seconds per Prometheus convention |
| `steward_reevaluation_jobs` | gauge | `state` | Policy health |
| `steward_policies_broken_total` | gauge | `target_id` | Policy health; customer health summary |
| per-assertion fire rate (`steward_assertion_results_total{policy, assertion, status}` in doc 06 §9) | — | — | **Moved to the analytics store** (`verdict_assertions` via `changeset_facts.fired_assertion_ids`): `policy_id × assertion_id` is unbounded per the labelling rule. The Policy health dashboard queries it by SQL |

### 3.4 Control plane and review queue (doc 07 §9)

| Metric | Type | Labels | Feeds |
|---|---|---|---|
| `steward_heartbeat_lag_seconds` | histogram (sampled every 30 s over non-terminal branches) | `data_plane_id` | Three signals |
| `steward_branches_nonterminal`, `steward_branches_heartbeat_stale_total`, `steward_branches_heartbeat_lost_total` | gauge | `data_plane_id, state` | S5; **New** names for doc 07's "heartbeat_lost count" |
| `steward_heartbeats_total` | counter | `data_plane_id, result=ok\|rate_limited\|unknown` | Storm detection (doc 07 §5.3) |
| `steward_heartbeat_matrix_total` | counter | `believed, authoritative, action` | Page on `action="alert"` (doc 13 §6.8) |
| `steward_heartbeat_handle_duration_seconds` | histogram | — | Threshold p99 ≤ 20 ms |
| `steward_genservers_total` | gauge | `state` | Leak check vs `steward_branches_nonterminal` (doc 07 §6) |
| `steward_transitions_total` | counter | `from, to, outcome=ok\|stale_transition\|unavailable` | Three signals |
| `steward_api_request_duration_seconds` | histogram | `route, status` | S3, S7a |
| `steward_liveview_mount_duration_seconds`, `steward_liveview_mounts_total` | histogram, counter | `page, outcome` | S7c; threshold 200 ms for queue |
| `oban_jobs_queue_depth`, `oban_jobs_oldest_age_seconds` | gauge | `queue` | Page at age > 10 min on `evaluate`, `merge`, `reconcile` |
| `steward_counter_deltas_backlog` | gauge | — | Ticket at > 100k rows |
| `steward_lease_waits_total`, `steward_lease_expired_total` | counter | `target_id` | Page on expiry with pending merge |
| `steward_pg_unavailable` | gauge | — | Page |
| `ecto_query_duration_seconds` | histogram | `repo, source` | Capacity |
| `steward_plane_oversize_total` | counter | `data_plane_id, direction` | S9 |
| `steward_boundary_rejections_total` | counter | `site=trigger\|ecto\|grpc` | S9; **New** |
| `steward_plane_sessions` | gauge | `data_plane_id` | Page when 0 with non-terminal branches > 10 min; **New** |
| `steward_plane_instruction_results_total` | counter | `data_plane_id, kind, error_code` | Per-data-plane health; **New** |
| `steward_plane_merge_outcomes_total` | counter | `data_plane_id, status, failure_reason` | S6; **New** |
| `steward_plane_compensation_status_total` | counter | `data_plane_id, status` | S8; **New**, derived from `Heartbeat.compensation_status` |
| `steward_plane_version` | gauge (=1) | `data_plane_id, component, version` | Customer-facing; **New**, requires a `version` field on `DataPlaneMessage` (§12) |

### 3.5 Adapters (doc 08 §9), data plane

| Metric | Type | Labels | Feeds |
|---|---|---|---|
| `adapter_call_duration_seconds` | histogram | `target_kind, target_id, op` | S4 attribution; doc 08 §7 requirements |
| `adapter_errors_total` | counter | `target_kind, target_id, op, code` | Three signals |
| `adapter_apply_rows_total`, `adapter_apply_in_progress` | counter, gauge | `target_id, outcome` (no `merge_id`) | Stalled-merge detection: flat `in_progress` with `merging` branch |
| `adapter_pool_active`, `adapter_pool_wait_seconds` | gauge, histogram | `target_id` | Ticket at p99 > 1 s (doc 08 §6) |
| `adapter_snapshots_open`, `adapter_snapshot_lost_total` | gauge, counter | `target_id` | Data-plane dashboard |
| `adapter_quota_remaining`, `adapter_quota_reset_seconds` | gauge | `target_id` | Data-plane rule at < 10% for Salesforce |
| `adapter_host_startup_seconds`, `adapter_plugin_loaded` | gauge | `kind, version` | Capacity (< 5 s, doc 08 §7) |

### 3.6 Compensation log (doc 09 §9), data plane

All from doc 09 §9 unchanged, labelled `target_id` only: `compensation_records_written_total{status}`, `compensation_partial_ratio`, `compensation_persist_seconds`, `compensation_persist_share_of_merge`, `compensation_reverts_total{outcome}`, `compensation_corrupt_total`, `compensation_gc_lag_seconds`, `compensation_index_repairs_total{kind}`, `compensation_chain_verify_failures_total`, `compensation_bytes_stored`, plus **New** `compensation_volume_used_ratio` for the 80% rule in doc 09 §6.

### 3.7 Product metrics (control plane, from `counters`, doc 07 §5.8)

| Metric | Type | Labels | Definition |
|---|---|---|---|
| `steward_queue_depth` | gauge | `target` | `counters.queue_depth{target}` |
| `steward_verdicts_total` | counter | `target, outcome` | §3.3 |
| `steward_auto_merge_ratio` | recording rule | `target` | `sum(increase(steward_verdicts_total{outcome="auto-merge"}[7d])) / sum(increase(steward_verdicts_total[7d]))`; doc 01 §10 target 0.8 |
| `steward_held_over_7d` | gauge | `target` | `counters.held_over_7d{target}` (doc 13 §12) |
| `steward_partial_compensation_ratio` | gauge | `target` | from heartbeat `compensation_status` over 24 h: `partial / (complete + partial)`; mirrors doc 09's `compensation_partial_ratio` on the control plane |
| `steward_policy_error_total` | counter | `target` | §3.3 |
| `steward_open_branches` | gauge | `target` | `counters.open_branches{target}` |
| `steward_reviewed_changesets` | gauge | `org, month` | the billing meter (doc 01 §7); dashboard only, never alerted |

`target` is the `target_id`; the short label name is kept because these metrics are exported to customers.

## 4. Logging

- **Format.** Structured JSON on stdout everywhere (doc 18 §2). One event per line; keys in snake_case; `ts` RFC 3339 UTC; `level`, `component`, `msg`, then the common field set.
- **Common fields** (present when known, omitted when not): `org_id`, `target_id`, `data_plane_id`, `branch_id`, `overlay_id`, `changeset_id`, `merge_id`, `principal_id`, `request_id`, `trace_id`, `span_id`, `instruction_id`. `principal_id` is the ID, never the API-key prefix.
- **Never logged.** Doc 15 owns the denylist; the union of the per-component lists is: statement text with literals, bind parameters, result rows, row images, keys and sample keys, API keys and grant JWTs, `steward.rationale` and review notes, connection strings, credentials, export destinations with row data, event `payload` bodies (doc 04 §8, doc 05 §8, doc 07 §8, doc 08 §8, doc 09 §8). Policy SQL bodies **may** be logged at `DEBUG` with the version ID in the control plane only, pending doc 15 (doc 06 §8).
- **CI test.** Every component's integration suite runs with a sentinel seeded into fixture rows, keys, parameters, and credentials and fails if any captured log line, metric label, or span attribute contains it (doc 08 §10 already does this; it becomes a repo-wide rule in doc 17). A second test greps emitted JSON for a denylisted key name at any depth, reusing the key list of `validate_boundary_json()` (doc 12 §2.4).
- **Levels.** `ERROR`: an invariant or checkpoint failure. `WARN`: a retryable failure or a budget exhausted. `INFO`: one line per lifecycle transition, per `Instruction` result, per compute phase, per adapter call (doc 08 §9), per heartbeat anomaly. `DEBUG`: off in production.
- **Proxy hot path.** No per-statement log line at `INFO` (doc 04 §7's hot-path rule: no I/O beyond the WAL and evidence log). Statement errors are logged at `WARN` sampled 1-in-100 per `(code)` with a counter of suppressed lines; `SD006` and `SD007` are logged every time. Per-statement detail lives in the evidence log and the 1% trace sample.
- **Retention.** Control plane: 30 days hot (indexed, searchable), 1 year cold (object storage, restorable), then deleted; `audit_log` and `events` are the compliance record and keep their own retention (doc 13 §9, doc 12 §9). Data plane: logs go to the customer's stack; the Helm chart defaults to 14 days in the local collector buffer and documents that the customer owns longer retention.

## 5. Tracing

OpenTelemetry across both planes, W3C `traceparent` everywhere.

**Propagation path.** SDK span (doc 11 §9, when an OTel SDK is installed; carries `request_id` and `task_id`) → API request span (`traceparent` header) → Branch GenServer span → `Instruction` on the `Session` stream → engine `ComputeChangeset` / `Merge` span → adapter gRPC spans (doc 08 §9: W3C context over the local socket) → compensation `Persist` span (doc 09 §9). Because instructions are messages on one long-lived stream, per-call gRPC metadata cannot carry the context (doc 07 §9 assumes it can); a **New** `trace_context` string field on `Instruction`, `InstructionResult`, `ChangesetReport`, and `MergeOutcome` is required and is a `contracts/` change (doc 18 §5; §12). Proxy statement spans are a separate trace per statement, linked to the branch by `branch_id` attribute; they carry the statement fingerprint hash, never text (doc 04 §9).

**Span names**, one per doc 13 flow, with child spans per step number:

| Flow | Root span | Children |
|---|---|---|
| 6.1 create | `branch.create` | `intent`, `overlay.initialise`, `commit`, `routing.upsert` |
| 6.2 write | `proxy.statement` | `classify`, `adapter.snapshot_read` or `engine.view`, `overlay.append`, `evidence.append` |
| 6.3 propose | `branch.propose` | `freeze`, `engine.compute` → `read, delta, base, summary, impact, assertions, persist`, `policy.evaluate`, `verdict.record` |
| 6.4 review | `review.decide` | `grant.mint`, `decide_tx` |
| 6.5 merge | `merge.apply` | `lease.acquire`, `staleness_check`, `compensation.compute`, `compensation.persist` → `put, verify, index`, `adapter.apply` (one per chunk), `outcome` |
| 6.6 revert | `merge.revert` → `branch.create` + `branch.propose` | as above |
| 6.8 heartbeat | `heartbeat` | `matrix.decide`, actions |

**Sampling.** 100% for control-plane API operations, heartbeat anomalies, instructions, merges, and reverts; 1% for proxy statements and 100% for statements that end in an error (doc 04 §9); 100% for `ComputeChangeset`. Tail sampling in the collector keeps every trace containing an error span or exceeding its flow's p99 threshold.

**What on-call opens first.** For a slow propose: the `branch.propose` trace, reading the `engine.compute` phase breakdown against doc 05 §7. For a stuck merge: the `merge.apply` trace, checking whether `compensation.persist` completed (committed; keep retrying) or not (safe to return to `proposed`). For a `heartbeat.anomaly`: the heartbeat trace plus the branch's last `merge.apply` trace.

## 6. Dashboards

| Dashboard | Scope | Panels |
|---|---|---|
| Platform | Global control plane | API p50/p99 and 5xx by route; S3 and S7a burn; `steward_pg_unavailable`; Ecto p99; Oban depth and oldest age per queue; transitions by `from,to,outcome`; `steward_genservers_total` vs non-terminal rows; heartbeats/s by result and rate-limit rejections; `steward_plane_sessions` per data plane; boundary rejections (S9) |
| Data plane | One per customer; also rendered from the customer's Prometheus with the same JSON | S1, S2 histograms; `proxy_statements_total` by `code`; connections and routed branches vs ceilings; overlay roll lag; `engine_changeset_duration_seconds` by phase and bucket vs doc 05 §7 lines; `engine_failures_total` by code; compaction lag; DuckDB high-water; adapter call latency and errors by code; pool wait; quota remaining; compensation persist p99 and share-of-merge; `compensation_corrupt_total` (S8) |
| Review loop | Per org and per target | `steward_queue_depth` trend; verdict mix stacked (`auto-merge` / `hold` / `block`) with the 80% line; `steward_held_over_7d`; median time-in-queue from `review_facts.held_seconds`; propose-to-verdict wall clock by bucket; `steward_partial_compensation_ratio`; reverts per week; reviewed changesets per month (billing) |
| Policy health | Per target | `steward_policy_error_total` rate; `steward_policies_broken_total`; per-assertion fire rate from the analytics store (fires on 100% or 0% of changesets flagged, doc 06 §9); `steward_evaluate_duration_seconds` by phase; re-evaluation jobs; assertion timeouts and budget exhaustion |
| Capacity | Global + per data plane | Postgres size and partition growth (`events` ~10 GB/month at 1M branches, doc 07 §7), disk at 70%; Oban depth; GenServer count and BEAM memory vs the 500 MB / 100k estimate; DuckDB memory vs 8 GiB; engine disk free; segment and row-delta cache fill; compensation bytes and volume ratio; proxy memory per branch vs 256 MB |

## 7. Alerts

### 7.1 Paging set (Steward on-call), nine conditions

| # | Alert | Condition | For | Sev | Runbook |
|---|---|---|---|---|---|
| 1 | `HeartbeatAnomaly` | `increase(steward_heartbeat_matrix_total{action="alert"}[5m]) > 0` | 0 | 1 | `runbooks/heartbeat-anomaly.md`: never auto-repair (doc 13 §6.8); freeze branch, inspect last merge trace |
| 2 | `CompensationCorrupt` | `increase(steward_plane_compensation_status_total{status="corrupt"}[5m]) > 0` | 0 | 1 | `runbooks/compensation-corrupt.md`: S8; record stays `corrupt`, never GC'd (doc 09 §6) |
| 3 | `BoundaryRejection` | `increase(steward_boundary_rejections_total[5m]) > 0` | 0 | 1 | `runbooks/boundary.md`: S9; identify the producer from `site` and the trace; a rejection means a bug tried to move row data |
| 4 | `MetadataPostgresDown` | `steward_pg_unavailable == 1` | 1 min | 1 | `runbooks/postgres-failover.md`; heartbeats are answered `stale: true` meanwhile (doc 07 §6) |
| 5 | `MergeStalled` | `merge.stalled` event, or a `merging` branch with `heartbeat_lost`, or `steward_lease_expired_total` increase with a `pending` merge | 0 (events are already 1 h stalled per doc 13 §6.5) | 2 | `runbooks/merge-stalled.md`: check `compensation_persisted`; human may force revert, **must not** mark applied by hand (doc 13 §6.5); never clear the lease (doc 07 §5.4) |
| 6 | `DataPlaneDisconnected` | `steward_plane_sessions == 0 and steward_branches_nonterminal > 0` | 10 min | 2 | `runbooks/data-plane-disconnected.md`; agents keep writing (invariant 15); only proposes and merges wait |
| 7 | `ApiBudgetFastBurn` | S7a or S3 burn rate > 14.4× over 1 h and 5 min | 2 min | 2 | `runbooks/api-latency.md` |
| 8 | `ObanCriticalBacklog` | `oban_jobs_oldest_age_seconds{queue=~"evaluate\|merge\|reconcile"} > 600` | 5 min | 2 | `runbooks/oban.md`; checkpoints are synchronous so correctness is safe (doc 07 §6) |
| 9 | `UnreviewedMergeInvariant` | S10 weekly job returns > 0 | 0 | 1 | `runbooks/unreviewed-merge.md`: doc 01 §10 incident; post-mortem mandatory |

Paging is through the on-call rota; severity 1 wakes someone, severity 2 pages in business hours and tickets otherwise.

### 7.2 Rules shipped in the Helm chart (customer's on-call; Steward sees the symptom via the stream)

`ProxyUnready` (`SD007` ratio > 1% for 2 min), `OverlayVolumeUnavailable`, `RoutingStoreCorrupt` (doc 04 §6), `OverlayRollLag > 15 min`, `UnclassifiableStatements > 0`, `EngineDiskFree < 10%`, `CompensationVolume > 80%`, `CompensationCorrupt > 0`, `ChainVerifyFailure > 0`, `AdapterQuotaLow < 10%` (Salesforce), `DuplicateAdapterHost` (doc 08 §6). The chart exposes a webhook so the customer may forward these to Steward support; forwarding is opt-in (doc 14).

### 7.3 Ticket set

Slow burn on S1–S7; `steward_policy_error_total` > 1% of verdicts over 1 h (doc 06 §9); evaluate control p99 > 500 ms; `adapter_pool_wait_seconds` p99 > 1 s; compaction lag > 10 min; weekly `CounterRebuild` drift ≠ 0; `events` disk > 70%; GenServer count ≠ non-terminal rows after the sweep; heartbeat rate-limit rejections > 5% for 15 min; `heartbeat_lost` rising on `open` branches of one data plane.

### 7.4 Explicit non-alerts

`steward_queue_depth`, `steward_auto_merge_ratio`, `steward_held_over_7d`, `steward_partial_compensation_ratio` (product metrics: customer-success conversation, Review-loop dashboard); `proxy_freeze_rejections_total` (expected: agents hitting a frozen branch); `SD002` within 60 s of create (repaired by heartbeat, SDK retries); `proxy_heartbeat_age_seconds` up to 60 s (backoff is normal); `heartbeat_lost` on an `open` branch (doc 13 §6.8); `engine_sql_timeouts_total` (customer SQL, surfaces as `policy_error` verdicts in the queue).

## 8. The three signals, consolidated

| Component | Signal 1 | Signal 2 | Signal 3 | Source |
|---|---|---|---|---|
| Write proxy | `proxy_statement_duration_seconds` p99 pass-through | `proxy_statements_total{outcome="error"}` by code | `proxy_heartbeat_age_seconds` | doc 04 §9 |
| Changeset engine | `engine_changeset_duration_seconds` p95 by bucket vs doc 05 §7 | `engine_failures_total` by code | `engine_compaction_lag_segments` | doc 05 §9 |
| Policy engine | policy error rate | `steward_evaluate_duration_seconds{phase="data"}` p99 | held-queue trend per target | doc 06 §9 |
| Control plane | `steward_heartbeat_lag_seconds` and `heartbeat_lost` count | Oban depth and oldest-job age | transition error rate by type | doc 07 §9 |
| Adapters | `adapter_errors_total` by code (`SNAPSHOT_LOST`, `RATE_LIMITED`, `AUTH_FAILED`) | `adapter_apply_in_progress` flat | `adapter_quota_remaining` (Salesforce) | doc 08 §9 |
| Compensation log | `compensation_corrupt_total` | `compensation_persist_seconds` p99 | `compensation_partial_ratio` | doc 09 §9 |

The Platform dashboard's first row is the control-plane and policy rows; each Data-plane dashboard's first row is the other four.

## 9. Customer-facing observability

What a target admin sees on the target settings page and the queue header (doc 07 §5.6), all computed in the control plane from metadata:

| Item | Shown as | Computed from |
|---|---|---|
| Queue trend | 30-day sparkline, current depth | `counters.queue_depth{target}` |
| Verdict mix | stacked 30-day bar, auto-merge % with the 80% marker | `changesets_by_verdict{target, verdict, day}` |
| Held > 7 days | count, link to the oldest | `counters.held_over_7d{target}` |
| Heartbeat status | "N branches, last heartbeat X s ago, M lost" | `last_heartbeat_at`, `heartbeat_lost` on branches |
| Data-plane version | component versions, "update available" if behind | `steward_plane_version` (**New**, §3.4) |
| Merge progress | "412 of 1,000 rows applied", retry-after for rate limits | heartbeat `merge_progress` (doc 13 §6.5) |
| Compensation partial ratio | 24 h ratio with an explanation link | `steward_partial_compensation_ratio{target}` |
| Broken policies | count, link to each | `steward_policies_broken_total{target}` |
| Base snapshot age (fallback substrate only) | age of the pinned LSN | `OverlayInitialised.opened_at` (doc 08 §11) |

**Health summary per target**, one of `healthy | degraded | unavailable`, evaluated every minute by an Oban job and stored on the `targets` row (**New** column `health`, `health_reasons jsonb`):

- `unavailable` if the data plane has no `Session` stream for > 10 min, or the target's last `describe()` failed, or any `merging` branch has `heartbeat_lost`.
- `degraded` if any of: > 0.5% of non-terminal branches stale > 60 s (S5 breached); last merge on the target `failed` with a non-`stale_base` reason; `steward_policies_broken_total > 0`; partial ratio > 10% over 24 h; `held_over_7d > 0`; data-plane version more than one minor behind.
- `healthy` otherwise.

**API.** `GET /v1/audit-events` (doc 10 §4) already exposes the event stream. **New:** `GET /v1/targets/{id}/health` → `{status, reasons[], as_of, heartbeat: {branches, stale, lost, last_at}, queue: {depth, held_over_7d, auto_merge_ratio_30d}, merge: {last_merge_id, last_status, in_progress?: {rows_confirmed, rows_total, retry_after?}}, compensation: {partial_ratio_24h}, policies: {broken}, data_plane: {connected, versions{}}}`, capability `any on target`; `as_of` honours doc 03 principle 8 (the view may lag one heartbeat). **New:** the webhook type `target.health_changed` (doc 10 §6) fires on a status change. Per-data-plane SLO attainment (S1, S2, S4–S8) is shown on the same page from the control plane's derived metrics; raw histograms stay in the customer's Prometheus.

## 10. Load testing

`tools/loadgen` is the realistic agent write-pattern generator required by doc 03 principle 9. It consumes synthetic datasets from `tools/fixtures` and drives them through the replay harness doc 04 §10 names `tools/replay`; **decision:** `tools/replay` becomes the `loadgen replay` subcommand so there is one tool. It speaks the Postgres wire protocol through real drivers (the doc 04 §10 matrix) and the SDK (doc 11), so it exercises the same path agents do. Datasets are synthetic only (doc 18 §7).

| Scenario | Shape | Measures | Pass criteria |
|---|---|---|---|
| A. Bursty bulk updates | 50 branches, each: heavy reads then 500 single-row `UPDATE`s in a loop, then one 20k-row transaction, propose | S1, S2, overlay throughput (2,000/s single, 20,000/s batched), `view()` p99, S4 at 10k–100k | doc 04 §7, doc 05 §5.5 and §7 |
| B. Many small branches | 1,000 branches created in 60 s, 100 rows each, all proposed within 5 min; data-plane restart mid-run | S3, heartbeat storm handling (token bucket, doc 07 §5.3), heartbeat p99 ≤ 20 ms, boot sweep, S5, Oban age | doc 07 §7 |
| C. One 10M-row overlay | one branch, `INSERT ... SELECT` of 10M rows, propose, approve, merge, revert | S4 at `10m`, DuckDB high-water ≤ 8 GiB, compaction, chunked apply (10k-row chunks, doc 08), compensation persist share < 20%, S6 | doc 05 §7 (promotes the 10M estimate to a requirement), doc 09 §7 |
| D. Control-plane outage | Scenario A with the control plane stopped for 10 min mid-run | zero failed reads or writes on `open` branches; proposes queue and complete on reconnect | doc 13 invariant 15 |
| E. Policy load | 1,000 changesets × 200 active policies | evaluate control p99 < 500 ms | doc 06 §10 |

**Gates.** On every PR to `proxy/` or `engine/`: the `benches/` suites (connect, classify, pass-through read, single-row write, merged read, `view()`, compute at 1k/100k/1M, compensation at 1k/100k) with no regression over 5% against `main` (doc 18 §3). Nightly: scenarios A–E against the local stack (`tools/stack up`, doc 18 §8) with the §2 targets as pass criteria; a failure blocks the next release train. Before a milestone that changes a §2 number: the scenario on a reference data-plane node (8 vCPU, 32 GiB, doc 05 §7). Doc 17 owns the schedule and the CI wiring.

## Alternatives considered

- **Datadog for everything.** One vendor, agents everywhere, fast to start. Rejected for the control plane: per-host and custom-metric pricing punishes exactly the cardinality we need (per-target metrics across many customers), and we cannot ask customers to run a Datadog agent in their account. Chosen: Prometheus + Grafana + Tempo + Loki, fed through an OpenTelemetry Collector, self-hosted on Steward's Kubernetes (doc 14). The data plane emits OTLP (metrics, logs, traces) to a collector endpoint the customer configures plus a Prometheus `/metrics` scrape endpoint, so it works with Datadog, Grafana Cloud, or anything else the customer runs; the chart ships Grafana dashboard JSON and Prometheus rules as the reference. Revisit a managed Grafana Cloud backend when operating Loki becomes a distraction.
- **Forwarding raw data-plane metrics to Steward.** Would give Steward complete visibility. Rejected: a second cross-boundary channel to audit (doc 15), and most of it is derivable from the `Session` stream, which is already the audited contract. The §3.4 `steward_plane_*` metrics are that derivation. A **New** `DataPlaneTelemetry` message is listed in §12 if the derived view proves insufficient.
- **SLO on customer-visible propose-to-verdict wall clock.** Honest, but dominated by customer SQL and target latency we do not control; it would be breached by a slow Snowflake warehouse. Reported, not promised (S4 excludes customer SQL).
- **Paging on queue depth.** Doc 01 §9 calls queue size a health metric; it is the customer's health, not ours. Tickets to customer success instead.
- **`branch_id` as a metric label** (doc 04 §9). Rejected: thousands of short-lived series per data plane per hour; per-branch facts are in the heartbeat, logs, and traces.

## Open questions

| Question | Owner | Needed by |
|---|---|---|
| `trace_context` field on `Instruction`, `InstructionResult`, `ChangesetReport`, `MergeOutcome`, and a `version` field on `DataPlaneMessage`: amend doc 10 §5 (`contracts/` change, doc 18 §5) | Control plane lead | Doc 10, before M0 |
| `impact_ms` and `assertions_ms` on `changeset_facts`; `health`, `health_reasons` on `targets`: amend doc 12 | Architecture | Doc 12 |
| `GET /v1/targets/{id}/health` and the `target.health_changed` webhook: add to doc 10 | Control plane lead | Doc 10, before M0 queue UI |
| Does any data-plane telemetry beyond the stream-derived view cross to Steward (a `DataPlaneTelemetry` message with a fixed, audited field list)? | Founding team, doc 15 owner | Doc 15 |
| Are per-data-plane SLO numbers contractual (a published SLA) or informational in M0? Affects whether S1–S8 appear in the health API | Founding team | Before first contract |
| Log retention: 30 days hot / 1 year cold is a guess; compliance customers may require longer for `audit_log` exports (doc 12 §12) | Doc 15 owner | Doc 15 |
| Per-target `heartbeat_lost` threshold for rate-limited CRM targets (doc 13 §12, doc 07 §12) changes S5 and alert 5 for those targets | Control plane lead | Doc 08 |
| Customer forwarding of chart-shipped alerts to Steward support: webhook format and whether it is on by default | Infrastructure lead | Doc 14 |
| Should `steward_assertion_results_total` stay a Prometheus metric with `policy_id` bounded to the active set (≤ 500 per target, doc 06 §7) rather than move to the analytics store? | Control plane lead | Doc 17 |
