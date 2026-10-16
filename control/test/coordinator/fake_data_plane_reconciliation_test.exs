defmodule Steward.Coordinator.FakeDataPlaneReconciliationTest do
  @moduledoc """
  The two halves of doc 13 §6.8 meeting: the E13 fake data plane heartbeats the
  real coordinator and reacts to its replies by the data plane's table. This is
  the control plane's check that the table, as the data plane reads it, and as
  the coordinator answers it, agree end to end. Rows of doc 13 §6.1–6.8 are
  named in the test names.
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.Heartbeat
  alias Steward.FakeDataPlane
  alias Steward.Plane.V1

  setup do
    org = org()
    owner = principal(org, :agent)
    target = target(org, principal(org, :human))
    {:ok, dp} = FakeDataPlane.start_link(data_plane_id: "dp-1")
    %{org: org, owner: owner, target: target, dp: dp}
  end

  # --- helpers ---------------------------------------------------------------

  defp flush(acc \\ []) do
    receive do
      {:data_plane_message, "dp-1", %V1.DataPlaneMessage{body: body}} -> flush([body | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  # What the engine does every ~30 s: heartbeat each overlay, apply the answer.
  defp exchange(ctx) do
    FakeDataPlane.heartbeat(ctx.dp)

    for {:heartbeat, hb} <- flush() do
      {:ok, reply} = Heartbeat.handle(ctx.org.id, from_proto(hb))
      FakeDataPlane.deliver(ctx.dp, to_proto(hb, reply))
      reply
    end
  end

  defp deliver(ctx, id, body),
    do: FakeDataPlane.deliver(ctx.dp, %V1.Instruction{instruction_id: id, body: body})

  # The create flow of doc 13 §6.1: the control plane picks the branch id, the
  # data plane the overlay id, and the row is written last.
  defp open_branch(ctx, opts \\ []) do
    branch_id = Ecto.UUID.generate()

    deliver(
      ctx,
      "init-#{branch_id}",
      {:initialise_overlay, %V1.InitialiseOverlay{branch_id: branch_id, target_id: ctx.target.id}}
    )

    [{:instruction_result, %{body: {:overlay_initialised, %{overlay_id: overlay_id}}}}] = flush()

    unless opts[:orphan] do
      branch(ctx.org, ctx.target, ctx.owner, id: branch_id, overlay_id: overlay_id)
    end

    deliver(
      ctx,
      "route-#{branch_id}",
      {:routing_upsert,
       %V1.RoutingUpsert{branch_id: branch_id, overlay_id: overlay_id, state: :AUTH_OPEN}}
    )

    flush()
    %{id: branch_id, overlay_id: overlay_id}
  end

  defp transition!(ctx, branch, action, params \\ %{}) do
    {:ok, record} = BranchProcess.transition(ctx.org.id, branch.id, action, params)
    record
  end

  defp overlay(ctx, branch), do: FakeDataPlane.overlay(ctx.dp, branch.id)

  # --- scenarios -------------------------------------------------------------

  test "in step: an open branch and an open overlay exchange no-ops", ctx do
    b = open_branch(ctx)
    assert [%{authoritative: :open, freeze: false}] = exchange(ctx)
    assert %{believed: :open, frozen: false} = overlay(ctx, b)
    assert :ok = FakeDataPlane.write(ctx.dp, b.id)
  end

  test "6.2 f6 / 6.3 f2: the branch is proposed; the data plane learns it from the reply and freezes",
       ctx do
    b = open_branch(ctx)
    assert :ok = FakeDataPlane.write(ctx.dp, b.id)
    transition!(ctx, b, :propose)

    # The window: the data plane has not heard yet, and a write still lands.
    assert :ok = FakeDataPlane.write(ctx.dp, b.id)

    assert [%{authoritative: :proposed, freeze: true}] = exchange(ctx)
    assert %{believed: :proposed, frozen: true, freeze_marker: true} = overlay(ctx, b)
    assert {:error, :branch_frozen} = FakeDataPlane.write(ctx.dp, b.id)
  end

  test "withdraw: proposed → open, and the data plane unfreezes and drops the marker", ctx do
    b = open_branch(ctx)
    transition!(ctx, b, :propose)
    exchange(ctx)
    assert {:error, :branch_frozen} = FakeDataPlane.write(ctx.dp, b.id)

    transition!(ctx, b, :return_to_open)
    assert [%{authoritative: :open}] = exchange(ctx)
    assert %{believed: :open, frozen: false, freeze_marker: false} = overlay(ctx, b)
    assert :ok = FakeDataPlane.write(ctx.dp, b.id)
  end

  test "6.7 f2: abandoned, the data plane stops accepting writes; the terminal branch has no process",
       ctx do
    b = open_branch(ctx)
    transition!(ctx, b, :abandon, %{reason: :ttl_expired, terminal_by_job: "ttl"})
    eventually(fn -> Coordinator.whereis(b.id) == nil end)

    assert [%{authoritative: :abandoned}] = exchange(ctx)
    assert {:error, :branch_abandoned} = FakeDataPlane.write(ctx.dp, b.id)
    assert %{believed: :done, terminal: :abandoned} = overlay(ctx, b)

    # Answered from the row; answering must not have recreated the process.
    assert Coordinator.whereis(b.id) == nil
  end

  test "6.1 f4/f5: an orphan overlay (no branch row) is told `unknown` and garbage-collected",
       ctx do
    orphan = open_branch(ctx, orphan: true)
    live = open_branch(ctx)

    replies = exchange(ctx)
    assert Enum.sort(Enum.map(replies, & &1.authoritative)) == [:open, :unknown]

    assert overlay(ctx, orphan) == nil
    assert overlay(ctx, live)
    assert [{orphan_id, _, {:heartbeat, :unknown}}] = FakeDataPlane.gc_log(ctx.dp)
    assert orphan_id == orphan.id
  end

  test "an overlay with the right branch id but another overlay id is dead", ctx do
    b = open_branch(ctx)
    # A retry created a second overlay under the same branch id on the data plane.
    other = uuid()
    :sys.replace_state(ctx.dp, fn s -> put_in(s.overlays[b.id].overlay_id, other) end)

    assert [%{authoritative: :unknown}] = exchange(ctx)
    assert overlay(ctx, b) == nil
  end

  test "6.8 alert: the data plane finished a merge the control plane never heard of; it alerts, repairs nothing, and the data plane holds",
       ctx do
    b = open_branch(ctx)
    transition!(ctx, b, :propose)
    exchange(ctx)

    deliver(
      ctx,
      "merge",
      {:merge, %V1.Merge{merge_id: "m1", changeset_id: "c1", branch_id: b.id}}
    )

    flush()
    assert %{believed: :done} = overlay(ctx, b)

    # The data plane is `done`; the control plane still says `proposed`.
    assert [%{authoritative: :proposed, actions: %{alert: :ok}}] = exchange(ctx)

    assert %{held: true, frozen: true} = overlay(ctx, b)
    assert %{state: :proposed} = Ash.get!(Branch, b.id, tenant: ctx.org.id, authorize?: false)

    events =
      Ash.read!(Steward.Core.Audit.Event, tenant: ctx.org.id, actor: System.new(:api, ctx.org.id))

    assert Enum.any?(events, &(&1.type == "heartbeat.anomaly" and &1.aggregate_id == b.id))
  end

  test "6.5 f3: merging branch, merge instruction lost; the reply asks for a re-send and keeps the data plane frozen",
       ctx do
    b = open_branch(ctx)
    transition!(ctx, b, :propose)
    transition!(ctx, b, :start_merge, %{merge_id: uuid()})

    # The data plane saw `open` still (its freeze never arrived, nor the merge).
    assert [
             %{
               authoritative: :merging,
               freeze: true,
               actions: %{resend_merge: {:error, :not_implemented}}
             }
           ] = exchange(ctx)

    assert %{believed: :proposed, frozen: true, expecting_merge: true} = overlay(ctx, b)
  end

  test "the heartbeat of a branch whose process died rebuilds it", ctx do
    b = open_branch(ctx)
    exchange(ctx)
    pid = Coordinator.whereis(b.id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    stop_all()

    assert Coordinator.whereis(b.id) == nil
    assert [%{authoritative: :open}] = exchange(ctx)
    assert Coordinator.whereis(b.id)
  end
end
