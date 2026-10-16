defmodule Steward.Jobs do
  @moduledoc """
  Scheduled work (doc 07 §4, §6): the layer above the coordinator. Depends on
  `Steward.Core` and `Steward.Coordinator`, never the reverse.

  Two kinds of job, split by what they touch:

    * **Pure-Ash reconciliations** are AshOban *triggers declared on the
      resource* they act on, in `Steward.Core` (a `Branch` past its TTL, a `block`
      verdict whose branch was never rejected, a held changeset with no queue
      entry). They need nothing outside the domain, and each runs once per org
      with that org as the tenant, as `Steward.Core.Authz.System.jobs/0`.
    * **Jobs that call into the coordinator** live here as plain Oban cron
      workers, because `Steward.Core` may not depend on `Steward.Coordinator`
      (doc 13 invariant 10): `Steward.Jobs.TerminalProcessSweep` (every 10 minutes)
      and `Steward.Jobs.ResumeComputing` (every minute). The crontab is in
      `config/config.exs`; AshOban adds its triggers' crons to it.

  Doc 07 §4 puts every trigger and scheduled action in this namespace; the
  triggers stay on their resources because that is where AshOban's DSL lives.

  Not here yet: `HeartbeatLostScan` (doc 07 §5.3), `ExpiredLeaseScan` (E6),
  `RetentionJob` (E12), and the reconciliation that starts a merge for an evaluated
  `auto-merge` verdict with no merge row (E6).
  """
  use Boundary,
    deps: [
      Steward.Core,
      Steward.Core.Branches,
      Steward.Core.Targets,
      Steward.Core.Authz,
      Steward.Coordinator
    ],
    exports: [TerminalProcessSweep, ResumeComputing]
end
