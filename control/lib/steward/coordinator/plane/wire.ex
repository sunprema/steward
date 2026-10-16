defmodule Steward.Coordinator.Plane.Wire do
  @moduledoc """
  Between `steward.plane.v1` messages and the plain maps the coordinator works
  with. Protobuf enums become the atoms `HeartbeatMatrix` is declared in; nothing
  here interprets a message.
  """
  alias Steward.Plane.V1

  @believed %{OPEN: :open, PROPOSED: :proposed, MERGING: :merging, DONE: :done, DEAD: :dead}
  @authoritative %{
    unknown: :UNKNOWN,
    open: :AUTH_OPEN,
    proposed: :AUTH_PROPOSED,
    merging: :AUTH_MERGING,
    merged: :MERGED,
    rejected: :REJECTED,
    abandoned: :ABANDONED,
    closed: :CLOSED
  }

  @doc "A `Heartbeat` as the map `Steward.Coordinator.Heartbeat.handle/2` takes; nil if its believed state is unspecified."
  def heartbeat(%V1.Heartbeat{} = hb) do
    with {:ok, believed} <- Map.fetch(@believed, hb.believed_state) do
      {:ok,
       %{
         branch_id: hb.branch_id,
         overlay_id: hb.overlay_id,
         believed: believed,
         overlay_rows: hb.overlay_rows,
         overlay_bytes: hb.overlay_size_bytes,
         evidence_gap: hb.evidence_gap,
         base_snapshot_gone: hb.base_snapshot_gone,
         merge_progress: merge_progress(hb.merge_progress)
       }}
    else
      :error -> {:error, :unspecified_believed_state}
    end
  end

  defp merge_progress(nil), do: nil

  defp merge_progress(%V1.MergeProgress{} = p) do
    %{
      merge_id: p.merge_id,
      rows_confirmed: p.rows_confirmed,
      rows_total: p.rows_total,
      complete: p.complete,
      compensation_persisted: p.compensation_persisted,
      last_error_code: p.last_error_code
    }
  end

  @doc "The coordinator's reply as a `HeartbeatReply`."
  def heartbeat_reply(%V1.Heartbeat{} = hb, reply) do
    %V1.HeartbeatReply{
      branch_id: hb.branch_id,
      overlay_id: hb.overlay_id,
      authoritative_state: Map.fetch!(@authoritative, reply.authoritative),
      lease_renewed: reply.lease_renewed,
      freeze: reply.freeze,
      stale: reply.stale
    }
  end

  @doc "Wraps a downstream body in a `ControlPlaneMessage`."
  def control_message(%V1.Instruction{} = i), do: %V1.ControlPlaneMessage{body: {:instruction, i}}

  def control_message(%V1.HeartbeatReply{} = r),
    do: %V1.ControlPlaneMessage{body: {:heartbeat_reply, r}}

  def control_message(%V1.ControlPlaneMessage{} = m), do: m

  # --- ChangesetReport → changeset columns (doc 12 §5) ---------------------------

  @doc """
  The `Changeset.record_computed` attributes for a report: `summary`
  (`steward:changeset-summary/1`) and `impact` (`steward:changeset-impact/1`) as
  JSON-shaped maps, the row-delta digest, and evidence references. Typed
  aggregates, names, counts and digests only: no field of the report can carry a
  row (doc 13 invariant 9).
  """
  def computed_attrs(%V1.ChangesetReport{} = report) do
    summary = report.summary || %V1.Summary{}

    %{
      summary: summary_map(summary, report),
      impact: %{format_version: 1, metrics: Enum.map(report.impact, &metric/1)},
      conflicts_count: report.conflicts_count,
      partial_keys_count: summary.partial_keys_count,
      reversible: report.reversible,
      row_delta_digest: report.row_delta_digest,
      evidence_refs:
        Enum.map(
          report.evidence_refs,
          &%{path: &1.path, digest: Base.encode16(&1.digest, case: :lower)}
        )
    }
  end

  defp summary_map(%V1.Summary{} = s, report) do
    %{
      format_version: 1,
      truncated: s.truncated,
      reversible: report.reversible,
      conflicts_count: report.conflicts_count,
      partial_keys_count: s.partial_keys_count,
      touches_revertable_merges: report.touches_revertable_merges,
      tables:
        Enum.map(
          s.tables,
          &Map.take(&1, [
            :table_name,
            :inserts,
            :updates,
            :deletes,
            :noop_updates,
            :invalid_before_images
          ])
        ),
      columns: Enum.map(s.columns, &column/1)
    }
    |> put_unless_nil(:staleness_check, s.staleness_check)
    |> put_unless_nil(:conflicts_ref, s.conflicts_ref)
  end

  defp column(%V1.ColumnSummary{} = c) do
    c
    |> Map.take([
      :table_name,
      :column_name,
      :changed_count,
      :null_delta,
      :numeric_delta_min,
      :numeric_delta_max,
      :numeric_delta_median,
      :numeric_pct_median,
      :distinct_before,
      :distinct_after
    ])
    |> then(fn base ->
      # `distinct_values` only when the engine sent some: it sends them only for allow-listed columns.
      if c.distinct_values == [],
        do: base,
        else:
          Map.put(
            base,
            :distinct_values,
            Enum.map(c.distinct_values, &Map.take(&1, [:value, :count_before, :count_after]))
          )
    end)
  end

  defp metric(%V1.ImpactMetric{} = m), do: %{name: m.name, value: m.value, error: m.error}

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
