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
end
