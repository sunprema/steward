defmodule Steward.Coordinator.HeartbeatFlusherTest do
  @moduledoc """
  `last_heartbeat_at` is written in batches, not per heartbeat (doc 07 §5.3,
  "Cost"): a handled heartbeat is one ETS insert, and one statement writes them
  all.
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.{Heartbeat, HeartbeatFlusher}

  setup do
    org = org()
    owner = principal(org, :agent)
    target = target(org, principal(org, :human))
    %{org: org, owner: owner, target: target}
  end

  defp hb(branch, extra \\ %{}),
    do:
      Map.merge(
        %{
          branch_id: branch.id,
          overlay_id: branch.overlay_id,
          believed: :open,
          merge_progress: nil
        },
        extra
      )

  defp row(ctx, branch), do: Ash.get!(Branch, branch.id, tenant: ctx.org.id, authorize?: false)

  test "a heartbeat is buffered, not written, until the flush", ctx do
    HeartbeatFlusher.flush()
    b = branch(ctx.org, ctx.target, ctx.owner)

    {:ok, _} =
      Heartbeat.handle(ctx.org.id, hb(b, %{overlay_rows: 7, overlay_bytes: 700, evidence_gap: 2}))

    assert HeartbeatFlusher.pending() == 1
    assert row(ctx, b).last_heartbeat_at == nil

    assert HeartbeatFlusher.flush() == 1
    assert HeartbeatFlusher.pending() == 0

    written = row(ctx, b)
    assert %DateTime{} = written.last_heartbeat_at
    assert {written.overlay_rows, written.overlay_bytes, written.evidence_gap} == {7, 700, 2}
  end

  test "many heartbeats of many branches are one batch; the latest per branch wins", ctx do
    HeartbeatFlusher.flush()
    branches = for _ <- 1..5, do: branch(ctx.org, ctx.target, ctx.owner)

    for b <- branches,
        rows <- [1, 2, 3],
        do: Heartbeat.handle(ctx.org.id, hb(b, %{overlay_rows: rows}))

    assert HeartbeatFlusher.pending() == 5

    assert HeartbeatFlusher.flush() == 5
    for b <- branches, do: assert(row(ctx, b).overlay_rows == 3)
  end

  test "the next heartbeat clears heartbeat_lost (doc 07 §5.3)", ctx do
    HeartbeatFlusher.flush()
    b = branch(ctx.org, ctx.target, ctx.owner)

    Ecto.Adapters.SQL.query!(
      Steward.Repo,
      "UPDATE branches SET heartbeat_lost = true WHERE id = $1",
      [Ecto.UUID.dump!(b.id)]
    )

    assert row(ctx, b).heartbeat_lost

    Heartbeat.handle(ctx.org.id, hb(b))
    HeartbeatFlusher.flush()
    refute row(ctx, b).heartbeat_lost
  end

  test "a flush touches neither state nor lock_version, so it cannot race a transition", ctx do
    b = branch(ctx.org, ctx.target, ctx.owner)
    {:ok, proposed} = BranchProcess.transition(ctx.org.id, b.id, :propose)

    HeartbeatFlusher.flush()
    Heartbeat.handle(ctx.org.id, hb(b))
    HeartbeatFlusher.flush()

    after_flush = row(ctx, b)
    assert after_flush.state == :proposed
    assert after_flush.lock_version == proposed.lock_version

    # And the process's next transition is not refused as stale.
    assert {:ok, %{state: :open}} = BranchProcess.transition(ctx.org.id, b.id, :return_to_open)
  end

  test "heartbeats that are not about a running branch write nothing", ctx do
    HeartbeatFlusher.flush()
    b = branch(ctx.org, ctx.target, ctx.owner)

    {:ok, _} = Heartbeat.handle(ctx.org.id, hb(b, %{overlay_id: Ecto.UUID.generate()}))

    {:ok, _} =
      Heartbeat.handle(ctx.org.id, %{
        branch_id: Ecto.UUID.generate(),
        overlay_id: Ecto.UUID.generate(),
        believed: :open,
        merge_progress: nil
      })

    assert HeartbeatFlusher.pending() == 0

    BranchProcess.transition(ctx.org.id, b.id, :abandon, %{
      reason: :ttl_expired,
      terminal_by_job: "t"
    })

    eventually(fn -> Coordinator.whereis(b.id) == nil end)
    {:ok, _} = Heartbeat.handle(ctx.org.id, hb(b))
    assert HeartbeatFlusher.pending() == 0
  end

  test "a terminal row is never touched, even by a stale buffered entry", ctx do
    HeartbeatFlusher.flush()
    b = branch(ctx.org, ctx.target, ctx.owner)
    Heartbeat.handle(ctx.org.id, hb(b, %{overlay_rows: 9}))

    # The branch ends before the flush.
    BranchProcess.transition(ctx.org.id, b.id, :abandon, %{
      reason: :ttl_expired,
      terminal_by_job: "t"
    })

    assert HeartbeatFlusher.flush() == 0
    assert row(ctx, b).overlay_rows == 0
  end

  test "an entry is kept if a newer heartbeat arrives during the flush's write window", ctx do
    HeartbeatFlusher.flush()
    b = branch(ctx.org, ctx.target, ctx.owner)
    Heartbeat.handle(ctx.org.id, hb(b, %{overlay_rows: 1}))
    HeartbeatFlusher.flush()

    Heartbeat.handle(ctx.org.id, hb(b, %{overlay_rows: 2}))
    assert HeartbeatFlusher.pending() == 1
    HeartbeatFlusher.flush()
    assert row(ctx, b).overlay_rows == 2
  end

  test "a base_snapshot_gone heartbeat abandons the branch with snapshot_lost (doc 13 §6.2 f3)",
       ctx do
    b = branch(ctx.org, ctx.target, ctx.owner)

    assert {:ok, %{authoritative: :abandoned}} =
             Heartbeat.handle(ctx.org.id, hb(b, %{base_snapshot_gone: true}))

    assert %{state: :abandoned, reason: :snapshot_lost} = row(ctx, b)
    eventually(fn -> Coordinator.whereis(b.id) == nil end)
  end

  test "...but not a merging branch whose compensation is persisted: the merge is committed to (§6.5 f7)",
       ctx do
    b = branch(ctx.org, ctx.target, ctx.owner)
    {:ok, _} = BranchProcess.transition(ctx.org.id, b.id, :propose)

    {:ok, _} =
      BranchProcess.transition(ctx.org.id, b.id, :start_merge, %{merge_id: Ecto.UUID.generate()})

    progress = %{
      merge_id: "m",
      rows_confirmed: 1,
      rows_total: 12,
      complete: false,
      compensation_persisted: true
    }

    assert {:ok, %{authoritative: :merging}} =
             Heartbeat.handle(
               ctx.org.id,
               hb(b, %{believed: :merging, base_snapshot_gone: true, merge_progress: progress})
             )

    assert row(ctx, b).state == :merging

    # Before the checkpoint it is abandoned instead.
    assert {:ok, %{authoritative: :abandoned}} =
             Heartbeat.handle(
               ctx.org.id,
               hb(b, %{
                 believed: :merging,
                 base_snapshot_gone: true,
                 merge_progress: %{progress | compensation_persisted: false}
               })
             )
  end
end
