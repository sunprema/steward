defmodule Steward.Core.Types.MergeState do
  @moduledoc "Doc 12 §2.1 `merge_state`; transitions from doc 13 §6.5/§6.6."
  use Ash.Type.Enum, values: [:pending, :applied, :compensated, :failed]
end
