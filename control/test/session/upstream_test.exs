defmodule Steward.Coordinator.Plane.UpstreamTest do
  @moduledoc """
  What the control plane does with each upstream message (doc 10 §5), without a
  socket: heartbeats through the coordinator, results to their waiting caller,
  reports to the handlers, audit events to `audit_log`, and the rules that close
  or limit a stream.
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.Plane
  alias Steward.Coordinator.Plane.Upstream
  alias Steward.Core.Audit.AuditLog
  alias Steward.Plane.V1

  setup do
    org = org()
    owner = principal(org, :agent)
    target = target(org, principal(org, :human))
    dp = data_plane(org)
    branch = branch(org, target, owner)

    %{
      org: org,
      owner: owner,
      target: target,
      dp: dp,
      branch: branch,
      up: Upstream.new(org.id, dp.id)
    }
  end

  defp message(ctx, body, id \\ nil),
    do: %V1.DataPlaneMessage{data_plane_id: id || ctx.dp.id, body: body}

  defp heartbeat(ctx, believed \\ :OPEN, extra \\ []) do
    struct!(
      V1.Heartbeat,
      [branch_id: ctx.branch.id, overlay_id: ctx.branch.overlay_id, believed_state: believed] ++
        extra
    )
  end

  describe "heartbeats" do
    test "are answered with the authoritative state, in the protobuf the data plane expects",
         ctx do
      assert {_, [%V1.ControlPlaneMessage{body: {:heartbeat_reply, reply}}]} =
               Upstream.handle(ctx.up, message(ctx, {:heartbeat, heartbeat(ctx)}))

      assert reply.branch_id == ctx.branch.id
      assert reply.overlay_id == ctx.branch.overlay_id
      assert reply.authoritative_state == :AUTH_OPEN
      refute reply.freeze
    end

    test "a proposed branch freezes the data plane", ctx do
      {:ok, _} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)

      assert {_,
              [%{body: {:heartbeat_reply, %{authoritative_state: :AUTH_PROPOSED, freeze: true}}}]} =
               Upstream.handle(ctx.up, message(ctx, {:heartbeat, heartbeat(ctx)}))
    end

    test "an unknown branch is answered UNKNOWN", ctx do
      hb = %V1.Heartbeat{
        branch_id: Ecto.UUID.generate(),
        overlay_id: Ecto.UUID.generate(),
        believed_state: :OPEN
      }

      assert {_, [%{body: {:heartbeat_reply, %{authoritative_state: :UNKNOWN}}}]} =
               Upstream.handle(ctx.up, message(ctx, {:heartbeat, hb}))
    end

    test "an unspecified believed state is not answered", ctx do
      assert {_, []} =
               Upstream.handle(
                 ctx.up,
                 message(ctx, {:heartbeat, heartbeat(ctx, :BELIEVED_UNSPECIFIED)})
               )
    end

    test "merge progress reaches the matrix: a stalled count does not renew the lease", ctx do
      record_actions()
      {:ok, _} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)

      {:ok, _} =
        BranchProcess.transition(ctx.org.id, ctx.branch.id, :start_merge, %{
          merge_id: Ecto.UUID.generate()
        })

      progress = fn rows ->
        %V1.MergeProgress{
          merge_id: Ecto.UUID.generate(),
          rows_confirmed: rows,
          rows_total: 12,
          compensation_persisted: true
        }
      end

      {up, [%{body: {:heartbeat_reply, first}}]} =
        Upstream.handle(
          ctx.up,
          message(ctx, {:heartbeat, heartbeat(ctx, :MERGING, merge_progress: progress.(3))})
        )

      assert first.lease_renewed

      {_, [%{body: {:heartbeat_reply, second}}]} =
        Upstream.handle(
          up,
          message(ctx, {:heartbeat, heartbeat(ctx, :MERGING, merge_progress: progress.(3))})
        )

      refute second.lease_renewed
    end
  end

  describe "the heartbeat bucket" do
    test "over budget a heartbeat is dropped, not answered, and counted (doc 07 §5.3)", ctx do
      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        [:steward, :plane, :heartbeat_rate_limited],
        fn _, _, _, _ -> send(parent, :limited) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      up = Upstream.new(ctx.org.id, ctx.dp.id, rate: 2)
      hb = message(ctx, {:heartbeat, heartbeat(ctx)})

      {up, replies} =
        Enum.reduce(1..4, {up, []}, fn _, {u, acc} ->
          {u, r} = Upstream.handle(u, hb)
          {u, acc ++ r}
        end)

      assert length(replies) == 4

      {_, replies} = Upstream.handle(up, hb)
      assert replies == []
      assert_receive :limited
    end

    test "the rate follows the number of branches on the data plane", ctx do
      assert ctx.up.limiter.rate == 100.0
      assert Upstream.retune(ctx.up, 1_000_000).limiter.rate == 100_000.0
    end
  end

  describe "identity" do
    test "a message naming another data plane is refused so the stream can be closed (doc 10 §5)",
         ctx do
      assert {:error, :identity_mismatch} =
               Upstream.handle(
                 ctx.up,
                 message(ctx, {:heartbeat, heartbeat(ctx)}, Ecto.UUID.generate())
               )
    end
  end

  describe "instruction results" do
    test "go to the caller waiting on the instruction", ctx do
      parent = self()

      h =
        spawn_link(fn ->
          receive do
            {:push, m} -> send(parent, {:pushed, m})
          end
        end)

      :ok = Plane.attach(ctx.org.id, ctx.dp.id, h)

      {:ok, id} =
        Plane.send_async(ctx.org.id, ctx.dp.id, %V1.Instruction{
          body: {:close_overlay, %V1.CloseOverlay{branch_id: "b"}}
        })

      assert_receive {:pushed, _}

      result = %V1.InstructionResult{instruction_id: id, ok: true}
      assert {_, []} = Upstream.handle(ctx.up, message(ctx, {:instruction_result, result}))
      assert_receive {:instruction_result, ^id, {:ok, ^result}}
    end
  end

  describe "reports" do
    defmodule Recording do
      @behaviour Steward.Coordinator.Plane.Handlers
      def changeset_report(org, dp, report),
        do: send(:persistent_term.get({__MODULE__, :to}), {:report, org, dp, report}) && :ok

      def merge_outcome(org, dp, outcome),
        do: send(:persistent_term.get({__MODULE__, :to}), {:outcome, org, dp, outcome}) && :ok
    end

    setup do
      :persistent_term.put({Recording, :to}, self())
      previous = Application.get_env(:steward, Steward.Coordinator, [])

      Application.put_env(
        :steward,
        Steward.Coordinator,
        Keyword.put(previous, :plane_handlers, Recording)
      )

      on_exit(fn ->
        Application.put_env(:steward, Steward.Coordinator, previous)
        :persistent_term.erase({Recording, :to})
      end)
    end

    test "a changeset report and a merge outcome go to the handlers with the org and data plane",
         ctx do
      report = %V1.ChangesetReport{changeset_id: "c1", branch_id: ctx.branch.id}
      outcome = %V1.MergeOutcome{merge_id: "m1", status: "applied"}

      assert {_, []} = Upstream.handle(ctx.up, message(ctx, {:changeset_report, report}))
      assert {_, []} = Upstream.handle(ctx.up, message(ctx, {:merge_outcome, outcome}))

      org_id = ctx.org.id
      dp_id = ctx.dp.id
      assert_receive {:report, ^org_id, ^dp_id, ^report}
      assert_receive {:outcome, ^org_id, ^dp_id, ^outcome}
    end
  end

  describe "the default handlers" do
    test "defer visibly until E4/E6 give them somewhere to go", ctx do
      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        [:steward, :plane, :report_deferred],
        fn _, _, meta, _ -> send(parent, {:deferred, meta.kind}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Upstream.handle(
        ctx.up,
        message(ctx, {:changeset_report, %V1.ChangesetReport{changeset_id: "c1"}})
      )

      Upstream.handle(ctx.up, message(ctx, {:merge_outcome, %V1.MergeOutcome{merge_id: "m1"}}))
      assert_receive {:deferred, :changeset_report}
      assert_receive {:deferred, :merge_outcome}
    end
  end

  describe "audit events (doc 09 §8)" do
    test "are written to audit_log as metadata only", ctx do
      jti = Ecto.UUID.generate()
      reviewer = principal(ctx.org, :human)

      event = %V1.DataPlaneAuditEvent{
        merge_id: Ecto.UUID.generate(),
        changeset_id: Ecto.UUID.generate(),
        action: "row_delta.read",
        principal_id: reviewer.id,
        grant_jti: jti,
        at: Steward.FakeDataPlane.Fixtures.timestamp()
      }

      assert {_, []} = Upstream.handle(ctx.up, message(ctx, {:audit_event, event}))

      [row] = Ash.read!(AuditLog, tenant: ctx.org.id, actor: System.new(:api, ctx.org.id))
      assert row.action == "row_delta.read"
      assert row.object_type == "changeset"
      assert row.object_id == event.changeset_id
      assert row.principal_id == reviewer.id
      assert row.grant_id == jti
      assert row.data_plane_id == ctx.dp.id
    end

    test "a merge-scoped event (compensation) is about the merge", ctx do
      merge_id = Ecto.UUID.generate()

      event = %V1.DataPlaneAuditEvent{
        merge_id: merge_id,
        action: "compensation.read",
        at: Steward.FakeDataPlane.Fixtures.timestamp()
      }

      Upstream.handle(ctx.up, message(ctx, {:audit_event, event}))

      [row] = Ash.read!(AuditLog, tenant: ctx.org.id, actor: System.new(:api, ctx.org.id))
      assert {row.object_type, row.object_id} == {"merge", merge_id}
    end

    test "an action outside the fixed vocabulary is rejected and counted, never raised", ctx do
      event = %V1.DataPlaneAuditEvent{
        merge_id: Ecto.UUID.generate(),
        action: "made.up",
        at: Steward.FakeDataPlane.Fixtures.timestamp()
      }

      assert {_, []} = Upstream.handle(ctx.up, message(ctx, {:audit_event, event}))
      assert Ash.read!(AuditLog, tenant: ctx.org.id, actor: System.new(:api, ctx.org.id)) == []
    end
  end
end
