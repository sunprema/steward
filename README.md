# Steward

**Pull requests for data.** A write-control plane that lets AI agents change production data through reviewable, policy-gated, reversible changesets.

Agents write through Steward into an isolated branch. Steward computes a semantic changeset, evaluates it against policy, and either merges it automatically or parks it in a review queue for a human. Every merge records its inverse, so any change can be reverted at any time.

## Status

Milestone M0 ("one branch, one merge") is starting. The design documentation under `docs/` is complete; `contracts/`, the local stack, and the language workspaces are scaffolded. See `docs/40-engineering/19-build-roadmap.md` for what is being built and `CLAUDE.md` for the rules.

## Repository layout

```
docs/           Design documents — the source of truth for what gets built
contracts/      Protobuf for the plane Session stream, OpenAPI for /v1, reasons.yaml
proxy/          Write proxy (Rust)                      — workspace member
engine/         Changeset engine + steward-overlay crate (Rust)
control/        Control plane and review UI (Elixir/Phoenix with Ash)
adapters/       Data-plane connectors and gRPC host (Java 21, Gradle)
sdk/            python/, typescript/, mcp/
tools/          stack/ (Docker Compose local environment), fixtures/ (synthetic data)
deploy/         Helm chart and Terraform for the data plane — later
```

## Getting started

```sh
tools/stack/stack up          # Postgres x2 + MinIO, loads the retail fixture
./contracts/check.sh          # compile protos, validate OpenAPI, cross-check enums
cargo build && cargo clippy -- -D warnings
cd adapters && ./gradlew build
```

The Phoenix application under `control/` is created locally; `control/README.md` describes the shape.

## Reading order

Start with `docs/README.md`. The foundation documents (product brief, domain model, architecture, lifecycle) constrain everything else and must be read first by anyone, human or agent, working in this repository.

## Working here

Engineering conventions, including how agents should decide versus ask, live in `docs/40-engineering/18-engineering-conventions.md`. Read it before opening a pull request.
