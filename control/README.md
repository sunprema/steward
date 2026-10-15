# control — Steward control plane

Phoenix umbrella with Ash 3. Specification: `docs/10-components/07-control-plane-and-review-queue.md` (read §5.0 first), `docs/10-components/06-policy-engine.md`, `docs/20-contracts/12-data-model-and-schemas.md`, conventions in `docs/40-engineering/18-engineering-conventions.md` §2.

The umbrella is created locally by the team (this directory is a placeholder until then). Target shape, from doc 07 §4:

```
control/
  apps/
    steward_core/          Ash domains and resources (Targets, Branches, Policies, Reviews, Audit)
    steward_coordinator/   Branch GenServers, Spark lifecycle DSL, Reactors
    steward_jobs/          AshOban triggers and workers
    steward_web/           Phoenix controllers (/v1, doc 10) and LiveView
  config/
  mix.exs
```

Suggested bootstrap:

```sh
cd control
mix phx.new . --umbrella --app steward --no-mailer --no-dashboard
# then add ash, ash_postgres, ash_state_machine, reactor, ash_oban, ash_phoenix
# to apps/steward_core/mix.exs and others per doc 07 §4
```

Local database: `tools/stack/stack up` starts `control-db` on port 5433 (database `steward_control`); see `tools/README.md`.

Rules that matter most here:

- Actions are the only write path; no `Ecto.Changeset` or `Repo.insert` in application code (doc 18 §2).
- Every action has a policy; a test fails the build otherwise (doc 07 §10).
- Migrations are generated with `mix ash.codegen` and committed; they must match the DDL in doc 12.
- The `events` row is appended inside the same transaction as the state change, via an Ash change, never a notifier (doc 07 §5.0).
- No remote call inside a transaction; Reactor steps before the checkpoint compensate, steps after it are heartbeat-repaired (doc 07 §5.0, doc 13).
