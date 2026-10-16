defmodule Steward.Coordinator.LifecycleVerifierTest do
  @moduledoc """
  A missing or duplicate matrix cell is a compile error, not a test failure
  (doc 07 §5.0).
  """
  use ExUnit.Case, async: true

  alias Steward.Coordinator.Lifecycle

  defp source(cells) do
    lines =
      for {b, a} <- cells,
          do:
            "cell believed: #{inspect(b)}, authoritative: #{inspect(a)}, reply: #{inspect(a)}, actions: []"

    """
    defmodule Steward.Coordinator.LifecycleVerifierTest.M#{System.unique_integer([:positive])} do
      use Steward.Coordinator.Lifecycle

      heartbeat do
        #{Enum.join(lines, "\n    ")}
      end
    end
    """
  end

  defp all_pairs,
    do: for(b <- Lifecycle.believed_states(), a <- Lifecycle.authoritative_states(), do: {b, a})

  defp compile(cells),
    do: ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source(cells)) end)

  test "all 40 cells, once each, compiles" do
    assert is_binary(compile(all_pairs()))
  end

  test "a missing cell fails compilation and names it" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string(source(all_pairs() -- [{:merging, :merging}]))
      end

    assert Exception.message(error) =~ "missing cells"
    assert Exception.message(error) =~ "believed merging × authoritative merging"
  end

  test "a duplicate cell fails compilation and names it" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string(source(all_pairs() ++ [{:open, :open}]))
      end

    assert Exception.message(error) =~ "more than once"
    assert Exception.message(error) =~ "believed open × authoritative open"
  end

  test "an unknown believed state, authoritative state or action is refused" do
    bad = fn fragment ->
      """
      defmodule Steward.Coordinator.LifecycleVerifierTest.B#{System.unique_integer([:positive])} do
        use Steward.Coordinator.Lifecycle

        heartbeat do
          cell #{fragment}
        end
      end
      """
    end

    for fragment <- [
          "believed: :sleeping, authoritative: :open, reply: :open",
          "believed: :open, authoritative: :exploded, reply: :open",
          "believed: :open, authoritative: :open, reply: :open, actions: [:launch]"
        ] do
      assert_raise Spark.Error.DslError, fn -> Code.compile_string(bad.(fragment)) end
    end
  end
end
