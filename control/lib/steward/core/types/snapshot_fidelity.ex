defmodule Steward.Core.Types.SnapshotFidelity do
  @moduledoc "Doc 12 §2.1 `snapshot_fidelity` (doc 08)."
  use Ash.Type.Enum, values: [:TRUE_SNAPSHOT, :TIMESTAMP_BOUNDED]
end
