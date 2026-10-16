defmodule Steward.Coordinator.Reactors.BestEffort do
  @moduledoc """
  A step *after* a flow's checkpoint (doc 07 §5.0, "Reactor rule"). The flow has
  happened, so whatever this step does it must not undo it, and Reactor undoes
  every earlier step that can be undone whenever any step fails. So a best-effort
  step:

    * implements `attempt/3`, not `run/3`, and `use`s this module;
    * never fails: an error or a crash becomes `{:ok, {:failed, reason}}`, logged
      and counted in `[:steward, :reactor, :best_effort_failed]`, and the heartbeat
      matrix, the branch self-tick or the minute reconciliation repair it;
    * defines no `compensate/4` or `undo/4`. `ReactorStepTest` asserts this for
      every step after a checkpoint.
  """
  defmacro __using__(_opts) do
    quote do
      use Reactor.Step

      @doc false
      @impl Reactor.Step
      def run(arguments, context, options) do
        Steward.Coordinator.Reactors.BestEffort.settle(__MODULE__, arguments, fn ->
          attempt(arguments, context, options)
        end)
      end
    end
  end

  @doc false
  def settle(module, arguments, fun) do
    case fun.() do
      :ok -> {:ok, :done}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> failed(module, reason, arguments)
    end
  rescue
    error -> failed(module, {:exception, Exception.message(error)}, arguments)
  catch
    kind, reason -> failed(module, {kind, reason}, arguments)
  end

  defp failed(module, reason, arguments) do
    require Logger
    Logger.warning("#{inspect(module)} failed after its flow's checkpoint: #{inspect(reason)}")

    :telemetry.execute([:steward, :reactor, :best_effort_failed], %{count: 1}, %{
      step: module,
      branch_id: Map.get(arguments, :branch_id)
    })

    {:ok, {:failed, reason}}
  end
end
