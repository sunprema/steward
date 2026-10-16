defmodule Steward.FakeDataPlane.MatrixTest do
  @moduledoc """
  Doc 13 §6.8, transcribed cell by cell: all 5 × 8 reactions of a data plane to
  a heartbeat reply. A change to the doc's table must change this file (doc 07
  §10 applies the same rule to the control plane's half, `Heartbeat.decide/3`).

  Each expectation is `{believed after, [effects that must be present], alert?}`;
  the doc's text for the cell is in the comment.
  """
  use ExUnit.Case, async: true

  alias Steward.FakeDataPlane.Matrix

  @doc_table %{
    open: %{
      # mark dead, GC overlay
      unknown: {:dead, [:mark_dead, :gc_overlay], false},
      # no-op
      open: {:open, [], false},
      # freeze writes, write freeze marker
      proposed: {:proposed, [:freeze, :write_freeze_marker], false},
      # freeze; expect merge instruction (re-sent by CP)
      merging: {:proposed, [:freeze, :expect_merge_instruction], false},
      # freeze; set done; GC after retention
      merged: {:done, [:freeze, :set_done, :gc_after_retention], false},
      rejected: {:done, [:freeze, :set_done, :gc_after_retention], false},
      abandoned: {:done, [:freeze, :set_done, :gc_after_retention], false},
      # mark dead, GC overlay
      closed: {:dead, [:mark_dead, :gc_overlay], false}
    },
    proposed: %{
      # mark dead, GC overlay
      unknown: {:dead, [:mark_dead, :gc_overlay], false},
      # unfreeze writes; drop freeze marker
      open: {:open, [:unfreeze, :drop_freeze_marker], false},
      # no-op
      proposed: {:proposed, [], false},
      # expect merge instruction (re-sent by CP)
      merging: {:proposed, [:expect_merge_instruction], false},
      # set done
      merged: {:done, [:set_done], false},
      rejected: {:done, [:set_done], false},
      abandoned: {:done, [:set_done], false},
      # mark dead, GC
      closed: {:dead, [:mark_dead, :gc_overlay], false}
    },
    merging: %{
      # mark dead; **alert** (compensation may exist for an unknown branch)
      unknown: {:dead, [:mark_dead], true},
      # **alert**; stop apply if before compensation checkpoint; otherwise continue and alert
      open:
        {:merging, [:stop_apply_if_before_checkpoint, :continue_apply_after_checkpoint], true},
      # stop apply if before checkpoint; otherwise continue (CP state is stale)
      proposed:
        {:merging, [:stop_apply_if_before_checkpoint, :continue_apply_after_checkpoint], false},
      # renew lease; report progress
      merging: {:merging, [:renew_lease, :report_progress], false},
      # set done
      merged: {:done, [:set_done], false},
      # **alert** (should be impossible after checkpoint)
      rejected: {:merging, [], true},
      # **alert** (abandon of `merging` is refused)
      abandoned: {:merging, [], true},
      # mark dead, GC
      closed: {:dead, [:mark_dead, :gc_overlay], false}
    },
    done: %{
      # mark dead, GC
      unknown: {:dead, [:mark_dead, :gc_overlay], false},
      # **alert** (CP lost a terminal transition)
      open: {:done, [], true},
      proposed: {:done, [], true},
      # report progress complete; CP advances
      merging: {:done, [:report_progress_complete], false},
      # no-op
      merged: {:done, [], false},
      rejected: {:done, [], false},
      abandoned: {:done, [], false},
      # mark dead, GC
      closed: {:dead, [:mark_dead, :gc_overlay], false}
    },
    dead: %{
      # GC when safe
      unknown: {:dead, [:gc_when_safe], false},
      # **alert**
      open: {:dead, [], true},
      proposed: {:dead, [], true},
      merging: {:dead, [], true},
      # GC
      merged: {:dead, [:gc_overlay], false},
      rejected: {:dead, [:gc_overlay], false},
      abandoned: {:dead, [:gc_overlay], false},
      closed: {:dead, [:gc_overlay], false}
    }
  }

  test "the table has exactly the doc's 5 × 8 cells" do
    assert Matrix.believed_states() |> Enum.sort() == Map.keys(@doc_table) |> Enum.sort()

    for believed <- Matrix.believed_states() do
      assert Map.keys(@doc_table[believed]) |> Enum.sort() ==
               Enum.sort(Matrix.authoritative_states())
    end
  end

  for {believed, row} <- @doc_table, {authoritative, {new_believed, effects, alert?}} <- row do
    test "#{believed} × #{authoritative}" do
      {actual_believed, actual_effects} = Matrix.react(unquote(believed), unquote(authoritative))

      assert actual_believed == unquote(new_believed)
      for effect <- unquote(effects), do: assert(effect in actual_effects, "missing #{effect}")
      assert Matrix.alert?(unquote(believed), unquote(authoritative)) == unquote(alert?)
    end
  end

  test "the proto enums round-trip" do
    for b <- Matrix.believed_states(),
        do: assert(b |> Matrix.to_proto_believed() |> Matrix.from_proto_believed() == b)

    for a <- Matrix.authoritative_states(),
        do: assert(a |> Matrix.to_proto_authoritative() |> Matrix.from_proto_authoritative() == a)
  end
end
