# Steward

**Pull requests for data.** A write-control plane that lets AI agents change production data through reviewable, policy-gated, reversible changesets.

Agents write through Steward into an isolated branch. Steward computes a semantic changeset, evaluates it against policy, and either merges it automatically or parks it in a review queue for a human. Every merge records its inverse, so any change can be reverted at any time.

## Status

Pre-build. This repository currently holds the design documentation that engineering agents and humans build from. Code will land in the directories listed below as each milestone starts.

## Repository layout

```
docs/           Design documents — the source of truth for what gets built
  00-foundation/
  10-components/
  20-contracts/
  30-operations/
  40-engineering/
proxy/          Write proxy (Rust) — not yet created
engine/         Changeset engine (Rust + DuckDB) — not yet created
control/        Control plane and review UI (Elixir/Phoenix) — not yet created
adapters/       Data-plane connectors (Java) — not yet created
sdk/            Agent SDKs and MCP server — not yet created
deploy/         Helm charts and Terraform modules — not yet created
```

## Reading order

Start with `docs/README.md`. The foundation documents (product brief, domain model, architecture, lifecycle) constrain everything else and must be read first by anyone, human or agent, working in this repository.

## Working here

Engineering conventions, including how agents should decide versus ask, live in `docs/40-engineering/18-engineering-conventions.md`. Read it before opening a pull request.
