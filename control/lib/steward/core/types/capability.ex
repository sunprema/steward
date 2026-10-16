defmodule Steward.Core.Types.Capability do
  @moduledoc "Doc 12 §2.1 `capability` — target_membership capabilities (doc 07 §8)."
  use Ash.Type.Enum, values: [:reviewer, :policy_admin, :target_admin]
end
