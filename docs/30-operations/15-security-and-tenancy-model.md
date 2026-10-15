# 15 — Security and tenancy model

**Status:** Draft
**Owner:** Founding team
**Last updated:** 2026-10-15

Steward's security story is the plane boundary of doc 03 §2: row data stays in the customer's cloud, the control plane holds metadata, and the inter-plane wire contract (doc 10 §5) cannot carry a row. This document states that boundary as invariants, consolidates what the component specs (docs 04–09 §8) and contracts (docs 10, 12, 13) already say about identity, authorisation, tenancy, data handling, logging, customer-authored SQL, audit, and compliance, and decides the questions those specs left to this one. Infrastructure mechanics (enrolment, secret stores, network policy, KMS) belong to doc 14, written in parallel and referred to by number.

## 1. Threat model

### 1.1 Assets

| Asset | Where it lives | Sensitivity |
|---|---|---|
| Target row data (base snapshot reads, overlay images, row deltas, assertion samples, conflict rows) | Data plane only (doc 13 invariant 9) | Highest: production data |
| Before-images in compensation records | Customer object store, compensation prefix (doc 09 §8) | Highest: includes rows a merge deleted |
| Target credentials | Customer's data-plane secret store; resolved only by the adapter host (doc 08 §5.5, §8) | Highest: write access to the system of record |
| Evidence (statement fingerprints, rows-read counts, per-statement rationale) | Data plane evidence log (doc 04 §5.5) | High: reveals what an agent queried |
| Policies (YAML + SQL), impact queries | Control-plane Postgres, pushed to data plane | Medium: customer IP; the rules that gate writes |
| Audit log, events, reviews, verdicts | Control-plane Postgres, append-only (doc 12 §2.5) | Medium: integrity matters more than confidentiality |
| API keys, grant JWTs, mTLS keys, export signing key | See §2.5 | Highest while valid |
| Changeset summary and impact | Control-plane Postgres | Low-medium: aggregates; `distinct_values` only by allow-list (doc 05 §5.2) |

### 1.2 Actors

| Actor | Capability assumed | What the design concedes | What it denies |
|---|---|---|---|
| Malicious or compromised agent | Valid `stw_` key; arbitrary SQL on its branch | Overlay of its own branches; reads of its base snapshot; evidence it fabricates | Writing to the target directly; writing to another principal's branch (doc 13 §7); editing the policy that gates it (doc 06 §8); approving its own changeset (doc 07 §5.5) |
| Malicious insider at the customer (human with memberships) | SSO identity; reviewer or admin rights | Approving a held changeset they are entitled to approve | Overriding `block` (doc 13 invariant 12); self-approval; silently editing audit rows (§9) |
| Compromised control plane | Full read of metadata; ability to send any `Instruction` | Metadata disclosure; sending merge instructions for evaluated changesets | Reading any row (no message can carry one); executing SQL outside the sandbox (the validator runs again in the data plane, doc 06 §8); obtaining target credentials (never present) |
| Steward employee | Operator access to the control plane | Same as above, plus support tooling | Same as above; every operator action is an `audit_log` row (§9) |
| Network attacker | On-path between agent and proxy, or between planes | Nothing: TLS to the proxy, mTLS between planes (doc 03 §8, doc 04 §8) | Replaying a grant (`jti`, 5 min) or heartbeat (mTLS identity) |
| A second tenant | Own org's credentials | Timing and shared-infrastructure observation (§4.3) | Any read or write across `org_id` (§4.1) |
| Compromised proxy process | Data-plane memory | Overlays, evidence, snapshot-scoped read credentials (doc 04 §8) | Primary target credentials; the compensation signing key |

### 1.3 Security invariants

Restating doc 03 §2 as invariants that tests enforce (§12):

1. **Row data never crosses the boundary.** No field in `steward.plane.v1` (doc 10 §5) or in `/v1` REST responses served by the control plane can carry a row, a key, or a value, except `distinct_values` under the per-column allow-list (doc 05 §5.2). Enforced by protobuf shape, Ecto embedded schemas rejecting unknown keys (doc 07 §8), `validate_boundary_json()` (doc 12 §2.4), and the 1 MiB message cap (doc 10 §5).
2. **The control plane never holds target credentials.** It holds `credential_ref` URIs only (doc 08 §5.5). The adapter host is the only process that resolves them.
3. **The data plane never dials out except to an allowlist:** the control plane's gRPC host on 443 (one egress rule, doc 10 §5), the targets, the customer's object store and secret store (doc 08 §3.2). The proxy opens no network connection outside the customer's cloud (doc 04 §3.2). Doc 14's network policy enforces this.
4. **The data plane never advances branch state on its own** (doc 13 §1); every transition is a control-plane transaction with an event.
5. **A merge never applies without a persisted compensation record** (doc 13 invariant 7).
6. **Customer SQL runs only in the data-plane sandbox** (§6); the control plane parses it but never executes it against data.

