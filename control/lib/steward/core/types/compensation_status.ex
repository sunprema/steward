defmodule Steward.Core.Types.CompensationStatus do
  @moduledoc "Doc 12 §2.1 `compensation_status` (doc 09 §4)."
  use Ash.Type.Enum, values: [:complete, :partial, :consumed, :expired, :corrupt]
end
