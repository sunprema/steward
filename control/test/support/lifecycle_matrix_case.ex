defmodule Steward.LifecycleMatrixCase do
  @moduledoc """
  Generates the matrix test for a `Steward.Coordinator.Lifecycle` module from
  its own declaration (doc 07 §10): one test per declared cell, each checking
  the compiled `decide/3` against the committed expectation file, plus checks
  that the declaration and the expectation list exactly the same 40 cells.

      use Steward.LifecycleMatrixCase,
        matrix: Steward.Coordinator.HeartbeatMatrix,
        expectations: "test/support/heartbeat_matrix.exs"
  """
  defmacro __using__(opts) do
    matrix = Macro.expand(Keyword.fetch!(opts, :matrix), __CALLER__)
    path = Keyword.fetch!(opts, :expectations)
    {expected, _} = Code.eval_file(path)

    cells = matrix.cells()

    tests =
      for %{believed: believed, authoritative: authoritative} <- cells do
        {reply, actions} = Map.fetch!(expected, {believed, authoritative})

        quote do
          test "#{unquote(believed)} × #{unquote(authoritative)}" do
            # No merge progress: only the unconditional actions can appear.
            {decision, taken} =
              unquote(matrix).decide(unquote(believed), unquote(authoritative), nil)

            assert decision.authoritative == unquote(reply)
            assert decision.freeze == unquote(reply) in [:proposed, :merging]

            unconditional = unquote(actions) -- [:renew_lease, :advance_merged]
            assert taken == unconditional

            # With progress that is advancing, complete and persisted, every declared action applies.
            {_, all} =
              unquote(matrix).decide(unquote(believed), unquote(authoritative), %{
                advancing: true,
                complete: true,
                compensation_persisted: true
              })

            assert all == unquote(actions)
          end
        end
      end

    quote do
      use ExUnit.Case, async: true

      @matrix unquote(matrix)
      @expected unquote(Macro.escape(expected))

      test "the declaration and the committed expectation list exactly the same cells" do
        declared =
          Map.new(@matrix.cells(), &{{&1.believed, &1.authoritative}, {&1.reply, &1.actions}})

        assert declared == @expected
        assert map_size(declared) == 40
      end

      unquote_splicing(tests)
    end
  end
end
