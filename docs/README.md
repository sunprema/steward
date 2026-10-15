# Steward design documents

This directory is the source of truth for what Steward is and how it is built. Documents are numbered in dependency order: a document only relies on documents with lower numbers. Read in order the first time; afterwards, jump to what you need.

Each document carries a status line at the top: `Draft`, `Review`, or `Accepted`. Only `Accepted` documents are binding on implementation. Changes to an `Accepted` document go through a pull request that explains what changed and why.

## Index

### 00 — Foundation

| # | Document | Status | Purpose |
|---|----------|--------|---------|
| 01 | [Product brief](00-foundation/01-product-brief.md) | Draft | Problem, customer, wedge, non-goals, pricing |
| 02 | [Glossary and domain model](00-foundation/02-glossary-and-domain-model.md) | Draft | Terms, entities, states, relationships |
| 03 | [Architecture overview](00-foundation/03-architecture-overview.md) | Draft | Planes, components, language boundaries, principles |

### 10 — Component specifications

All component specs follow the template in `10-components/_template.md`.

| # | Document | Status | Purpose |
|---|----------|--------|---------|
| 04 | Write proxy | Planned | Rust; wire protocols, routing, branch resolution |
| 05 | Changeset engine | Planned | Rust + DuckDB; overlay format, diff, impact metrics |
| 06 | Policy engine | Planned | SQL-assertion policies, evaluation, outcomes |
| 07 | Control plane and review queue | Planned | Elixir; branch lifecycle, heartbeats, LiveView UI |
| 08 | Data-plane adapters | Planned | Java; Postgres, Snowflake/Iceberg, Salesforce |
| 09 | Compensation log | Planned | Inverse writes, revert semantics, retention |

### 20 — Contracts

| # | Document | Status | Purpose |
|---|----------|--------|---------|
| 10 | API specification | Planned | REST/gRPC surface, auth model |
| 11 | Agent SDK and MCP server | Planned | Tools agents call; Python/TS clients |
| 12 | Data model and schemas | Planned | Control-plane schema, overlay layout, events |
| 13 | [Branch and merge lifecycle](20-contracts/13-branch-and-merge-lifecycle.md) | Draft | State machine, checkpoints, conflicts, failures |

### 30 — Operations

| # | Document | Status | Purpose |
|---|----------|--------|---------|
| 14 | Deployment and infrastructure | Planned | Customer-cloud data plane, control plane, secrets |
| 15 | Security and tenancy model | Planned | Residency, plane boundary, audit |
| 16 | Observability and SLOs | Planned | Metrics, traces, the numbers that matter |
| 17 | Testing strategy | Planned | Unit, integration, load, policy harness |

### 40 — Engineering

| # | Document | Status | Purpose |
|---|----------|--------|---------|
| 18 | [Engineering conventions](40-engineering/18-engineering-conventions.md) | Draft | Per-language style, repo layout, agent decision rules |
| 19 | Build roadmap | Planned | Milestones, dependency order, definition of done |

## Conventions for these documents

- Plain Markdown. Diagrams as Mermaid in fenced blocks so they render on GitHub and diff cleanly.
- Every document opens with: title, status, owner, last-updated date, one-paragraph summary.
- Normative language: **must**, **should**, **may** carry their RFC 2119 meanings. Use them deliberately.
- Decisions that were close calls get a short "Alternatives considered" section. Future readers need to know what was rejected and why, not only what was chosen.
- Open questions go in an "Open questions" section at the end, each with an owner. Do not bury them in prose.
