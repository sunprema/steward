defmodule Steward.Coordinator.HeartbeatFlusher do
  @moduledoc """
  Writes `last_heartbeat_at` (and the informational overlay figures) in batches
  (doc 07 §5.3, "Cost"). A branch process records each heartbeat here with one
  ETS insert; every 5 s one `UPDATE ... FROM unnest(...)` writes them all, so
  3.3k heartbeats/s become about one statement per node per 5 s instead of 3.3k
  row updates per second.

  The batch also clears `heartbeat_lost`: "the flag is cleared by the next
  heartbeat" (doc 07 §5.3). It touches neither `state` nor `lock_version`, and
  only non-terminal rows, so it cannot interfere with a transition. Lease
  renewal and `merge_progress` changes are transitions and write immediately,
  not through here.

  This is the one raw SQL statement of the coordinator: a read-model update that
  doc 07 §5.3 specifies as a single statement and that an Ash action per row would
  defeat. It is the explicitly reviewed exception to "actions are the only write
  path" in doc 18 §2.
  """
  use GenServer

  require Logger

  @table :steward_heartbeat_dirty
  @default_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records that a heartbeat for the branch was handled. One ETS insert; the latest
  heartbeat per branch wins. A no-op if the flusher is not running.
  """
  def record(%{branch_id: branch_id, org_id: org_id} = entry) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(
        @table,
        {branch_id, org_id, entry.at, entry[:rows] || 0, entry[:bytes] || 0,
         entry[:evidence_gap] || 0}
      )
    end

    :ok
  end

  @doc "Flushes now and returns the number of branches written. For tests and shutdown."
  def flush(timeout \\ 5_000), do: GenServer.call(__MODULE__, :flush, timeout)

  @doc "Branches waiting for the next flush."
  def pending, do: if(:ets.whereis(@table) == :undefined, do: 0, else: :ets.info(@table, :size))

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    interval = Keyword.get(opts, :interval_ms, interval_ms())
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, do_flush(), state}

  @impl true
  def handle_info(:flush, state) do
    do_flush()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    do_flush()
    :ok
  end

  defp interval_ms do
    Application.get_env(:steward, Steward.Coordinator, [])
    |> Keyword.get(:heartbeat_flush_ms, @default_ms)
  end

  defp schedule(:infinity), do: :ok
  defp schedule(ms), do: Process.send_after(self(), :flush, ms)

  defp do_flush do
    rows = :ets.tab2list(@table)

    if rows == [] do
      0
    else
      case write(rows) do
        {:ok, count} ->
          # Delete exactly what was written: a heartbeat that arrived meanwhile has a
          # different tuple and stays for the next batch.
          Enum.each(rows, &:ets.delete_object(@table, &1))
          count

        {:error, error} ->
          Logger.warning(
            "heartbeat flush failed, keeping #{length(rows)} entries: #{inspect(error)}"
          )

          0
      end
    end
  end

  @sql """
  UPDATE branches b
     SET last_heartbeat_at = v.at,
         overlay_rows = v.rows,
         overlay_bytes = v.bytes,
         evidence_gap = v.gap,
         heartbeat_lost = false
    FROM unnest($1::uuid[], $2::uuid[], $3::timestamptz[], $4::bigint[], $5::bigint[], $6::int[])
         AS v(id, org_id, at, rows, bytes, gap)
   WHERE b.id = v.id
     AND b.org_id = v.org_id
     AND b.state IN ('open', 'proposed', 'merging')
  """

  defp write(rows) do
    cols = Enum.unzip(Enum.map(rows, fn {id, org, at, r, b, g} -> {{id, org}, {at, r, b, g}} end))
    {keys, vals} = cols
    {ids, orgs} = Enum.unzip(keys)

    {ats, rs, bs, gs} =
      vals
      |> Enum.map(&Tuple.to_list/1)
      |> Enum.zip()
      |> Enum.map(&Tuple.to_list/1)
      |> List.to_tuple()

    params = [
      Enum.map(ids, &Ecto.UUID.dump!/1),
      Enum.map(orgs, &Ecto.UUID.dump!/1),
      ats,
      rs,
      bs,
      gs
    ]

    case Ecto.Adapters.SQL.query(Steward.Repo, @sql, params) do
      {:ok, %{num_rows: n}} -> {:ok, n}
      {:error, error} -> {:error, error}
    end
  end
end
