# 18 — Engineering conventions

**Status:** Draft
**Owner:** Founding team
**Last updated:** 2026-10-15

How work gets done in this repository. Written for engineering agents first and humans second, because agents follow written rules more literally and need the ambiguous cases spelled out.

## 1. Repository layout

One monorepo. Each top-level directory is one deployable unit or one shared library, with its own build and tests.

```
docs/        Design documents (see docs/README.md)
proxy/       Write proxy — Rust, Cargo workspace
engine/      Changeset engine — Rust; `steward-engine` binary (separate data-plane
             process, gRPC over Unix socket: changeset computation, merge worker,
             compensation log) plus the shared `steward-overlay` crate linked into
             proxy and engine (overlay WAL, `view()`); the Rustler NIF into control
             is used ONLY for policy SQL static validation and policy tests
control/     Control plane and review UI — single Elixir/Phoenix app, namespaces enforced by `boundary`
adapters/    Data-plane connectors — Java, Gradle multi-project
sdk/         python/, typescript/, mcp/
deploy/      helm/, terraform/
tools/       Dev scripts, local stack (docker compose), fixtures
```

Shared protocol definitions (protobuf, OpenAPI) live in `contracts/` and are the only thing more than one language directory may depend on.

## 2. Language conventions

### Rust (`proxy/`, `engine/`)
- Edition 2024. `cargo fmt` and `cargo clippy -- -D warnings` must pass.
- No `unsafe` outside a module named `ffi` with a safety comment on every block.
- Errors: `thiserror` for library crates, `anyhow` only in binaries. Every error crossing a crate boundary is a typed enum.
- Async: `tokio`. No blocking calls on the runtime; DuckDB work goes through `spawn_blocking` or a dedicated thread pool.
- Hot-path code (anything the proxy touches per query) must have a benchmark under `benches/` and must not allocate per request where avoidable.

### Elixir (`control/`)
- `mix format` and `mix credo --strict` must pass. Dialyzer runs in CI; new warnings fail the build.
- Domain layer: Ash 3.x (doc 07 §5.0). One `Ash.Resource` per doc 12 table, in the domain doc 07 §4 assigns it. Ash actions are the only write path.
- No `Ecto.Changeset`, `Repo.insert/update/delete`, or raw SQL in application code. Exceptions: migrations, and explicitly reviewed read-model queries (doc 07 §5.8) where an Ash read action cannot express the statement; prefer an Ash read action, calculation or aggregate first. Ecto stays underneath Ash and is not imported by application modules.
- Migrations are generated from resources by `mix ash.codegen <name>`; the generated migration **must** be committed and reviewed in the same PR as the resource change, and `mix ash.codegen --check` runs in CI. Doc 12's DDL is the reference the generated schema must match.
- Every action declares `Ash.Policy` policies; the coverage test (doc 07 §10) fails an action with none. Controllers and LiveViews pass `actor:` and `tenant:` and never check a capability themselves.
- Every resource except `Org` declares attribute multitenancy on `org_id`.
- Stateful resources (`Branch`, `Changeset`, `Merge`, `Policy`, `PolicyVersion`) use `AshStateMachine`; transitions are declared literally from doc 13 §2.1 and doc 06 §5.2, never implemented as conditional updates.
- Multi-step flows with a checkpoint are one `Reactor` each (doc 07 §5.0): compensable steps before the checkpoint, best-effort steps after it, remote calls only as reactor steps.
- One GenServer per branch, supervised; it calls actions and never writes rows itself. State that must survive a restart lives in Postgres, never only in process state.
- LiveView for the review UI, with `AshPhoenix.Form` over the same actions. Add a JS framework only with an accepted design doc explaining why LiveView cannot do it.
- Jobs: AshOban triggers and scheduled actions; consumer jobs inserted in the action's transaction. No ad-hoc `Task.start` for anything that must complete.

### Java (`adapters/`)
- Java 21. Gradle with the version catalog in `gradle/libs.versions.toml`.
- Every adapter implements the `Connector` interface from `adapters/api/` and nothing else is public.
- No framework (no Spring). Adapters are libraries loaded by a thin host; keep the dependency tree small.
- Checked exceptions are not thrown across the connector boundary; wrap in `ConnectorException` with a stable error code.

### All languages
- Names in the code match the glossary (doc 02). If the glossary is wrong, fix the glossary first.
- No TODO comments without an issue number.
- Logs are structured (JSON) and never contain customer row data. See doc 15 for what must not be logged.

## 3. Branching and pull requests

- `main` is always deployable. Work on short-lived branches named `<area>/<short-description>`, e.g. `proxy/branch-resolution-cache`.
- One PR, one concern. A PR that touches two components needs a sentence explaining why they cannot be split.
- PR description template: what, why, how tested, what the reviewer should look at first. Link the design doc section being implemented.
- Squash merge. The squash commit message is the PR title plus the "why" paragraph.
- Required checks: build, tests, lint, and for `proxy/` and `engine/` the benchmark suite with no regression over 5%.

## 4. Commits

- Imperative subject under 72 characters. Body explains why, not what; the diff shows what.
- Agents append the attribution trailers they are given. Humans do not need to.

## 5. How agents decide versus ask

Agents should ask when a wrong guess is expensive to undo and the design docs do not settle it. Agents should decide when the docs settle it, when the choice is easily reversed, or when the question is one of taste within a convention above.

**Decide, then note it in the PR:**
- Which of two equally valid library choices to use, when neither is named in a doc.
- Internal module structure, naming within the glossary, test organisation.
- Any choice where the docs say "may" or "should".

**Ask before proceeding:**
- Anything that changes a public contract (API, SDK, wire format, schema).
- Anything the docs say "must" about, where the agent believes the doc is wrong.
- Deleting data, dropping tables, rewriting history, force-pushing.
- Adding a new external dependency with a non-permissive license, or any dependency to `proxy/`.
- A cost that cannot be undone: provisioning cloud resources, sending to a customer system.

**Never, without an explicit instruction in the task:**
- Edit an `Accepted` design document. Open a separate PR proposing the change instead.
- Commit secrets, credentials, or customer data, including in test fixtures.
- Disable a failing test instead of fixing or removing it with an explanation.

When an agent asks, it must state the options and its recommendation, so the human answers with one word.

## 6. Design docs and code

Code implements design docs, not the other way around. If implementation reveals a doc is wrong:
1. Finish the smallest safe change, or stop.
2. Open a PR against the doc explaining the discrepancy.
3. Reference that PR from the code PR.

A doc that is `Draft` can be amended in the same PR as the code, with the change called out in the PR description.

## 7. Testing

- Every PR adds or changes tests. "No tests needed" requires a one-line justification.
- Unit tests next to the code. Integration tests under `<area>/tests/integration` (Rust, Java, SDKs); `control/test/integration` for Elixir (mix convention, `control/test/`). End-to-end tests under `tools/e2e` against the local stack.
- Fixtures: synthetic data only, generated by `tools/fixtures`. Never a copy of real customer data, however anonymised.
- Policy tests (doc 06) are data: a YAML file with a changeset and the expected outcome. They live under `control/test/policies/` and run in CI.

## 8. Local development

`tools/stack up` brings up Postgres, a sample target database, the proxy, and the control plane in Docker Compose. Every component must run under it. If a change breaks the local stack, the PR is not done.

## 9. Open questions

| Question | Owner | Needed by |
|----------|-------|-----------|
| Monorepo build orchestration: Bazel, Nx, or per-directory Make targets wired by a top-level script? | Founding team | Before M0 |
| Rust edition 2024 availability on the pinned toolchain | Proxy lead | Before M0 |
