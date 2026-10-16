defmodule Steward.Core.Types.BranchState do
  @moduledoc "Doc 12 §2.1 `branch_state`; transitions literally from doc 13 §2.1."
  use Ash.Type.Enum,
    values: [:open, :proposed, :merging, :merged, :rejected, :abandoned, :closed]
end
