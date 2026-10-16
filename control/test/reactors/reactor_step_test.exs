defmodule Steward.Coordinator.Reactors.ReactorStepTest do
  @moduledoc """
  The reactor rule of doc 07 §5.0, asserted structurally and by behaviour:

    * every reactor has **exactly one checkpoint step**, which has no `undo`;
    * steps *before* it that wrote something declare `undo` (and `compensate`);
    * steps *after* it declare neither, never fail, and are never unwound;
    * a reactor that fails after its checkpoint returns `{:ok, record}` with the
      failed step logged, and nothing before the checkpoint is undone.

  The step tables below transcribe doc 07 §5.0 / §5.1 / §5.2 / doc 13 §6.7, so a
  change to a flow's shape must change this file.
  """
  use ExUnit.Case, async: true

  alias Steward.Coordinator.Reactors.{Abandon, CreateBranch, Propose, Withdraw}

  # {reactor, checkpoint, steps before it that wrote something (and so can be undone),
  #  every step before it, steps after it}
  @flows [
    {CreateBranch, :checkpoint, [:intent], [:intent, :ids, :target, :overlay],
     [:commit_intent, :start_process, :routing]},
    {Propose, :checkpoint, [:open_changeset],
     [:open_changeset, :freeze, :compute, :record_computed, :evaluate, :floor], [:followup]},
    {Abandon, :abandon, [], [], [:routing_remove]},
    {Withdraw, :withdraw, [], [], [:unfreeze]}
  ]

  defp steps(reactor),
    do:
      reactor
      |> Reactor.Info.to_struct!()
      |> Map.fetch!(:steps)
      |> Map.new(&{&1.name, elem(&1.impl, 0)})

  defp undoable?(module),
    do:
      Reactor.Step.can?(%Reactor.Step{impl: module}, :undo) and
        function_exported?(module, :undo, 4)

  defp compensable?(module), do: function_exported?(module, :compensate, 4)

  for {reactor, checkpoint, writers, before, after_steps} <- @flows do
    describe "#{inspect(reactor)}" do
      test "has exactly the steps of its table, in three groups" do
        names = steps(unquote(reactor)) |> Map.keys() |> Enum.sort()
        expected = Enum.sort([unquote(checkpoint)] ++ unquote(before) ++ unquote(after_steps))
        assert names == expected
      end

      test "the checkpoint step has no undo (doc 07 §5.0)" do
        refute undoable?(steps(unquote(reactor))[unquote(checkpoint)])
      end

      test "the steps before the checkpoint that wrote something declare undo" do
        for name <- unquote(writers),
            do: assert(undoable?(steps(unquote(reactor))[name]), "#{name} must be undoable")
      end

      test "the other steps before the checkpoint undo nothing, because they wrote nothing durable" do
        for name <- unquote(before) -- unquote(writers),
            do: refute(undoable?(steps(unquote(reactor))[name]), "#{name}")
      end

      test "steps after the checkpoint declare neither undo nor compensate, so a failure cannot unwind the flow" do
        for name <- unquote(after_steps) do
          module = steps(unquote(reactor))[name]
          refute undoable?(module), "#{name} must not undo"
          refute compensable?(module), "#{name} must not compensate"

          assert module.module_info(:attributes)[:behaviour]
                 |> List.wrap()
                 |> Enum.member?(Reactor.Step)

          assert function_exported?(module, :attempt, 3), "#{name} must be a BestEffort step"
        end
      end
    end
  end

  # --- the rule, by behaviour -----------------------------------------------------

  defmodule Log do
    def add(entry), do: Agent.update(:reactor_step_log, &[entry | &1])
    def all, do: Agent.get(:reactor_step_log, &Enum.reverse/1)
  end

  defmodule Writes do
    use Reactor.Step
    def run(%{name: name}, _context, _opts), do: Log.add({:run, name}) && {:ok, name}
    def undo(_value, %{name: name}, _context, _opts), do: Log.add({:undo, name}) && :ok
  end

  defmodule Checkpoint do
    use Reactor.Step
    def run(%{name: name}, _context, _opts), do: Log.add({:run, name}) && {:ok, :record}
  end

  defmodule Fails do
    use Steward.Coordinator.Reactors.BestEffort
    def attempt(_arguments, _context, _opts), do: {:error, :the_data_plane_is_down}
  end

  defmodule Raises do
    use Steward.Coordinator.Reactors.BestEffort
    def attempt(_arguments, _context, _opts), do: raise("boom")
  end

  defmodule Flow do
    use Reactor

    step :before, Writes do
      argument :name, value(:before)
    end

    step :checkpoint, Checkpoint do
      argument :name, value(:checkpoint)
      wait_for :before
    end

    step :best_effort, Fails do
      wait_for :checkpoint
    end

    step :also_best_effort, Raises do
      wait_for :checkpoint
    end

    return :checkpoint
  end

  setup do
    {:ok, _} =
      start_supervised(%{
        id: :log,
        start: {Agent, :start_link, [fn -> [] end, [name: :reactor_step_log]]}
      })

    :ok
  end

  test "a failing or raising step after the checkpoint leaves the flow done: {:ok, record}, nothing undone" do
    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:steward, :reactor, :best_effort_failed],
      fn _, _, meta, _ -> send(parent, {:failed, meta.step}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, :record} = Reactor.run(Flow, %{})

    assert Log.all() == [run: :before, run: :checkpoint]
    refute {:undo, :before} in Log.all()
    assert_receive {:failed, Fails}
    assert_receive {:failed, Raises}
  end
end
