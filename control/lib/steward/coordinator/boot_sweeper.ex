defmodule Steward.Coordinator.BootSweeper do
  @moduledoc """
  Rebuilds the branch processes after a restart (doc 07 §4): streams every
  non-terminal branch (`Branch.non_terminal`, 1,000 per page) and starts its
  process. The node is not `ready?/0` until the sweep has finished, so a load
  balancer or readiness probe does not send it heartbeats it would answer from
  an empty Registry (they would still be answered correctly, by
  `Steward.Coordinator.Heartbeat` starting the process on demand, but the
  sweep is what makes the node's process count honest).

  Orgs are enumerated with authorisation off, because there is no org to scope
  a system actor to yet; each org's branches are then read as that org's
  `:coordinator` system actor, so multitenancy still applies to every branch
  read. This is the one reviewed `authorize?: false` of the coordinator
  (doc 15 §4.1 point 1).
  """
  use GenServer

  require Logger

  alias Steward.Coordinator.Branch
  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Branch, as: BranchRecord
  alias Steward.Core.Targets.Org

  @batch 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True once this node's boot sweep has finished."
  def ready?, do: :persistent_term.get({__MODULE__, :ready}, false)

  @doc """
  Starts a process for every non-terminal branch that has none. Returns
  `%{started: n, present: n}`. Safe to run any time; `TerminalProcessSweep`
  runs it periodically.
  """
  def run do
    started_at = Elixir.System.monotonic_time(:millisecond)

    summary =
      Org
      |> Ash.stream!(authorize?: false, batch_size: @batch)
      |> Enum.reduce(%{started: 0, present: 0}, fn org, acc ->
        sweep_org(org.id, acc)
      end)

    :telemetry.execute(
      [:steward, :coordinator, :boot_sweep],
      %{
        duration_ms: Elixir.System.monotonic_time(:millisecond) - started_at,
        started: summary.started
      },
      %{}
    )

    summary
  end

  defp sweep_org(org_id, acc) do
    BranchRecord
    |> Ash.Query.for_read(:non_terminal, %{},
      tenant: org_id,
      actor: System.new(:coordinator, org_id)
    )
    |> Ash.stream!(batch_size: @batch)
    |> Enum.reduce(acc, fn record, acc ->
      case Steward.Coordinator.whereis(record.id) do
        nil ->
          case Branch.ensure_started(org_id, record.id, record: record) do
            {:ok, _} -> %{acc | started: acc.started + 1}
            {:error, _} -> acc
          end

        _pid ->
          %{acc | present: acc.present + 1}
      end
    end)
  end

  @impl true
  def init(_opts) do
    :persistent_term.put({__MODULE__, :ready}, false)
    {:ok, %{}, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    summary = run()
    :persistent_term.put({__MODULE__, :ready}, true)
    Logger.info("coordinator boot sweep finished: #{inspect(summary)}")
    {:noreply, state}
  end
end
