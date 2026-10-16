defmodule Steward.FakeDataPlane.Matrix do
  @moduledoc """
  The data plane's side of doc 13 §6.8: what it does when a heartbeat reply
  gives the control plane's authoritative state for a branch it believes to be
  in some other state. "The data plane **must** adopt the authoritative state.
  It never argues."

  `react(believed, authoritative)` returns `{new_believed, effects}` for each
  of the 5 × 8 cells of the doc's table. Effects are atoms the fake applies to
  an overlay (and records, so tests can assert on them):

    * `:freeze`, `:write_freeze_marker`, `:unfreeze`, `:drop_freeze_marker`
    * `:mark_dead`, `:gc_overlay` (now), `:gc_after_retention`, `:gc_when_safe`
    * `:set_done`
    * `:renew_lease`, `:report_progress`, `:report_progress_complete`
    * `:expect_merge_instruction`: the control plane re-sends `Merge`
    * `:stop_apply_if_before_checkpoint`, `:continue_apply_after_checkpoint`
    * `:alert`: a cell the design says cannot happen. The fake then *holds* the
      overlay (`held: true`) and takes no further automatic action, because
      "alert" rows "must not be auto-repaired" (doc 13 §6.8).

  This module is the oracle `FakeDataPlaneMatrixTest` checks against the doc's
  table, cell by cell. It is deliberately independent of the control plane's own
  `Heartbeat.decide/3` (E3), which is the *other* half of the same table.
  """

  @believed [:open, :proposed, :merging, :done, :dead]
  @authoritative [:unknown, :open, :proposed, :merging, :merged, :rejected, :abandoned, :closed]

  @table %{
    open: %{
      unknown: {:dead, [:mark_dead, :gc_overlay]},
      open: {:open, []},
      proposed: {:proposed, [:freeze, :write_freeze_marker]},
      merging: {:proposed, [:freeze, :write_freeze_marker, :expect_merge_instruction]},
      merged: {:done, [:freeze, :set_done, :gc_after_retention]},
      rejected: {:done, [:freeze, :set_done, :gc_after_retention]},
      abandoned: {:done, [:freeze, :set_done, :gc_after_retention]},
      closed: {:dead, [:mark_dead, :gc_overlay]}
    },
    proposed: %{
      unknown: {:dead, [:mark_dead, :gc_overlay]},
      open: {:open, [:unfreeze, :drop_freeze_marker]},
      proposed: {:proposed, []},
      merging: {:proposed, [:expect_merge_instruction]},
      merged: {:done, [:set_done]},
      rejected: {:done, [:set_done]},
      abandoned: {:done, [:set_done]},
      closed: {:dead, [:mark_dead, :gc_overlay]}
    },
    merging: %{
      unknown: {:dead, [:mark_dead, :alert]},
      open:
        {:merging, [:alert, :stop_apply_if_before_checkpoint, :continue_apply_after_checkpoint]},
      proposed: {:merging, [:stop_apply_if_before_checkpoint, :continue_apply_after_checkpoint]},
      merging: {:merging, [:renew_lease, :report_progress]},
      merged: {:done, [:set_done]},
      rejected: {:merging, [:alert]},
      abandoned: {:merging, [:alert]},
      closed: {:dead, [:mark_dead, :gc_overlay]}
    },
    done: %{
      unknown: {:dead, [:mark_dead, :gc_overlay]},
      open: {:done, [:alert]},
      proposed: {:done, [:alert]},
      merging: {:done, [:report_progress_complete]},
      merged: {:done, []},
      rejected: {:done, []},
      abandoned: {:done, []},
      closed: {:dead, [:mark_dead, :gc_overlay]}
    },
    dead: %{
      unknown: {:dead, [:gc_when_safe]},
      open: {:dead, [:alert]},
      proposed: {:dead, [:alert]},
      merging: {:dead, [:alert]},
      merged: {:dead, [:gc_overlay]},
      rejected: {:dead, [:gc_overlay]},
      abandoned: {:dead, [:gc_overlay]},
      closed: {:dead, [:gc_overlay]}
    }
  }

  def believed_states, do: @believed
  def authoritative_states, do: @authoritative
  def table, do: @table

  @doc "The reaction of a data plane that believes `believed` to a reply saying `authoritative`."
  def react(believed, authoritative)
      when believed in @believed and authoritative in @authoritative do
    @table |> Map.fetch!(believed) |> Map.fetch!(authoritative)
  end

  @doc "True for the cells doc 13 §6.8 marks **alert**."
  def alert?(believed, authoritative) do
    {_, effects} = react(believed, authoritative)
    :alert in effects
  end

  # --- protobuf enum <-> atoms --------------------------------------------

  @doc "`Steward.Plane.V1.BelievedState` atom to the matrix's atom."
  def from_proto_believed(:OPEN), do: :open
  def from_proto_believed(:PROPOSED), do: :proposed
  def from_proto_believed(:MERGING), do: :merging
  def from_proto_believed(:DONE), do: :done
  def from_proto_believed(:DEAD), do: :dead

  def to_proto_believed(:open), do: :OPEN
  def to_proto_believed(:proposed), do: :PROPOSED
  def to_proto_believed(:merging), do: :MERGING
  def to_proto_believed(:done), do: :DONE
  def to_proto_believed(:dead), do: :DEAD

  @doc "`Steward.Plane.V1.AuthoritativeState` atom to the matrix's atom."
  def from_proto_authoritative(:UNKNOWN), do: :unknown
  def from_proto_authoritative(:AUTH_OPEN), do: :open
  def from_proto_authoritative(:AUTH_PROPOSED), do: :proposed
  def from_proto_authoritative(:AUTH_MERGING), do: :merging
  def from_proto_authoritative(:MERGED), do: :merged
  def from_proto_authoritative(:REJECTED), do: :rejected
  def from_proto_authoritative(:ABANDONED), do: :abandoned
  def from_proto_authoritative(:CLOSED), do: :closed

  def to_proto_authoritative(:unknown), do: :UNKNOWN
  def to_proto_authoritative(:open), do: :AUTH_OPEN
  def to_proto_authoritative(:proposed), do: :AUTH_PROPOSED
  def to_proto_authoritative(:merging), do: :AUTH_MERGING
  def to_proto_authoritative(:merged), do: :MERGED
  def to_proto_authoritative(:rejected), do: :REJECTED
  def to_proto_authoritative(:abandoned), do: :ABANDONED
  def to_proto_authoritative(:closed), do: :CLOSED
end
