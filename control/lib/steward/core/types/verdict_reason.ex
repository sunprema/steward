defmodule Steward.Core.Types.VerdictReason do
  @moduledoc """
  Doc 12 §2.1 `verdict_reason` (doc 06 §4.3). Distinct from `LifecycleReason`:
  these never appear as `branches.reason`, `changesets.superseded_reason`, or
  `merges.reason` (contracts/reasons.yaml's "not in this list on purpose" note).
  """
  use Ash.Type.Enum, values: [:policies, :policy_error, :no_policy_coverage, :revert_conflict]
end
