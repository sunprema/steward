defmodule Steward.Coordinator.Reports do
  @moduledoc """
  Hands a `ChangesetReport` from the stream (where it arrives on its own, doc 13
  §6.3 step 7) to the `Propose` reactor that is waiting for it.

  A report can arrive before the reactor starts to wait, or twice (a recompute
  overwrites, §6.3 f4), so reports are kept for 30 minutes by `changeset_id` and a
  waiter registers *before* it looks: `await/2` never loses one to the race. A
  reactor retrying a compute calls `forget/1` first, so it waits for the new report
  and not the failed one it already has.

  This is the default `Steward.Coordinator.Plane.Handlers.changeset_report/3`.
  `MergeOutcome`s are not handled here (E6).
  """
  use GenServer

  @table :steward_changeset_reports
  @waiters Steward.Coordinator.Reports.Waiters
  @keep_ms 30 * 60_000
  @purge_ms 60_000

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {Registry, keys: :duplicate, name: @waiters},
             %{id: :table, start: {GenServer, :start_link, [__MODULE__, [], [name: __MODULE__]]}}
           ],
           [strategy: :one_for_all]
         ]}
    }
  end

  @doc "Stores `report` and wakes anyone waiting on its changeset."
  def deliver(%{changeset_id: changeset_id} = report) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {changeset_id, report, now()})

      Registry.dispatch(@waiters, changeset_id, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:changeset_report, changeset_id, report})
      end)
    end

    :ok
  end

  @doc """
  Waits up to `timeout_ms` for the report of `changeset_id`: `{:ok, report}` or
  `{:error, :timeout}`. Returns at once if one has already arrived.
  """
  def await(changeset_id, timeout_ms) do
    {:ok, _} = Registry.register(@waiters, changeset_id, nil)

    try do
      case lookup(changeset_id) do
        {:ok, report} ->
          {:ok, report}

        :error ->
          receive do
            {:changeset_report, ^changeset_id, report} -> {:ok, report}
          after
            timeout_ms -> {:error, :timeout}
          end
      end
    after
      Registry.unregister(@waiters, changeset_id)
      flush(changeset_id)
    end
  end

  @doc "Drops a stored report, so the next `await/2` waits for a fresh one."
  def forget(changeset_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, changeset_id)
    :ok
  end

  defp lookup(changeset_id) do
    case :ets.whereis(@table) != :undefined && :ets.lookup(@table, changeset_id) do
      [{_, report, _}] -> {:ok, report}
      _ -> :error
    end
  end

  defp flush(changeset_id) do
    receive do
      {:changeset_report, ^changeset_id, _} -> flush(changeset_id)
    after
      0 -> :ok
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :purge, @purge_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:purge, state) do
    cutoff = now() - @keep_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :purge, @purge_ms)
    {:noreply, state}
  end

  defp now, do: Elixir.System.monotonic_time(:millisecond)
end