## 2. Identity and authentication

### 2.1 Principals

Principals are `agent`, `human`, or `service` (doc 02, doc 12 §2.1). A principal belongs to exactly one org.

| Principal kind | Credential | Where verified | Lifetime |
|---|---|---|---|
| Agent, service | API key `stw_<prefix>_<secret>` (doc 10 §3.1); 256-bit random secret, stored as `secret_sha256` (doc 12 §2.2) | Control plane for REST; proxy via SCRAM-SHA-256 with the key as the password (doc 04 §3.1), against the routing store's `api_keys` table pushed by `RoutingUpsert` | `expires_at` optional; **should** be ≤ 1 year; revocation reaches the proxy on the next `RoutingUpsert` or heartbeat (≤ 60 s) |
| Human | SSO session (Phoenix encrypted cookie, doc 07 §8); optional `stwt_` token, 1 h, not renewable (doc 10 §3.2) | Control plane | Session 12 h idle, 7 days absolute; `stwt_` 1 h |
| Data plane | mTLS client certificate; SAN = `data_plane_id` (doc 10 §3.4) | Control-plane gRPC host | 90 days, auto-renewed at ⅔ lifetime (doc 14) |
| Reviewer's browser → data plane | Row-delta grant JWT (ES256, 5 min, doc 07 §5.6) | Data-plane grant endpoint | 5 min, single changeset or merge, single action |
| Control plane → data plane (instructions) | The mTLS session the data plane opened (doc 10 §5) | Both ends | Per stream |

**Decision: API-key hashing has no per-deployment salt.** Doc 04 §8 and doc 12 §8.6 specify `SHA-256(salt || secret)` in the routing store, while doc 07 §8 and doc 12 §2.2 store unsalted `SHA-256(secret)` and `RoutingUpsert.api_keys[].key_hash` carries that hash downward. The control plane sees the secret once and cannot compute a hash under a salt it does not hold; a 256-bit random secret gains nothing from one. `key_hash = SHA-256(secret)` in both planes; `meta.salt_id` in doc 12 §8.6 is dropped.

**Decision: SSO providers for M0 are generic OIDC, Google Workspace, and Okta** (resolving doc 07 §12); generic OIDC covers Entra ID with manual configuration. SAML is M1, gated on the first customer that cannot do OIDC. Humans are matched by `sso_subject` (doc 12 §2.1), never by email alone. JIT provisioning creates the principal with no memberships.

### 2.2 Row-delta and export grants

Claims are exactly doc 07 §5.6 and doc 10 §3.3: `iss`, `aud` = `data_plane_id`, `sub`, `org`, `cs` (or merge id), `scope` ∈ `row_delta:read | compensation:read | compensation:export:<target_id>`, `jti`, `exp` = iat + 5 min. The data plane verifies signature, `aud`, `exp`, scope-to-path match, and rejects a `jti` seen before within the validity window (replay cache, 10 min). Issuance is an `audit_log` row `grant.issued` (doc 12 §2.5); every use is a `DataPlaneAuditEvent` on the session (doc 10 §5) that becomes a `row_delta.read` / `compensation.*` row. A grant is minted only for a principal with `review:read` on the target, or `target:admin` for export.

### 2.3 Key and certificate rotation

| Key / cert | Owner | Where | Rotation | Overlap |
|---|---|---|---|---|
| Grant signing key pair (ES256) | Control plane | Control-plane secret store; public key pushed in data-plane configuration (doc 07 §5.6) | 90 days | 24 h: data plane holds current + previous public key |
| Data-plane mTLS client cert | Data plane (doc 14 enrolment) | Data-plane secret store | 90 days | Renewed at day 60; old cert valid until expiry |
| Control-plane gRPC server cert | Control plane | Public CA | 90 days (ACME) | Standard |
| Proxy TLS server cert (agents connect with `sslmode=require`) | Customer (doc 14) | Data-plane secret store | Customer's policy; **should** be ≤ 1 year | Hot reload |
| Agent/service API keys | Customer `org_admin` | Control plane (hash), routing store (hash) | **Should** be ≤ 1 year; `expires_at` surfaced in the UI 30 days before | Create new, update agent, revoke old; both valid during the overlap |
| Target credentials (`steward_adapter` role etc.) | Customer | Data-plane secret store | Customer's policy; host picks up rotation within 60 s (doc 08 §5.5) | 30 s pool drain (doc 08 §5.5) |
| Snapshot-scoped read credentials | Adapter | Minted per snapshot (doc 08 §5.1) | Expire with branch TTL | None; dropped at `closeSnapshot` |
| Export signing key (Ed25519) | Data plane | Data-plane secret store; public key registered at enrolment (doc 09 §3.2) | 1 year | Old public key retained by the control plane forever, so old manifests verify |
| Webhook HMAC secrets | Customer | `webhooks.secret_ciphertext`, Cloak-encrypted (doc 12 §2.2) | Customer-initiated | Two secrets accepted for 24 h after rotation |
| Cloak (column encryption) key | Control plane | Control-plane secret store | 1 year | Cloak re-encrypt job |
| Phoenix session signing/encryption salts | Control plane | Release config | 180 days | All sessions invalidated at rotation; announced |

