defmodule Steward.Coordinator.TerminalProcessSweep do
  @moduledoc """
  The reconciliation between processes and rows (doc 07 §6, "GenServer leak"):
  stop any process whose row is terminal (or gone), and start any non-terminal
  row that has none. Every terminal transition through
  `Steward.Coordinator.Branch.transition/5` already stops its process; this
  catches transitions made by other means (a reactor calling the Ash action
  directly, another node) and crashed processes.

  `run/0` is the whole job. Doc 07 schedules it with Oban every 10 minutes; the
  AshOban wiring belongs to `Steward.Jobs` and arrives with the Oban setup (the
  first AshOban consumer is E4), so until then nothing calls this on a timer.
  """
  require Ash.Query

  alias Steward.Coordinator
  alias Steward.Coordinator.BootSweeper
  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Branch, as: BranchRecord

  @terminal [:merged, :rejected, :abandoned, :closed]

  @doc "Returns `%{stopped: n, started: n}`."
  def run do
    stopped = stop_terminal()
    %{started: started} = BootSweeper.run()
    %{stopped: stopped, started: started}
  end

  defp stop_terminal do
    Coordinator.registry()
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.group_by(fn {_id, _pid, org_id} -> org_id end)
    |> Enum.map(fn {org_id, entries} -> stop_in_org(org_id, entries) end)
    |> Enum.sum()
  end

  defp stop_in_org(org_id, entries) do
    ids = Enum.map(entries, &elem(&1, 0))
    terminal = @terminal
    actor = System.new(:coordinator, org_id)

    live =
      BranchRecord
      |> Ash.Query.filter(id in ^ids and state not in ^terminal)
      |> Ash.read!(tenant: org_id, actor: actor)
      |> MapSet.new(& &1.id)

    entries
    |> Enum.reject(fn {id, _pid, _org} -> id in live end)
    |> Enum.map(fn {_id, pid, _org} -> stop(pid) end)
    |> Enum.count(& &1)
  end

  defp stop(pid) do
    GenServer.stop(pid, :normal)
    true
  catch
    :exit, _ -> false
  end
end
