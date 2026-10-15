# Working in the Steward repository

Steward is a write-control plane for AI agents: agents write to production data through branches, changes become reviewable changesets, policy gates them, every merge is reversible. If you have not read the design, start with `docs/README.md`; the foundation documents (01–03) and the lifecycle spec (13) are required reading before changing anything.

## Rules that apply to every change

1. **Design documents are the source of truth.** Code implements `docs/`; it does not redefine it. If implementation shows a document is wrong, stop, open a PR against the document, and reference it from the code PR. Never edit an `Accepted` document in a code PR. See `docs/40-engineering/18-engineering-conventions.md` §6.
2. **Vocabulary is fixed.** Use the terms in `docs/00-foundation/02-glossary-and-domain-model.md` as identifiers: `Branch`, `Changeset`, `Verdict`, `Compensation`, not synonyms. Reason strings, error codes, and event names come from `contracts/reasons.yaml`.
3. **Contracts first.** Anything that crosses a process or plane boundary is defined in `contracts/` (protobuf and OpenAPI). Changes there are additive within v1 and run `./contracts/check.sh`.
4. **No row data in the control plane, ever.** Not in logs, not in metrics labels, not in messages crossing the plane boundary. `docs/30-operations/15-security-and-tenancy-model.md` lists what is never logged.
5. **Every PR adds or changes tests.** Synthetic data only, from `tools/fixtures`. The local stack (`tools/stack/stack up`) must keep working.
6. **Decide vs ask.** `docs/40-engineering/18-engineering-conventions.md` §5 says when to proceed and when to stop and ask. When asking, state the options and a recommendation.

## Layout

| Directory | What | Language | Spec |
|-----------|------|----------|------|
| `docs/` | Design documents | Markdown | — |
| `contracts/` | Protobuf for the plane `Session` stream, OpenAPI for `/v1`, `reasons.yaml` | — | docs 10, 12 |
| `proxy/` | Write proxy (`steward-proxy`) | Rust | doc 04 |
| `engine/` | Changeset engine (`steward-engine`) and the shared `steward-overlay` crate | Rust | docs 05, 09 |
| `control/` | Control plane: single Phoenix app with Ash | Elixir | docs 06, 07 |
| `adapters/` | Data-plane connectors and the gRPC host | Java 21 / Gradle | doc 08 |
| `sdk/` | `python/`, `typescript/`, `mcp/` | Python, TypeScript | doc 11 |
| `tools/` | `stack/` (Docker Compose local environment), `fixtures/` (synthetic data) | Bash, Python | docs 17, 18 |
| `tasks/` | Action items per milestone, the working list handed to Claude | Markdown | doc 19 |
| `deploy/` | Helm chart and Terraform for the data plane (later) | — | doc 14 |

The Rust workspace root is the repository root (`Cargo.toml`). Java builds from `adapters/` with the Gradle wrapper. Elixir builds from `control/`.

## Milestone

Work is scoped by `docs/40-engineering/19-build-roadmap.md`; the working list of action items is `tasks/M0-action-items.md`. Current milestone: **M0 — One branch, one merge** (Postgres only). Pick items from the tasks file, read the spec sections it names first, and tick the item with the PR number when merged. Do not start M1 items without an explicit instruction.

## Commits and PRs

Branch names `<area>/<short-description>`. One PR, one concern. PR description: what, why, how tested, what to look at first, link to the spec section. Squash merge. See doc 18 §3–4.