## 3. Authorisation

### 3.1 Two vocabularies, one model

Humans hold **membership capabilities** on `target_memberships`: `reviewer`, `policy_admin`, `target_admin` (doc 07 §8, doc 12 §2.1 enum), plus `org_admin` on the principal. API keys hold **scopes** in `resource:verb` form (doc 10 §3.1). The mapping in doc 10 §3.1 is normative: `reviewer` = `review:read` + `review:decide` + `changeset:read`; `policy_admin` = `policy:*`; `target_admin` = `target:admin` + everything above. Every capability check in the control plane resolves to the scope vocabulary, so one function (`Steward.Authz.allowed?/3`) answers both.

**Decision: humans have no draft-only policy capability in M0.** `policy_admin` covers save, test, activate, and retire. A human who should draft but not activate is served by a service key with `policy:write` and no `policy:admin`. Revisit if a customer asks (open question).

### 3.2 Operation matrix

`A` = agent key, `S` = service key, `R` = `reviewer`, `P` = `policy_admin`, `T` = `target_admin`, `O` = `org_admin`. Scopes follow doc 10 §4; an agent key **must not** carry `review:decide`, `policy:write`, `policy:admin`, or `merge:revert` in M0 (doc 06 §8, doc 10 §3.1, doc 13 §6.6), enforced at key creation and by the `target_memberships` trigger (doc 12 §2.1).

| Operation (doc 10) | A | S | R | P | T | O | Extra rule |
|---|---|---|---|---|---|---|---|
| Create branch, write via proxy, withdraw, abandon own branch | ✓ | ✓ | — | — | ✓ | — | Owner only (doc 13 §7); `target:admin` may abandon any |
| Propose | ✓ | ✓ | — | — | — | — | Owner only |
| Get branch / changeset / verdict / merge | ✓ | ✓ | ✓ | ✓ | ✓ | — | `distinct_values` returned only with `review:read` (decided, §5) |
| List queue; mint row-delta grant | — | S with `review:read` | ✓ | — | ✓ | — | Grant logged |
| Approve / reject | — | — | ✓ | — | ✓ | — | Not the owning principal (`self_approval`); never on `block` (`verdict_block`) |
| Save policy version, tests, validate | — | `policy:write` | — | ✓ | ✓ | — | Static check at save |
| Activate / retire policy | — | `policy:admin` | — | ✓ | ✓ | — | §3.3 separation rule |
| Impact queries write | — | `target:admin` | — | — | ✓ | — | Static check |
| Target settings, memberships, retention, legal hold | — | `target:admin` | — | — | ✓ | — | `legal_hold.set/cleared` audited |
| Revert | — | `merge:revert` | — | — | ✓ | — | Agents never in M0 |
| Register target | — | `target:admin` | — | — | ✓ | — | Needs a data plane the org owns |
| Principals, API keys | — | — | — | — | — | ✓ | Secret shown once; `api_key.created/revoked` audited |
| Audit events read | — | `audit:read` | — | — | ✓ | ✓ | Scoped to org; target filter honours memberships |
| Webhooks | — | `webhook:admin` | — | — | — | ✓ | HTTPS only (doc 12 §2.2) |
| Compensation export | — | `target:admin` | — | — | ✓ | — | Grant `compensation:export:<target_id>`; manifest hash audited |

### 3.3 Separation of duties

