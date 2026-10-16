defmodule Steward.Core.Branches do
  @moduledoc """
  The `Steward.Branches` domain (doc 07 §4): branches, changesets,
  verdicts, merges, reverts, create intents, idempotency keys, queue
  entries, counters — plus `CompensationRecordMeta`, grouped here as the
  merge's own metadata mirror (doc 18 §5 decision).
  """
  use Boundary,
    deps: [
      Steward.Core.Types,
      Steward.Core.Authz,
      Steward.Core.Targets,
      Steward.Core.Policies,
      Steward.Core.Audit
    ],
    exports: [
      CreateIntent,
      Branch,
      Changeset,
      Verdict,
      VerdictAssertion,
      Merge,
      CompensationRecordMeta,
      Revert,
      QueueEntry,
      CounterDelta,
      Counter,
      IdempotencyKey
    ]

  use Ash.Domain

  resources do
    resource Steward.Core.Branches.CreateIntent
    resource Steward.Core.Branches.Branch
    resource Steward.Core.Branches.Changeset
    resource Steward.Core.Branches.Verdict
    resource Steward.Core.Branches.VerdictAssertion
    resource Steward.Core.Branches.Merge
    resource Steward.Core.Branches.CompensationRecordMeta
    resource Steward.Core.Branches.Revert
    resource Steward.Core.Branches.QueueEntry
    resource Steward.Core.Branches.CounterDelta
    resource Steward.Core.Branches.Counter
    resource Steward.Core.Branches.IdempotencyKey
  end
end
