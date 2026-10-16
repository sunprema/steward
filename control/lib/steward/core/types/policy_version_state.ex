defmodule Steward.Core.Types.PolicyVersionState do
  @moduledoc "Doc 12 §2.1 `policy_version_state`; transitions from doc 06 §5.2."
  use Ash.Type.Enum, values: [:draft, :active, :retired]
end
