defmodule Steward.Coordinator.Lifecycle.Cell do
  @moduledoc "One cell of the doc 13 §6.8 table: what the control plane replies, and does, for a `(believed, authoritative)` pair."
  defstruct [:believed, :authoritative, :reply, actions: [], __spark_metadata__: nil]
end