- **Self-approval is refused** with `self_approval` (doc 07 §5.5), compared on principal id. A service principal that owns a branch cannot approve it even if it also holds `review:decide`.
- **Agents cannot hold `policy_admin` or `target_admin`** in M0 (doc 06 §8, doc 12 §2.1 trigger). The failure mode the product exists to prevent is an agent editing the gate in front of it.
- **Policy activation by a different principal than the author. Decision:** when `target_settings.separate_approval = true` (default, doc 12 §2.2) and the target has ≥ 2 principals holding `policy_admin`, `activate` **must** be called by a principal other than `policy_versions.saved_by`, else `409 policy_activation_refused` with `details.reason = self_activation`. With one `policy_admin`, self-activation is allowed and `policy.activated` carries `details.self_activated = true`, so a one-DBA customer is not blocked and the exception is visible to an auditor. Doc 13 §5's edit-related use of `separate_approval` is out of M0; this is the setting's M0 meaning.
- **One writer per branch** (doc 13 §7): the proxy compares `routing.principal_id` to the SCRAM-authenticated principal and reports a mismatch as `28P01`, never as "not yours", so branch ids cannot be probed (doc 04 §5.1). The API checks ownership on propose, withdraw, abandon.
- **Operator actions** (Steward staff) use a `service` principal in the customer's org, created and revoked per support engagement, audited like any other. There is no superuser path in the application.

## 4. Tenancy

### 4.1 Control plane: logical isolation by `org_id`

Doc 12 §10 is restated and extended:

1. Every table except `orgs`, `oban_jobs`, `schema_migrations` carries `org_id NOT NULL`; cross-org FKs are composite on `(org_id, id)`; `Steward.Repo.prepare_query/3` raises `MissingOrgScope` on an unscoped query unless tagged `skip_org_check: true` (allowed only in `steward_jobs` system scans, each reviewed).
2. **Row-level security is not in M0** (doc 12 §10). Compensating controls: (a) the `prepare_query` guard; (b) `Steward.Schema.OrgIdTest` and the migration test (doc 12 §10); (c) an integration test that creates two orgs, exercises every `/v1` endpoint as org A against ids belonging to org B, and asserts `404 not_found` on every call (doc 10 §2.1: never distinguishes absent from foreign); (d) a CI grep that fails on `skip_org_check` outside `steward_jobs`. RLS is the M1 migration described in doc 12 §10 and **must** land before the first enterprise security review.
3. `404` for foreign resources, never `403`, so a tenant cannot enumerate another's ids.
4. Idempotency keys, rate-limit buckets, and counters are keyed by org (doc 12 §2.2, doc 10 §2), so one tenant's replay or burst cannot affect another's.

### 4.2 Data plane: physical isolation

One data plane per customer account, in the customer's cloud (doc 03 §2). A data plane has one mTLS identity; the control plane binds `targets.data_plane_id` to the org that enrolled it, and an `Instruction` for a branch is only ever sent on the stream whose SAN equals that target's `data_plane_id`. Two customers never share a proxy, engine, routing store, overlay bucket, or adapter host. Within one customer, targets share a data plane; per-target isolation is by credential (one `credential_ref` per target) and object-store prefix (`steward/targets/<target_id>/`, doc 09 §4).

### 4.3 What a tenant can observe about another

