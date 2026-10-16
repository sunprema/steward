defmodule Steward.Core.Types.AssertionStatus do
  @moduledoc "Doc 12 §2.1 `assertion_status`."
  use Ash.Type.Enum, values: [:passed, :failed, :error]
end
