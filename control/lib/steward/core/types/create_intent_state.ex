defmodule Steward.Core.Types.CreateIntentState do
  @moduledoc "Doc 12 §2.1 `create_intent_state` (doc 13 §6.1)."
  use Ash.Type.Enum, values: [:pending, :committed, :failed, :superseded]
end
