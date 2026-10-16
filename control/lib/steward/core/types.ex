defmodule Steward.Core.Types do
  @moduledoc """
  Doc 12 §2.1 enums, one `Ash.Type.Enum` module per type under `types/`.
  Depended on by every domain in `Steward.Core` whose resources use one of
  these as an attribute type.
  """
  use Boundary,
    exports: [
      PrincipalKind,
      TargetKind,
      SnapshotFidelity,
      Capability,
      BranchState,
      ChangesetState,
      VerdictOutcome,
      VerdictReason,
      ReviewDecision,
      MergeState,
      CompensationStatus,
      AssertionStatus,
      PolicyVersionState,
      CreateIntentState,
      LifecycleReason
    ]
end
