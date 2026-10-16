defmodule Steward.Coordinator.Lifecycle.Transformers.GenerateDecide do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    cells = Transformer.get_entities(dsl_state, [:heartbeat])

    clauses =
      for cell <- cells do
        quote do
          def decide(unquote(cell.believed), unquote(cell.authoritative), progress) do
            Steward.Coordinator.Lifecycle.resolve(
              unquote(cell.reply),
              unquote(cell.actions),
              progress
            )
          end
        end
      end

    declared =
      Macro.escape(for c <- cells, do: Map.take(c, [:believed, :authoritative, :reply, :actions]))

    {:ok,
     Transformer.eval(
       dsl_state,
       [],
       quote do
         @doc """
         The decision for one heartbeat: `{reply, actions}`, generated from the
         `heartbeat` declaration. `progress` is `nil` or
         `%{advancing: boolean, complete: boolean, compensation_persisted: boolean}`.
         """
         unquote_splicing(clauses)

         @doc "The declared cells, as maps; the generated matrix test iterates these."
         def cells, do: unquote(declared)
       end
     )}
  end
end
