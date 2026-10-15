# contracts/

Everything that crosses a process or plane boundary in Steward is defined here and nowhere else (doc 18 §1). `contracts/` is the only directory more than one language directory may depend on.

| File | What | Spec |
|---|---|---|
| `proto/steward/plane/v1/session.proto` | gRPC `Session` stream between a data plane and the control plane (heartbeats, changeset reports, merge outcomes, instructions and their results, data-plane audit events) and the `Enrolment` service. Also the shared enums: `BranchState`, `ChangesetState`, `VerdictOutcome`, `VerdictReason`, `LifecycleReason`, `SnapshotFidelity`. | doc 10 §5, doc 12 §2.1 / §3, doc 13 §2 |
| `openapi/steward-v1.yaml` | OpenAPI 3.1 for the public `/v1` REST API: targets, branches, changesets and grants, reviews, merges and reverts, policies, impact queries, principals and API keys, memberships, audit events, webhooks, data planes; the error envelope and its closed code enum; the webhook delivery payload. | doc 10 §2–4, §6 |
| `reasons.yaml` | Canonical vocabularies: lifecycle reasons (with terminality and source states), domain event types, proxy SQLSTATE codes. Code uses these strings; it never redefines them. | doc 12 §3, §6.1; doc 10 §4.2 |
| `check.sh` | Compiles the protos, validates the OpenAPI document, and checks that `reasons.yaml`, the `LifecycleReason` enum and the OpenAPI enums agree. | — |

Data-plane-local protos (`steward.engine.v1`, `steward.adapter.v1`) and the per-event JSON schemas under `events/` are added by the component that owns them (doc 10 §1) and are checked by the same script.

## How consumers use it

- **Rust (`proxy/`, `engine/`)** — a `build.rs` with `tonic_build::configure().compile(&["steward/plane/v1/session.proto"], &["../contracts/proto"])` (path relative to the crate). `prost` types and `tonic` client/server stubs are generated at build time; nothing is copied into the crate.
- **Elixir (`control/`)** — `protobuf` and `grpc` (elixir-grpc) with `protoc --elixir_out=plugins=grpc:lib/steward_plane -I contracts/proto contracts/proto/steward/plane/v1/session.proto`, wrapped in a mix task so `mix steward.contracts.gen` regenerates `lib/steward_plane/`. Generated modules are checked in and CI diffs them against a fresh run.
- **Java (`adapters/`)** — the `com.google.protobuf` Gradle plugin with `protobuf { protoc { ... } ; plugins { grpc { ... } } }` and `sourceSets.main.proto.srcDir("../contracts/proto")`; the `java_package` option already places the classes under `io.steward.plane.v1`.
- **SDKs (`sdk/python`, `sdk/typescript`, `sdk/mcp`)** — generated from `openapi/steward-v1.yaml`. Hand-written code in an SDK is limited to retry policy (`SD002` for 60 s; 503 with backoff), `Idempotency-Key` generation and connection-string handling (doc 10 §8). The `sqlstates` list in `reasons.yaml` is how an SDK maps a proxy error to a terminal branch state.
- **Everyone** — reason strings, error codes and event names are read from `reasons.yaml` (or the enums that mirror it), never typed by hand.

## Rules

1. **Additive within v1** (doc 10 §2). New optional fields, new endpoints and new enum values (only where a field is documented as open) are fine. Removing or changing the meaning of a field, renumbering or reusing a protobuf field number, or removing an enum value requires `/v2` / a new proto package; removed protobuf fields are `reserved`. Deprecations carry a `Deprecation` header and 12 months' notice.
2. **No row data on the wire** (doc 13 invariant 9, doc 15). No message or schema here may carry a row, a key, a before/after image or a SQL literal; summaries are typed aggregates, evidence is counts, digests and paths, assertion results are status + count + `sample_ref`.
3. **Design docs are the source of truth.** If a contract has to diverge from docs 10/12/13, change the document first (doc 18 §6). Messages completed beyond what a doc spells out carry a `// NOTE: completed from doc N §x` comment.
4. **A change to `contracts/` is a public contract change** (doc 18 §5): one PR, one concern, reviewed by the owners of every consuming directory, with the spec section linked.

## CI

`./contracts/check.sh` runs from the repository root in CI and must pass before merge. It needs `python3` with `grpcio-tools`, `openapi-spec-validator` and `pyyaml`. CI also regenerates the checked-in stubs and `reasons.yaml` (`mix steward.reasons.export`, doc 12 §3) and fails on drift.
