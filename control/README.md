# control — Steward control plane

A single Phoenix application with Ash 3. Specification: `docs/10-components/07-control-plane-and-review-queue.md` (read §4 and §5.0 first), `docs/10-components/06-policy-engine.md`, `docs/20-contracts/12-data-model-and-schemas.md`, conventions in `docs/40-engineering/18-engineering-conventions.md` §2.

The application is created locally by the team; this directory is a placeholder until then. Target shape, from doc 07 §4 — four top-level namespaces, each a `boundary`:

```
control/
  lib/
    steward/
      core/           Ash domains and resources: Targets, Branches, Policies, Reviews, Audit
      coordinator/    Branch GenServers, Spark lifecycle DSL, Reactors (CreateBranch, Propose, Merge, Revert, Abandon)
      jobs/           AshOban triggers and workers
    steward_web/      Phoenix controllers for /v1 (doc 10), gRPC services, LiveView
  config/
  test/               ExUnit; integration tests under test/integration (doc 18 §7)
  mix.exs
```

Dependency direction, enforced at compile time by `boundary`:

```
StewardWeb ──▶ Steward.Coordinator ──▶ Steward.Core
Steward.Jobs ──▶ Steward.Core (and Coordinator for repairs)
```

`Steward.Core` must not reference a GenServer, the data-plane client, or anything in `StewardWeb`; that is what guarantees doc 13 invariant 10 (no remote call inside a transaction).

Suggested bootstrap:

```sh
mix phx.new control --app steward --no-mailer --no-dashboard --no-gettext
cd control
# add to mix.exs deps: ash, ash_postgres, ash_state_machine, reactor, ash_oban, ash_phoenix, boundary
# declare the four boundaries in lib/steward/core.ex, coordinator.ex, jobs.ex and lib/steward_web.ex
```

Local database: `tools/stack/stack up` starts `control-db` on port 5433 (database `steward_control`); see `tools/README.md`.

Rules that matter most here:

- Actions are the only write path; no `Ecto.Changeset` or `Repo.insert` in application code (doc 18 §2).
- Every action has a policy; a test fails the build otherwise (doc 07 §10).
- Migrations are generated with `mix ash.codegen` and committed; they must match the DDL in doc 12.
- The `events` row is appended inside the same transaction as the state change, via an Ash change, never a notifier (doc 07 §5.0).
- Reactor steps before the checkpoint compensate; steps after it are heartbeat-repaired (doc 07 §5.0, doc 13).
