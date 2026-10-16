defmodule Steward.Core.Types.VerdictOutcome do
  @moduledoc "Doc 12 §2.1 `verdict_outcome`; precedence `block > hold > auto-merge` (doc 06 §5.1)."
  use Ash.Type.Enum, values: [:"auto-merge", :hold, :block]
end