The control plane is shared: one Postgres, one gRPC host, one Oban queue. A tenant can observe aggregate latency (a neighbour's heartbeat storm delays theirs by up to 30 s, doc 07 §5.3) and nothing else; UUIDv7 ids embed a timestamp (doc 10 §2) but resolve to `404` across orgs. Acceptable for M0: no confidentiality-bearing value is shared and latency is bounded by per-identity token buckets.

## 5. Data classification and handling

| Class | May live in | Encryption | Retention (doc 12 §9) | Who may read | Logged? |
|---|---|---|---|---|---|
| Row data (snapshot reads, overlay, row delta, samples, conflict rows) | Data plane only | Object store SSE with customer-managed key (doc 09 §8; doc 14); local volume encryption per doc 14 | Overlay 7 d after terminal; row delta with overlay | Owning principal via proxy; reviewer under grant | Never |
| Before-images (compensation bodies) | Customer object store, compensation prefix | SSE-KMS, customer key; header overwrite denied (doc 09 §8) | 90 d, ≥ `revert_window`; legal hold extends | Merge worker; grant holders; every read audited | Never |
| Compensation headers (counts, hashes, chain) | Object store; metadata mirror in control plane | As above / Postgres at rest | Permanent (doc 09 §5.5; confirmed §9) | Any `changeset:read` on the target | Hashes and counts only |
| Changeset summary and impact | Control-plane Postgres | Postgres at rest (doc 14) | Indefinite | `changeset:read`; `distinct_values` needs `review:read` | Counts only; never `distinct_values` |
| Evidence statement fingerprints, rows-read counts | Data plane evidence log | Volume encryption | Follows compensation (merged) or overlay | Reviewer under grant | Fingerprint hash only |
| Rationale (per-statement and propose-time, ≤ 4 KiB) | Per-statement: data plane; propose-time: control plane `changesets.evidence.rationale` | As host | With the changeset | `changeset:read` | Never |
| Policies, impact queries (SQL) | Control-plane Postgres; pushed to data plane | Postgres at rest | Versions never deleted (doc 06 §5.2) | `policy:read` | **Never** (decided: doc 07 §8 wins over doc 06 §8's debug allowance); version id only |
| Audit log, events, reviews, verdicts | Control-plane Postgres, append-only | Postgres at rest | Audit 2 y default (§9); events 90 d after export | `audit:read`; `review:read` | Ids and action names only |
| Credentials and keys | Secret stores per §2.3 | Secret store native | Per §2.3 | Processes named in §2.3 | Never |
| Billing meters and analytics facts | Control plane; analytics store | At rest | 13 months | `org_admin`; Steward billing | Counts only |

**Decision (doc 10 §10):** `GET /v1/changesets/{id}` and the LiveView detail page include `distinct_values` only when the caller holds `review:read` on the target; agent keys with `changeset:read` receive counts only. The allow-list `summary_values_allowed` stays empty by default (doc 05 §5.2).

### 5.1 The never-logged list

Consolidated from doc 04 §8, 05 §8, 06 §8, 07 §8, 08 §8, 09 §8, 11 §8.3, 18 §2. At any log level, in any plane, including exception messages, gRPC status details, metric labels, and trace attributes:

| Item | Source |
|---|---|
| Statement text with literals; bind parameter values; result rows | doc 04 |
| Row values, key values, sample keys, before/after images, partial-key lists | docs 05, 06, 09 |
| DuckDB error messages before scrubbing | doc 05 |
| API key secrets, `stwt_` tokens, grant JWTs, connection strings | docs 04, 07 |
| Target credentials, including inside wrapped exception messages | doc 08 |
| `steward.rationale` values and propose-time rationale | docs 04, 07, 11 |
| Policy and impact-query SQL bodies | doc 07 (overrides doc 06) |
| `events.payload`, `audit_log.details` contents | doc 07 |
| Policy test fixture rows (synthetic, but the habit matters) | doc 06 |
| Export destination paths that embed row data | doc 09 |

**Enforcement.** (1) Each plane logs structured JSON through one logging module per language that accepts only a fixed set of field names; `message` is a template with no interpolation of request data. (2) A denylist of field names (`sql`, `statement`, `text`, `rows`, `row`, `values`, `value`, `key`, `keys`, `before`, `after`, `secret`, `password`, `token`, `grant`, `rationale`, `credential`) is rejected by the logging module, and a CI test (`tools/logcheck`, doc 18) runs every integration suite with a sentinel-seeded fixture (doc 08 §10's pattern, extended to all planes) and fails on any sentinel in captured logs, traces, or metrics. (3) The OTel exporter drops any attribute whose name is on the denylist.

## 6. Customer-authored code execution

Impact queries and policy assertions are customer SQL executed in the data plane (doc 03 §4, doc 06 §8). The sandbox is doc 05 §8, restated exactly: a dedicated in-memory DuckDB instance per computation with `enable_external_access = false`, `disabled_filesystems = 'LocalFileSystem'`, `autoinstall_known_extensions = false`, `autoload_known_extensions = false`, `allow_unsigned_extensions = false`, `allow_community_extensions = false`, `allow_persistent_secrets = false`, `enable_progress_bar = false`, `memory_limit` (2 GiB per sandbox instance), `threads` (2), `temp_directory` set, then `lock_configuration = true`. Relations (`delta.*`, `before.*`, `after.*`, `summary.*`, `impact.*`, `conflicts.*`) are read-only Arrow/Parquet views registered before locking; no `ATTACH`, `COPY`, or writable table. Every statement **must** be a single `SELECT`, checked by the `sqlparser`-based validator in the engine crate at save time in the control plane *and again* before execution in the data plane (doc 06 §8), so a compromised control plane cannot smuggle SQL past the sandbox.

**Guarantees:** no filesystem, network, or secret access from SQL; no writes; bounded memory and time (assertion 20 s, set budget 60 s, impact 30 s; doc 06 §7, doc 12 §2.2); a runaway statement is interrupted and reported as `error`, never as a pass (doc 05 §6).

**Residual risks:** (1) resource exhaustion inside the limits: a `policy_admin` can make every propose cost 60 s of CPU; mitigated by per-target budgets and `engine_sql_timeouts_total` alerting. (2) Timing side channels between targets of one customer sharing an engine: accepted, same trust domain. (3) DuckDB bugs: mitigated by the double validator, the syscall-trace escape tests (doc 05 §10), and the fuzzing in §12. (4) A `before.*` scan runs against the customer's own target under the read-only snapshot credential; it cannot write.

The proxy's statement classifier is the other place customer SQL meets Steward logic. It fails closed (doc 04 §5.2, §8): parse failure is `SD006`, anything not positively classified is `SD005`, and a false negative on `write` is a release blocker (doc 04 §10).

## 7. Evidence scrubbing

Resolving doc 03 §11's open question. Evidence records (doc 12 §8.8) carry `statement_fingerprint`: the statement with every literal replaced by `$n` and bind values omitted; raw text and parameters are never written anywhere (doc 04 §5.5). What remains identifiable: table and column names, predicate shape (`WHERE email = $1`), function names, and the per-statement rationale. Column names can themselves be sensitive (`ssn`), and rationale is free text the agent controls.

1. Evidence content never crosses the boundary (doc 13 §6.2): the control plane receives `query_count`, `tables_read`, `evidence_gap`, `refs {path, digest}`, and the propose-time rationale (doc 10 §4.3). `tables_read` is schema metadata already in `adapters.catalog`.
2. The per-statement rationale stays in the data plane and is shown only under the row-delta grant.
3. **New per-target setting `evidence_statement_capture: fingerprint | none`** (default `fingerprint`). With `none`, the proxy leaves `statement_fingerprint` and `fingerprint_hash` empty and keeps `tables`, counts, timing, and rationale. Added to `target_settings` (doc 12 §2.2 amendment); changes are `target_settings.changed` in the audit log.
4. Errors returned to agents never echo literals (doc 04 §5.2); DuckDB messages are scrubbed before crossing the boundary (doc 05 §8).

## 8. Supply chain and build

- **Signed images.** Every image (`steward-proxy`, `steward-engine`, `steward-adapter-host`, `steward-control`) is signed with cosign (keyless, Sigstore, CI identity) with an SPDX SBOM attestation. The Helm chart (doc 14) **must** pin digests, not tags; the data-plane admission policy **should** verify signatures.
- **Dependency policy** (doc 18 §5): no non-permissive licences; any new dependency in `proxy/` requires asking first; `cargo deny`, `mix hex.audit`, and Gradle dependency verification run in CI; a known critical CVE fails the build. Lockfiles are committed.
- **Reproducible builds.** Rust binaries: pinned toolchain, `--locked`, `SOURCE_DATE_EPOCH`, `-C strip=symbols`, build container digest in the attestation; CI rebuilds each release once and fails on a differing hash. JVM and Elixir releases follow the same recipe, best-effort.
- **Adapter plugin loading.** The host loads each adapter in its own `URLClassLoader` from a jar named in its config (doc 08 §11). Not a customer-facing surface: config and jars ship inside the signed image, no API or runtime path sets the jar list, and the host filesystem is read-only except temp. A customer-built adapter (M1+) means a customer-built host image, their trust decision.
- **CI** holds no customer data or production credentials (doc 18 §5); fixtures are synthetic (doc 18 §7).

## 9. Audit

**What is recorded.** Every state transition writes `events` in the same transaction (doc 07 §5.7); every access or administrative act writes `audit_log` with the M0 action set of doc 12 §2.5 (`grant.issued`, `row_delta.read`, `compensation.opened/read/exported/verified`, `api_key.created/revoked`, `membership.granted/revoked`, `target_settings.changed`, `legal_hold.set/cleared`, `policy.activated/retired`). Added by this document: `principal.disabled`, `principal.sso_login`, `operator.access` (a Steward service principal created in a customer org), and `self_activated` as a detail on `policy.activated`. Every row carries the acting principal or `system:<job>` (doc 13 invariant 16).

**Immutability.** `events`, `audit_log`, `reviews`, `verdicts`, `verdict_assertions`, `review_features` are `INSERT`/`SELECT`-only for `steward_app`, with a `raise_immutable()` trigger as the second guard and partition drops by `steward_migrator` only (doc 12 §2.5). In the data plane, compensation headers form a per-target SHA-256 hash chain via `prev_hash` (doc 09 §4, §5.2) and the data-plane role may not overwrite `header.json` (doc 09 §8). **Decision (doc 09 §12):** the hash chain is in M0; headers are retained permanently and bodies expire.

**Export for compliance.** Control-plane audit is `GET /v1/audit-events` (doc 10 §4.9) and the webhook stream; M0 also provides `mix steward.audit.export --org --from --to` producing newline-JSON with a SHA-256 manifest for an auditor. Data-plane evidence and compensation export is the signed bundle of doc 09 §5.6. SIEM push (S3/GCS drop, Splunk HEC) is M1.

**Retention (decided; closes doc 12 §9's pending item).** `audit_log` default 2 years, configurable per org between 1 and 7 years (`orgs.audit_retention`, new column); `events` stays at 90 days after export because the analytics facts and `audit_log` carry what compliance needs. Partition drops are monthly.

## 10. Compliance posture

| Item | M0 | M1 |
|---|---|---|
| SOC 2 | Controls documented in this doc and doc 14; evidence collection (access reviews quarterly, change management = PR process of doc 18 §3) starts at M0 launch | Type I report targeted 6 months after the first paying customer; Type II observation window starts immediately after, report 12 months later |
| GDPR | Data residency satisfied by design: row data never leaves the customer's cloud; the control plane region is chosen at org creation (`api.<region>.steward.dev`, doc 10 §2). A DPA template names Steward as processor for metadata (principal names, emails, `sso_subject`, rationale text, summaries) and the customer as controller; sub-processors are the control-plane cloud and the SSO relay only | EU-only control-plane deployment if a customer requires it |
| Customer offboarding (deletion) | Procedure in §10.1 | Automated as one Oban workflow |
| HIPAA | Not in M0; no BAA. The design (row data in the customer's account, encrypted with their key) is compatible, but the control plane's summaries and rationale could contain PHI if a customer puts it there; `summary_values_allowed` and `evidence_statement_capture = none` are the knobs | Evaluate after SOC 2 Type I |
| Pen test | Before GA (§12) | Annual |

### 10.1 Customer offboarding procedure

1. `org_admin` or Steward support (audited as `operator.access`) sets `orgs.archived_at`; all API keys are revoked and SSO logins refused.
2. Every non-terminal branch is abandoned with reason `abandoned_by_principal` attributed to `system:offboarding`; pending merges are allowed to complete or are escalated (doc 13 §6.5 failure 10), never cut short.
3. Legal holds are reported to the customer; offboarding **must not** clear them silently; the customer confirms clearing each one (`legal_hold.cleared`).
4. The control plane sets `retention_until = now()` for every compensation record and overlay via `SetRetention`; the data plane GC releases bodies and overlays (doc 09 §5.5, doc 05 §5.7). Headers remain in the customer's bucket; they are the customer's.
5. After the data plane acknowledges (or after 7 days without a heartbeat), the customer uninstalls the Helm release and destroys the Terraform module (doc 14); the data-plane mTLS certificate is revoked.
6. Control-plane metadata purge, 30 days after step 1: all rows with the org's `org_id` are deleted by `steward_migrator` in a reviewed script, except `audit_log` and `events`, which are retained to the end of the org's audit retention with `principals.email`, `display_name`, and `sso_subject` pseudonymised, and then dropped by partition. Analytics facts are deleted from the analytics store. A completion record is sent to the customer.

## 11. Incident response

**Severity levels.**

| Sev | Definition | Response | Examples |
|---|---|---|---|
| 1 | Confirmed or suspected row data outside the customer's cloud; credential compromise; an unreviewed changeset reaching production that policy should have held (doc 01 §10) | Page immediately; customer notified within 24 h of confirmation; written report within 5 business days | Boundary validator fires in production; grant key leaked |
| 2 | Integrity of audit or compensation in doubt; cross-tenant metadata exposure | Page; customer notified within 72 h | `compensation_corrupt_total > 0`; `MissingOrgScope` bypass found |
| 3 | Availability of the control plane; a data plane that cannot merge | Business hours; status page | Postgres failover; expired lease escalation |
| 4 | Hardening finding with no exposure | Tracked issue | Dependency CVE without a reachable path |

**Runbook: suspected row data leak to the control plane.** Detection: `validate_boundary_json()` raising (doc 12 §2.4), an Ecto embedded-schema rejection (doc 07 §8), `steward_plane_oversize_total` rising (doc 10 §5), or a `tools/logcheck` sentinel hit in production logs. Steps: (1) declare Sev 1; (2) identify the sender (`data_plane_id`, `changeset_id`) from the rejection log, which carries ids only; (3) confirm the rejection was total (a rejected insert or message is never partially stored); if a value reached a store, snapshot the affected partition and the log stream, then purge; (4) determine the cause in the engine's summary builder or in a new message field; (5) ship a fix to the engine or validator; (6) notify the customer with the ids, the field, and whether anything was persisted; (7) add the shape to the boundary test corpus (§12).

**Runbook: grant signing key compromise.** Rotate the ES256 key pair immediately with zero overlap (push the new public key only), which invalidates every outstanding grant (≤ 5 min of reviewer disruption); audit `row_delta.read` and `compensation.*` rows for the exposure window and report them to affected customers.

**Runbook: data-plane mTLS key compromise.** Revoke the certificate at the control plane (stream closes with `UNAUTHENTICATED`); the data plane re-enrols (doc 14); branches keep writing throughout (doc 13 invariant 15). Review `Instruction` and `Heartbeat` history for the identity during the window.

**Runbook: API key compromise.** Revoke (`DELETE /v1/api-keys/{id}`); the proxy refuses within one `RoutingUpsert`; abandon the key's open branches; nothing merged without review needs a revert because every merge went through policy, but the customer reviews the key's merged changesets and reverts if needed.

**Runbook: target credential compromise.** Customer rotates in their secret store; the host rebuilds pools within 60 s (doc 08 §5.5); Steward's involvement is confirming `AUTH_FAILED` retries succeeded.

## 12. Security testing

| Test | Where | Gate |
|---|---|---|
| Threat-model review of this document against the shipped components | Each milestone (doc 19) | Milestone exit |
| External penetration test: control plane API and UI, proxy wire protocol, grant endpoint, data-plane egress | Before GA; annual after | GA |
| Proxy classifier property tests and `cargo fuzz` target over SQL grammar; any write-bearing AST classified as non-write fails the build | `proxy/` (doc 04 §10) | Every PR |
| SQL validator fuzzing; corpus of known-bad statements | `engine/` (doc 06 §10) | Every PR |
| Sandbox escape tests with syscall trace | `engine/tests` (doc 05 §10) | Every PR |
| **Boundary test:** for every message in `session.proto` and every JSON schema in doc 12 §5, generate instances from a fixture containing sentinel row values and assert (a) no message type has a `string`/`bytes` field that is not in an allowlist of named id/aggregate fields, (b) `validate_boundary_json()` rejects every sentinel-bearing object, (c) the 1 MiB cap rejects an oversize summary | `contracts/tests`, `control/test` | Every PR; a new proto field fails until allowlisted with a reason |
| Org-isolation tests (§4.1) | `control/test` | Every PR |
| Never-logged sentinel test (`tools/logcheck`) across all integration suites | All planes | Every PR |
| Grant tests: expired, wrong `aud`, wrong scope, replayed `jti` | `engine/tests` (doc 09 §10) | Every PR |
| Separation-of-duties tests: self-approval, agent with admin capability, self-activation with ≥ 2 admins | `control/test` | Every PR |
| Dependency and image checks: `cargo deny`, licence scan, CVE scan, cosign verify of the built image | CI | Every PR; release |

## Alternatives considered

- **RLS in M0.** Rejected per doc 12 §10; the `prepare_query` guard plus tests gives the same guarantee for one connection role. Scheduled for M1 before the first enterprise review.
- **Control plane proxies row data for display under its own auth.** Rejected (doc 03 §2, doc 07 §2): one accidental log line would break the residency promise; the grant costs one browser fetch.
- **Per-customer control planes.** Would remove §4.3's shared-infrastructure observations. Rejected: that is the single-plane cost structure doc 03 §10 rejected, without removing the data-plane deployment.
- **Salted API-key hashes.** Rejected in §2.1: the secret is 256-bit random and the control plane cannot compute a per-data-plane salted hash it must push.
- **Logging policy SQL at debug (doc 06 §8).** Rejected in favour of doc 07 §8: it is customer IP and can name sensitive columns; the version id is enough to find it.
- **Capturing raw statement text as evidence with redaction.** Rejected: fingerprinting at the parser is deterministic; redaction of free text is not.

## Open questions

| Question | Owner | Needed by |
|---|---|---|
| Draft-only policy capability for humans (§3.1): add a fourth membership capability `policy_author` or keep service keys as the answer? | Product | M1 |
| Is a browser-direct fetch to the data plane acceptable to customers' network policies, or do we need a data-plane-hosted viewer frame (doc 07 §12)? Affects the grant endpoint's exposure | Founding team | Before M0 queue UI |
| `audit_retention` per org (1–7 years): confirm the range and whether `events` also needs a per-org override | Founding team | Doc 12 amendment |
| SAML: which customer forces it, and whether to buy (WorkOS-style relay) or build | Founding team | M1 |
| Legal-hold authority: `target_admin` sets it in M0 (§3.2); should clearing require `org_admin` or a second approver? | Product | Doc 10 amendment |
| Object-store object lock on compensation headers as belt-and-braces (doc 09 §12) and the KMS integration per cloud | Infrastructure lead | Doc 14 |
| Customer-built adapters (M1+): image-build model as in §8, or a signed plugin registry? | Adapters lead | M1 |
| SOC 2 auditor selection and whether the control-plane cloud's reports can be inherited for infrastructure controls | Founding team | 3 months after first paying customer |
