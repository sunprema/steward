defmodule Steward.Core.Types.ChangesetState do
  @moduledoc "Doc 12 §2.1 `changeset_state`; transitions from doc 13 §3."
  use Ash.Type.Enum, values: [:computing, :evaluated, :superseded]
end
