defmodule Steward.Core.Types.ReviewDecision do
  @moduledoc """
  Doc 12 §2.1 `review_decision`. `edited` exists in the enum for forward
  compatibility but is refused in M0 by the `reviews.edit_not_in_m0` CHECK
  (doc 13 §12, doc 12 §2.2).
  """
  use Ash.Type.Enum, values: [:approved, :rejected, :edited]
end
