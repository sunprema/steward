defmodule Steward.Core.Types.PrincipalKind do
  @moduledoc "Doc 12 §2.1 `principal_kind`."
  use Ash.Type.Enum, values: [:agent, :human, :service]
end
