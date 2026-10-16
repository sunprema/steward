defmodule Steward.Coordinator.Lifecycle.Transformers.VerifyCoverage do
  @moduledoc """
  Compilation fails unless all 40 `(believed, authoritative)` pairs of doc 13
  §6.8 are declared exactly once: a missing or duplicate cell is a compile
  error, not a test failure (doc 07 §5.0).

  This is a transformer rather than a `Spark.Dsl.Verifier` on purpose: Spark
  reports a failing verifier as a compiler *warning*, which only fails the build
  where `--warnings-as-errors` is on, while a failing transformer raises.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Steward.Coordinator.Lifecycle

  @impl true
  def before?(Steward.Coordinator.Lifecycle.Transformers.GenerateDecide), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    declared =
      dsl_state
      |> Transformer.get_entities([:heartbeat])
      |> Enum.map(&{&1.believed, &1.authoritative})

    expected =
      for b <- Lifecycle.believed_states(), a <- Lifecycle.authoritative_states(), do: {b, a}

    missing = expected -- declared
    duplicated = (declared -- Enum.uniq(declared)) |> Enum.uniq()

    cond do
      missing != [] ->
        error(dsl_state, "heartbeat matrix is missing cells: #{cells(missing)}")

      duplicated != [] ->
        error(dsl_state, "heartbeat matrix declares cells more than once: #{cells(duplicated)}")

      true ->
        {:ok, dsl_state}
    end
  end

  defp cells(pairs),
    do: Enum.map_join(pairs, ", ", fn {b, a} -> "believed #{b} × authoritative #{a}" end)

  defp error(dsl_state, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: Transformer.get_persisted(dsl_state, :module),
       path: [:heartbeat],
       message: message
     )}
  end
end
