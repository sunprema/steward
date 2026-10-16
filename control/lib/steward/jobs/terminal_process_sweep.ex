defmodule Steward.Jobs.TerminalProcessSweep do
  @moduledoc """
  Every 10 minutes (doc 07 §6, "GenServer leak"): stop any branch process whose
  row is terminal, start any non-terminal row that has none. The work is
  `Steward.Coordinator.TerminalProcessSweep.run/0`.

  It runs on every node, and each node sweeps its own registry; the Oban job is
  unique per period so one node's queue does not run it many times.
  """
  use Oban.Worker, queue: :reconcile, max_attempts: 1, unique: [period: 300]

  @impl Oban.Worker
  def perform(_job) do
    summary = Steward.Coordinator.TerminalProcessSweep.run()
    :telemetry.execute([:steward, :jobs, :terminal_process_sweep], summary, %{})
    :ok
  end
end
