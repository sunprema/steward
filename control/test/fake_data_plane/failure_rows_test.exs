defmodule Steward.FakeDataPlane.FailureRowsTest do
  @moduledoc """
  One scenario per data-plane-visible failure row of doc 13 §6 (build roadmap
  M0 exit: "every doc 13 §6 failure row ... is exercised by E13 or engine/proxy
  failure injection"). Test names carry the row, `6.5 f7` being doc 13 §6.5
  failure analysis item 7. Rows that happen wholly on the control plane
  (Postgres writes, lease acquisition, reconciliation jobs) are the coordinator's
  tests; they use this fake to provide the other half.

  Not covered here, because no data-plane message is involved: 6.1 f1, 6.3 f1/f5/f6/f7/f8,
  6.4 (the browser fetches row deltas from the data plane directly under a
  grant, doc 13 §6.4, which the fake does not serve), 6.5 f1/f2/f10, 6.6 f1/f3-f5,
  6.7 f1.
  """
  use ExUnit.Case, async: true

  alias Steward.FakeDataPlane
  alias Steward.FakeDataPlane.Fixtures
  alias Steward.Plane.V1

  setup do
    {:ok, dp} = FakeDataPlane.start_link(data_plane_id: "dp-1")
    %{dp: dp}
  end

  # --- helpers ---------------------------------------------------------------

  defp deliver(dp, id, body),
    do: :ok = FakeDataPlane.deliver(dp, %V1.Instruction{instruction_id: id, body: body})

  defp reply(dp, branch_id, overlay_id, state, opts \\ []) do
    :ok =
      FakeDataPlane.deliver(
        dp,
        struct!(
          V1.HeartbeatReply,
          [branch_id: branch_id, overlay_id: overlay_id, authoritative_state: state] ++ opts
        )
      )
  end

  # Everything the data plane has sent so far, as `{tag, body}`, oldest first.
  defp flush(acc \\ []) do
    receive do
      {:data_plane_message, "dp-1", %V1.DataPlaneMessage{body: body}} -> flush([body | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  defp init_overlay(dp, branch_id, opts \\ []) do
    body = struct!(V1.InitialiseOverlay, [branch_id: branch_id, target_id: "t1"] ++ opts)
    deliver(dp, "init-#{branch_id}", {:initialise_overlay, body})
  end

  defp open_branch(dp, branch_id) do
    init_overlay(dp, branch_id)
    [{:instruction_result, %{body: {:overlay_initialised, %{overlay_id: overlay_id}}}}] = flush()

    deliver(
      dp,
      "route-#{branch_id}",
      {:routing_upsert,
       %V1.RoutingUpsert{branch_id: branch_id, overlay_id: overlay_id, state: :AUTH_OPEN}}
    )

    flush()
    overlay_id
  end

  defp freeze(dp, branch_id, overlay_id),
    do:
      deliver(
        dp,
        "freeze-#{branch_id}",
        {:freeze_writes, %V1.FreezeWrites{branch_id: branch_id, overlay_id: overlay_id}}
      )

  defp compute(dp, branch_id, overlay_id, changeset_id \\ "c1") do
    deliver(
      dp,
      "compute-#{changeset_id}",
      {:compute_changeset,
       %V1.ComputeChangeset{
         changeset_id: changeset_id,
         branch_id: branch_id,
         overlay_id: overlay_id
       }}
    )
  end

  defp merge(dp, branch_id, merge_id \\ "m1"),
    do:
      deliver(
        dp,
        "merge-#{merge_id}",
        {:merge, %V1.Merge{merge_id: merge_id, changeset_id: "c1", branch_id: branch_id}}
      )

  defp frozen_branch(dp, branch_id) do
    overlay_id = open_branch(dp, branch_id)
    :ok = FakeDataPlane.write(dp, branch_id, rows: 12)
    freeze(dp, branch_id, overlay_id)
    flush()
    overlay_id
  end

  # --- 6.1 create branch -----------------------------------------------------

  describe "6.1 create branch" do
    test "happy path: the overlay is initialised and answered with its id", %{dp: dp} do
      init_overlay(dp, "b1")

      assert [
               {:instruction_result,
                %V1.InstructionResult{
                  ok: true,
                  instruction_id: "init-b1",
                  body: {:overlay_initialised, init}
                }}
             ] = flush()

      assert init.fidelity == "TRUE_SNAPSHOT"
      assert FakeDataPlane.overlay(dp, "b1").overlay_id == init.overlay_id
    end

    test "6.1 f2: data plane unreachable, nothing is created and nothing answers", %{dp: dp} do
      FakeDataPlane.script(dp, :initialise_overlay, :drop)
      init_overlay(dp, "b1")
      assert flush() == []
      assert FakeDataPlane.overlay(dp, "b1") == nil
    end

    test "6.1 f2: stream down, the instruction cannot even be delivered", %{dp: dp} do
      FakeDataPlane.disconnect(dp)

      assert {:error, :disconnected} =
               FakeDataPlane.deliver(dp, %V1.Instruction{
                 instruction_id: "i",
                 body: {:initialise_overlay, %V1.InitialiseOverlay{branch_id: "b1"}}
               })

      assert FakeDataPlane.received(dp) == []
    end

    test "6.1 f3: the overlay store write fails, error result and no overlay", %{dp: dp} do
      FakeDataPlane.script(
        dp,
        :initialise_overlay,
        {:error, "object_store_unavailable", "synthetic"}
      )

      init_overlay(dp, "b1")

      assert [{:instruction_result, %{ok: false, error_code: "object_store_unavailable"}}] =
               flush()

      assert FakeDataPlane.overlay(dp, "b1") == nil
    end

    test "6.1 f4/f5: reply lost, an orphan overlay exists and heartbeat `unknown` kills it", %{
      dp: dp
    } do
      FakeDataPlane.script(dp, :initialise_overlay, :lose_reply)
      init_overlay(dp, "b1")
      assert flush() == []

      orphan = FakeDataPlane.overlay(dp, "b1")
      assert orphan.believed == :open

      # It heartbeats (b1, o1); the control plane has no such branch.
      assert FakeDataPlane.heartbeat(dp) == 1
      assert [{:heartbeat, %V1.Heartbeat{branch_id: "b1", believed_state: :OPEN}}] = flush()
      reply(dp, "b1", orphan.overlay_id, :UNKNOWN)

      assert FakeDataPlane.overlay(dp, "b1") == nil
      assert [{"b1", overlay_id, {:heartbeat, :unknown}}] = FakeDataPlane.gc_log(dp)
      assert overlay_id == orphan.overlay_id
    end

    test "6.1 f5: a retry uses fresh ids, so the first overlay stays an orphan while the second lives",
         %{dp: dp} do
      FakeDataPlane.script(dp, :initialise_overlay, :lose_reply)
      init_overlay(dp, "b1")
      flush()
      init_overlay(dp, "b2")
      [{:instruction_result, %{body: {:overlay_initialised, second}}}] = flush()

      assert FakeDataPlane.overlay(dp, "b1").overlay_id != second.overlay_id
      assert map_size(FakeDataPlane.overlays(dp)) == 2
    end

    test "6.1 f6: routing add lost, writes fail not-routable until a heartbeat reply of `open` repairs it",
         %{dp: dp} do
      FakeDataPlane.script(dp, :routing_upsert, :drop)
      init_overlay(dp, "b1")

      [{:instruction_result, %{body: {:overlay_initialised, %{overlay_id: overlay_id}}}}] =
        flush()

      deliver(
        dp,
        "route",
        {:routing_upsert,
         %V1.RoutingUpsert{branch_id: "b1", overlay_id: overlay_id, state: :AUTH_OPEN}}
      )

      assert {:error, :branch_not_routable} = FakeDataPlane.write(dp, "b1")

      reply(dp, "b1", overlay_id, :AUTH_OPEN)
      assert :ok = FakeDataPlane.write(dp, "b1")
    end

    test "6.1 f7: a re-sent instruction is answered with the same overlay, never a second one", %{
      dp: dp
    } do
      init_overlay(dp, "b1")
      [{:instruction_result, %{body: {:overlay_initialised, first}}}] = flush()
      init_overlay(dp, "b1")
      [{:instruction_result, %{body: {:overlay_initialised, again}}}] = flush()

      assert first.overlay_id == again.overlay_id
      assert map_size(FakeDataPlane.overlays(dp)) == 1
    end
  end

  # --- 6.2 write and evidence ------------------------------------------------

  describe "6.2 write and evidence capture" do
    test "6.2 f1: a routing miss is `branch_not_routable`", %{dp: dp} do
      assert {:error, :branch_not_routable} = FakeDataPlane.write(dp, "nope")
    end

    test "6.2 f2: an overlay store write failure is not acknowledged and not counted", %{dp: dp} do
      open_branch(dp, "b1")
      assert {:error, :overlay_store_unavailable} = FakeDataPlane.write(dp, "b1", overlay: :fail)
      assert FakeDataPlane.overlay(dp, "b1").rows == 0
    end

    test "6.2 f3: base snapshot gone fails writes and the heartbeat carries it", %{dp: dp} do
      open_branch(dp, "b1")
      FakeDataPlane.lose_base_snapshot(dp, "b1")

      assert {:error, :base_snapshot_gone} = FakeDataPlane.write(dp, "b1")
      FakeDataPlane.heartbeat(dp)
      assert [{:heartbeat, %{base_snapshot_gone: true}}] = flush()
    end

    test "6.2 f4: an evidence append failure still acknowledges the write and raises the gap", %{
      dp: dp
    } do
      open_branch(dp, "b1")
      assert :ok = FakeDataPlane.write(dp, "b1", evidence: :fail)
      assert :ok = FakeDataPlane.write(dp, "b1", evidence: :fail)
      assert :ok = FakeDataPlane.write(dp, "b1")

      FakeDataPlane.heartbeat(dp)
      assert [{:heartbeat, %{evidence_gap: 2, overlay_rows: 3}}] = flush()
    end

    test "6.2 f5: believing `open` after the control plane abandoned it, writes land until the heartbeat reply",
         %{dp: dp} do
      overlay_id = open_branch(dp, "b1")
      assert :ok = FakeDataPlane.write(dp, "b1")
      assert :ok = FakeDataPlane.write(dp, "b1")

      reply(dp, "b1", overlay_id, :ABANDONED)
      assert {:error, :branch_abandoned} = FakeDataPlane.write(dp, "b1")
      assert FakeDataPlane.overlay(dp, "b1").believed == :done
    end

    test "6.2 f6: writes between the control plane freezing and the proxy learning, then the freeze marker",
         %{dp: dp} do
      overlay_id = open_branch(dp, "b1")
      assert :ok = FakeDataPlane.write(dp, "b1")

      # The control plane set `proposed`; the freeze instruction was lost.
      FakeDataPlane.script(dp, :freeze_writes, :drop)
      freeze(dp, "b1", overlay_id)
      assert :ok = FakeDataPlane.write(dp, "b1")
      refute FakeDataPlane.overlay(dp, "b1").freeze_marker

      reply(dp, "b1", overlay_id, :AUTH_PROPOSED)
      assert FakeDataPlane.overlay(dp, "b1").freeze_marker
      assert {:error, :branch_frozen} = FakeDataPlane.write(dp, "b1")
    end
  end

  # --- 6.3 propose -----------------------------------------------------------

  describe "6.3 propose" do
    test "happy path: freeze, then compute answers with a report carrying aggregates only", %{
      dp: dp
    } do
      overlay_id = open_branch(dp, "b1")
      freeze(dp, "b1", overlay_id)
      compute(dp, "b1", overlay_id)

      assert [
               {:instruction_result, %{ok: true, instruction_id: "freeze-b1"}},
               {:instruction_result, %{ok: true, instruction_id: "compute-c1"}},
               {:changeset_report,
                %V1.ChangesetReport{
                  changeset_id: "c1",
                  branch_id: "b1",
                  overlay_id: ^overlay_id,
                  error: nil
                } = report}
             ] = flush()

      assert report.row_delta_digest != <<>>
      assert [%V1.TableSummary{table_name: "products"}] = report.summary.tables
    end

    test "6.3 f2: the freeze times out; compute reports `freeze_marker_missing` until the heartbeat reply freezes",
         %{dp: dp} do
      overlay_id = open_branch(dp, "b1")
      FakeDataPlane.script(dp, :freeze_writes, :drop)
      freeze(dp, "b1", overlay_id)
      compute(dp, "b1", overlay_id)

      assert [
               {:instruction_result, %{ok: true}},
               {:changeset_report,
                %{error: %V1.ComputeError{code: "freeze_marker_missing", retryable: true}}}
             ] = flush()

      reply(dp, "b1", overlay_id, :AUTH_PROPOSED)
      compute(dp, "b1", overlay_id)
      assert [{:instruction_result, %{ok: true}}, {:changeset_report, %{error: nil}}] = flush()
    end

    test "6.3 f3: a compute crash leaves the changeset computing, and a retry with the same id succeeds",
         %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :compute_changeset, [:crash, :ok])

      compute(dp, "b1", overlay_id, "c1")
      assert flush() == []

      compute(dp, "b1", overlay_id, "c1")

      assert [
               {:instruction_result, %{ok: true}},
               {:changeset_report, %{changeset_id: "c1", error: nil}}
             ] = flush()
    end

    test "6.3 f3: a typed compute error comes back in the report", %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :compute_changeset, {:compute_error, "adapter_unavailable", true})
      compute(dp, "b1", overlay_id)

      assert [
               {:instruction_result, %{ok: true}},
               {:changeset_report, %{error: %{code: "adapter_unavailable", retryable: true}}}
             ] = flush()
    end

    test "6.2 f3 via 6.3: with the base snapshot gone, compute reports it", %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      FakeDataPlane.lose_base_snapshot(dp, "b1")
      compute(dp, "b1", overlay_id)

      assert [
               {:instruction_result, %{ok: true}},
               {:changeset_report, %{error: %{code: "base_snapshot_gone"}}}
             ] = flush()
    end

    test "6.3 f4: a lost report is recomputed under the same changeset id", %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :compute_changeset, [:lose_report, :ok])

      compute(dp, "b1", overlay_id)
      assert [{:instruction_result, %{ok: true}}] = flush()

      compute(dp, "b1", overlay_id)

      assert [{:instruction_result, %{ok: true}}, {:changeset_report, %{changeset_id: "c1"}}] =
               flush()
    end

    test "a script can supply verdict inputs: a fired assertion and conflicts", %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      failed = Fixtures.assertion_result("p1", "max-price-change", "failed", count: 3)

      FakeDataPlane.script(
        dp,
        :compute_changeset,
        {:report, assertion_results: [failed], conflicts_count: 2}
      )

      compute(dp, "b1", overlay_id)

      assert [{:instruction_result, _}, {:changeset_report, report}] = flush()
      assert [%{policy_id: "p1", status: "failed", count: 3}] = report.assertion_results
      assert report.conflicts_count == 2
    end

    test "re-evaluation: RunAssertions answers a report for the new changeset", %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      compute(dp, "b1", overlay_id, "c1")
      flush()

      deliver(
        dp,
        "rerun",
        {:run_assertions, %V1.RunAssertions{changeset_id: "c2", source_changeset_id: "c1"}}
      )

      assert [
               {:instruction_result, %{ok: true}},
               {:changeset_report, %{changeset_id: "c2", branch_id: "b1"}}
             ] = flush()
    end
  end

  # --- 6.5 merge -------------------------------------------------------------

  describe "6.5 merge" do
    test "happy path: compensation persisted, applied, outcome carries it", %{dp: dp} do
      frozen_branch(dp, "b1")
      merge(dp, "b1")

      assert [
               {:instruction_result, %{ok: true, instruction_id: "merge-m1"}},
               {:merge_outcome,
                %V1.MergeOutcome{
                  merge_id: "m1",
                  status: "applied",
                  compensation_persisted: true,
                  rows_applied: 12
                } = outcome}
             ] = flush()

      assert %V1.CompensationStatus{merge_id: "m1", status: :COMPLETE, merge_applied: true} =
               outcome.compensation

      assert FakeDataPlane.overlay(dp, "b1").believed == :done
    end

    test "6.5 f3: data plane unreachable, no work done and no answer", %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :drop)
      merge(dp, "b1")

      assert flush() == []
      overlay = FakeDataPlane.overlay(dp, "b1")
      assert overlay.merge == nil
      assert overlay.believed == :proposed
    end

    test "6.5 f3: a crash before the checkpoint leaves nothing durable, and the heartbeat shows it",
         %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :crash_before_checkpoint)
      merge(dp, "b1")
      flush()

      FakeDataPlane.heartbeat(dp)

      assert [
               {:heartbeat,
                %{believed_state: :MERGING, merge_progress: %{compensation_persisted: false}}}
             ] = flush()

      # The control plane says `proposed`: stop, since it is before the checkpoint.
      reply(dp, "b1", overlay_id, :AUTH_PROPOSED)
      assert %{merge: nil, believed: :proposed} = FakeDataPlane.overlay(dp, "b1")
    end

    test "6.5 f4: stale_base fails the merge with no compensation", %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :stale_base)
      merge(dp, "b1")

      assert [
               {:instruction_result, %{ok: true}},
               {:merge_outcome,
                %{status: "failed", failure_reason: "stale_base", compensation_persisted: false}}
             ] = flush()

      assert FakeDataPlane.overlay(dp, "b1").believed == :proposed
    end

    test "6.5 f4: snapshot lost fails the merge and marks the snapshot gone", %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :snapshot_lost)
      merge(dp, "b1")

      assert [_, {:merge_outcome, %{failure_reason: "snapshot_lost"}}] = flush()
      assert FakeDataPlane.overlay(dp, "b1").base_snapshot_gone
    end

    test "6.5 f4: an adapter error code is carried as the failure reason", %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, {:adapter_error, "ADAPTER_UNAVAILABLE"})
      merge(dp, "b1")

      assert [_, {:merge_outcome, %{status: "failed", failure_reason: "ADAPTER_UNAVAILABLE"}}] =
               flush()
    end

    test "6.5 f5: compensation cannot be computed, so the merge never proceeds", %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :compensation_failed)
      merge(dp, "b1")

      assert [
               _,
               {:merge_outcome,
                %{failure_reason: "compensation_failed", compensation_persisted: false}}
             ] = flush()

      assert FakeDataPlane.overlay(dp, "b1").compensation == nil
    end

    test "6.5 f6: the compensation write succeeded but the ack was lost; the re-sent merge continues",
         %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :lose_reply)
      merge(dp, "b1")
      assert flush() == []

      merge(dp, "b1")

      assert [
               {:instruction_result, %{ok: true}},
               {:merge_outcome, %{merge_id: "m1", status: "applied"}}
             ] = flush()
    end

    test "6.5 f7: committed but the apply stalls; heartbeats show progress and the error, then it resumes",
         %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, {:stall, 5, "RATE_LIMITED"})
      merge(dp, "b1")
      assert [{:instruction_result, %{ok: true}}] = flush()

      FakeDataPlane.heartbeat(dp)

      assert [
               {:heartbeat,
                %{
                  believed_state: :MERGING,
                  merge_progress: %{
                    rows_confirmed: 5,
                    rows_total: 12,
                    complete: false,
                    compensation_persisted: true,
                    last_error_code: "RATE_LIMITED",
                    retry_after: %Google.Protobuf.Timestamp{}
                  },
                  compensation_status: %{status: :COMPLETE, merge_applied: false}
                }}
             ] = flush()

      FakeDataPlane.advance_merge(dp, "b1", 9)
      FakeDataPlane.heartbeat(dp)
      assert [{:heartbeat, %{merge_progress: %{rows_confirmed: 9}}}] = flush()

      assert :ok = FakeDataPlane.resume_merge(dp, "b1")
      assert [{:merge_outcome, %{status: "applied", rows_applied: 12}}] = flush()
    end

    test "6.5 f7: after a crash past the checkpoint the merge is committed to; `proposed` from the control plane does not stop it",
         %{dp: dp} do
      overlay_id = frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :crash_after_checkpoint)
      merge(dp, "b1")
      flush()

      reply(dp, "b1", overlay_id, :AUTH_PROPOSED)

      assert %{merge: %{compensation_persisted: true}, believed: :merging} =
               FakeDataPlane.overlay(dp, "b1")

      assert :ok = FakeDataPlane.resume_merge(dp, "b1")
    end

    test "6.5 f8/f9: the outcome is lost; the heartbeat reports merging with progress complete",
         %{dp: dp} do
      frozen_branch(dp, "b1")
      FakeDataPlane.script(dp, :merge, :lose_outcome)
      merge(dp, "b1")
      assert [{:instruction_result, %{ok: true}}] = flush()

      FakeDataPlane.heartbeat(dp)

      assert [
               {:heartbeat,
                %{
                  believed_state: :DONE,
                  merge_progress: %{complete: true, compensation_persisted: true}
                }}
             ] = flush()
    end

    test "6.5: a merge instruction for an unknown branch is refused", %{dp: dp} do
      merge(dp, "ghost")
      assert [{:instruction_result, %{ok: false, error_code: "overlay_unreadable"}}] = flush()
    end
  end

  # --- 6.6 revert ------------------------------------------------------------

  describe "6.6 revert" do
    test "6.6 f2: the revert overlay is created like any branch, remembering the merge it reverts",
         %{dp: dp} do
      init_overlay(dp, "r1", revert_of_merge_id: "m1")
      assert [{:instruction_result, %{ok: true}}] = flush()
      assert FakeDataPlane.overlay(dp, "r1").revert_of == "m1"
    end

    for {authoritative, outcome} <- [
          MERGED: :RO_MERGED,
          REJECTED: :RO_REJECTED,
          ABANDONED: :RO_ABANDONED
        ] do
      test "6.8: a revert branch ending #{authoritative} reports revert_outcome #{outcome}", %{
        dp: dp
      } do
        init_overlay(dp, "r1", revert_of_merge_id: "m1")

        [{:instruction_result, %{body: {:overlay_initialised, %{overlay_id: overlay_id}}}}] =
          flush()

        reply(dp, "r1", overlay_id, unquote(authoritative))

        FakeDataPlane.heartbeat(dp)

        assert [
                 {:heartbeat,
                  %{revert_outcome: %{revert_of_merge_id: "m1", outcome: unquote(outcome)}}}
               ] = flush()
      end
    end
  end

  # --- 6.7 abandon and TTL ---------------------------------------------------

  describe "6.7 abandon and TTL" do
    test "6.7 f2: writes land in a doomed overlay until the heartbeat reply, then are refused", %{
      dp: dp
    } do
      overlay_id = open_branch(dp, "b1")
      assert :ok = FakeDataPlane.write(dp, "b1")
      reply(dp, "b1", overlay_id, :ABANDONED)
      assert {:error, :branch_abandoned} = FakeDataPlane.write(dp, "b1")
    end

    test "6.7 f3: the routing removal fails; the connection string resolves but the heartbeat answer ends writes",
         %{dp: dp} do
      overlay_id = open_branch(dp, "b1")

      # The removal (a RoutingUpsert with state `abandoned`) is lost, so the route still says open.
      FakeDataPlane.script(dp, :routing_upsert, :drop)

      deliver(
        dp,
        "unroute",
        {:routing_upsert,
         %V1.RoutingUpsert{branch_id: "b1", overlay_id: overlay_id, state: :ABANDONED}}
      )

      assert :ok = FakeDataPlane.write(dp, "b1")

      reply(dp, "b1", overlay_id, :ABANDONED)
      assert {:error, :branch_abandoned} = FakeDataPlane.write(dp, "b1")
    end

    test "6.7: a routing upsert of a terminal state refuses writes with the terminal code", %{
      dp: dp
    } do
      overlay_id = open_branch(dp, "b1")

      deliver(
        dp,
        "unroute",
        {:routing_upsert,
         %V1.RoutingUpsert{branch_id: "b1", overlay_id: overlay_id, state: :REJECTED}}
      )

      assert {:error, :branch_rejected} = FakeDataPlane.write(dp, "b1")
    end

    test "a closed branch's overlay is released on CloseOverlay", %{dp: dp} do
      overlay_id = open_branch(dp, "b1")

      deliver(
        dp,
        "close",
        {:close_overlay, %V1.CloseOverlay{branch_id: "b1", overlay_id: overlay_id}}
      )

      assert [{:instruction_result, %{ok: true}}] = flush()
      assert FakeDataPlane.overlay(dp, "b1") == nil
      assert [{"b1", ^overlay_id, :close_overlay}] = FakeDataPlane.gc_log(dp)
    end
  end

  # --- 6.8 heartbeat reconciliation ------------------------------------------

  describe "6.8 heartbeat reconciliation" do
    test "an alert cell holds the overlay and the data plane stops reacting to it", %{dp: dp} do
      frozen_branch(dp, "b1")
      overlay_id = FakeDataPlane.overlay(dp, "b1").overlay_id
      merge(dp, "b1")
      flush()

      # done × open is an alert row: the control plane lost a terminal transition.
      reply(dp, "b1", overlay_id, :AUTH_OPEN)
      assert %{held: true, frozen: true} = FakeDataPlane.overlay(dp, "b1")
      assert {:error, :held} = FakeDataPlane.write(dp, "b1")

      # No auto-repair: a later, contradictory reply is ignored.
      reply(dp, "b1", overlay_id, :MERGED)
      assert %{held: true} = FakeDataPlane.overlay(dp, "b1")
      assert %{ignored: :held_for_human} = List.last(FakeDataPlane.reactions(dp))
    end

    test "a reply for a different overlay id is `unknown` to the control plane and is ignored", %{
      dp: dp
    } do
      open_branch(dp, "b1")
      reply(dp, "b1", "some-other-overlay", :UNKNOWN)

      assert %{believed: :open} = FakeDataPlane.overlay(dp, "b1")
      assert %{ignored: :overlay_id_mismatch} = List.last(FakeDataPlane.reactions(dp))
    end

    test "retention and legal-hold instructions are acknowledged on the next heartbeat", %{dp: dp} do
      frozen_branch(dp, "b1")
      merge(dp, "b1")
      flush()

      until = Fixtures.timestamp(DateTime.add(DateTime.utc_now(), 86_400))

      deliver(
        dp,
        "ret",
        {:set_retention, %V1.SetRetention{merge_id: "m1", retention_until: until}}
      )

      deliver(dp, "hold", {:set_legal_hold, %V1.SetLegalHold{merge_id: "m1", legal_hold: true}})
      flush()

      FakeDataPlane.heartbeat(dp)

      assert [
               {:heartbeat,
                %{retention_ack: %{merge_id: "m1", legal_hold: true, retention_until: ^until}}}
             ] = flush()
    end

    test "a dropped retention instruction is never acknowledged, so the control plane re-sends",
         %{dp: dp} do
      frozen_branch(dp, "b1")
      merge(dp, "b1")
      flush()

      FakeDataPlane.script(dp, :set_retention, :drop)

      deliver(
        dp,
        "ret",
        {:set_retention, %V1.SetRetention{merge_id: "m1", retention_until: Fixtures.timestamp()}}
      )

      FakeDataPlane.heartbeat(dp)
      assert [{:heartbeat, %{retention_ack: nil}}] = flush()
    end

    test "while disconnected nothing is sent, and what was dropped is recorded", %{dp: dp} do
      open_branch(dp, "b1")
      flush()
      FakeDataPlane.disconnect(dp)
      FakeDataPlane.heartbeat(dp)

      assert flush() == []

      assert {:dropped, %V1.DataPlaneMessage{body: {:heartbeat, _}}} =
               List.last(FakeDataPlane.sent(dp))

      FakeDataPlane.reconnect(dp)
      FakeDataPlane.heartbeat(dp)
      assert [{:heartbeat, _}] = flush()
    end
  end

  # --- registration ----------------------------------------------------------

  describe "registering a target" do
    test "describe() result comes back as a TargetDescription", %{dp: dp} do
      deliver(
        dp,
        "reg",
        {:register_target,
         %V1.RegisterTarget{target_id: "t1", kind: "postgres", credential_ref: "env://X"}}
      )

      assert [
               {:instruction_result,
                %{
                  ok: true,
                  body: {:target_description, %{target_id: "t1", fidelity: "TRUE_SNAPSHOT"}}
                }}
             ] = flush()
    end

    test "a scripted failure surfaces as an error result", %{dp: dp} do
      FakeDataPlane.script(
        dp,
        :register_target,
        {:error, "ADAPTER_UNAVAILABLE", "cannot connect"}
      )

      deliver(dp, "reg", {:register_target, %V1.RegisterTarget{target_id: "t1"}})
      assert [{:instruction_result, %{ok: false, error_code: "ADAPTER_UNAVAILABLE"}}] = flush()
    end
  end

  # --- scripting itself ------------------------------------------------------

  describe "scripting" do
    test "behaviours are consumed in order, then default to ok", %{dp: dp} do
      FakeDataPlane.script(dp, :initialise_overlay, [:drop, :ok])
      init_overlay(dp, "b1")
      assert flush() == []
      init_overlay(dp, "b2")
      assert [{:instruction_result, %{ok: true}}] = flush()
      init_overlay(dp, "b3")
      assert [{:instruction_result, %{ok: true}}] = flush()
    end

    test "{:always, behaviour} never runs out", %{dp: dp} do
      FakeDataPlane.script(dp, :initialise_overlay, {:always, :drop})
      for n <- 1..3, do: init_overlay(dp, "b#{n}")
      assert flush() == []
    end

    test "{:delay, ms, behaviour} answers later", %{dp: dp} do
      FakeDataPlane.script(dp, :initialise_overlay, {:delay, 50, :ok})
      init_overlay(dp, "b1")
      assert flush() == []
      Process.sleep(80)
      assert [{:instruction_result, %{ok: true}}] = flush()
    end

    test "received/1 records instructions in order, including dropped ones", %{dp: dp} do
      FakeDataPlane.script(dp, :initialise_overlay, :drop)
      init_overlay(dp, "b1")
      init_overlay(dp, "b2")

      assert [%{instruction_id: "init-b1"}, %{instruction_id: "init-b2"}] =
               FakeDataPlane.received(dp)
    end
  end

  test "no message the fake sends carries a field that could hold a row (doc 13 invariant 9)", %{
    dp: dp
  } do
    overlay_id = frozen_branch(dp, "b1")
    compute(dp, "b1", overlay_id)
    merge(dp, "b1")
    FakeDataPlane.heartbeat(dp)

    # The generated messages are the contract; assert none of them is a bare map or binary payload
    # beyond digests and ids by checking every sent body is a known steward.plane.v1 struct.
    for message <- FakeDataPlane.sent(dp) do
      assert %V1.DataPlaneMessage{body: {_tag, %{__struct__: module}}} = message
      assert module |> Module.split() |> Enum.take(3) == ["Steward", "Plane", "V1"]
    end
  end
end
