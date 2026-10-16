defmodule Steward.Coordinator.HeartbeatTest do
  @moduledoc """
  Heartbeat dispatch (doc 07 §5.3): a process answers from its cache; a missing
  process for a live branch is rebuilt; a terminal or unknown branch is answered
  from the row without starting anything (doc 07 §6, "GenServer leak").
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.Heartbeat

  setup do
    org = org()
    owner = principal(org, :agent)
    target = target(org, principal(org, :human))
    branch = branch(org, target, owner)
    %{org: org, owner: owner, target: target, branch: branch}
  end

  defp hb(ctx, believed, extra \\ %{}) do
    Map.merge(
      %{
        branch_id: ctx.branch.id,
        overlay_id: ctx.branch.overlay_id,
        believed: believed,
        merge_progress: nil
      },
      extra
    )
  end

  defp transition!(ctx, action, params \\ %{}) do
    {:ok, record} = BranchProcess.transition(ctx.org.id, ctx.branch.id, action, params)
    record
  end

  defp progress(rows, opts \\ []) do
    %{
      merge_id: uuid(),
      rows_confirmed: rows,
      rows_total: 12,
      complete: Keyword.get(opts, :complete, false),
      compensation_persisted: Keyword.get(opts, :persisted, true)
    }
  end

  describe "routing" do
    test "a missing process for a live branch is started and answers", ctx do
      assert Coordinator.whereis(ctx.branch.id) == nil

      assert {:ok, %{authoritative: :open, freeze: false}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open))

      assert Coordinator.whereis(ctx.branch.id)
    end

    test "an existing process answers from its cache, without a database read", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      # Cache says `open`; nothing in the row has changed behind it.
      assert {:ok, %{authoritative: :open}} = Heartbeat.handle(ctx.org.id, hb(ctx, :open))
      assert Coordinator.whereis(ctx.branch.id) == pid
    end

    test "the reply follows the branch: proposed freezes the data plane", ctx do
      transition!(ctx, :propose)

      assert {:ok, %{authoritative: :proposed, freeze: true}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open))
    end

    test "a terminal branch is answered from the row and gets no process", ctx do
      transition!(ctx, :abandon, %{reason: :ttl_expired, terminal_by_job: "ttl"})
      eventually(fn -> Coordinator.whereis(ctx.branch.id) == nil end)

      assert {:ok, %{authoritative: :abandoned, freeze: false}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open))

      assert Coordinator.whereis(ctx.branch.id) == nil
    end

    test "an unknown branch is `unknown`, which is how an orphan overlay dies", ctx do
      assert {:ok, %{authoritative: :unknown}} =
               Heartbeat.handle(ctx.org.id, %{
                 branch_id: uuid(),
                 overlay_id: uuid(),
                 believed: :open,
                 merge_progress: nil
               })

      assert Coordinator.count() == 0
    end

    test "a branch in another org is `unknown` too", ctx do
      other = org()
      assert {:ok, %{authoritative: :unknown}} = Heartbeat.handle(other.id, hb(ctx, :open))
      assert Coordinator.count() == 0
    end

    test "lookup is by both ids: the right branch with another overlay id is `unknown`", ctx do
      assert {:ok, %{authoritative: :unknown}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open, %{overlay_id: uuid()}))

      # Nor does it start a process for the live branch.
      assert Coordinator.whereis(ctx.branch.id) == nil

      {:ok, _} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)

      assert {:ok, %{authoritative: :unknown}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open, %{overlay_id: uuid()}))
    end

    test "the last heartbeat time is recorded in the process", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      assert BranchProcess.last_heartbeat_at(pid) == nil

      Heartbeat.handle(ctx.org.id, hb(ctx, :open))
      assert %DateTime{} = BranchProcess.last_heartbeat_at(pid)
    end
  end

  describe "actions (through the recording seam)" do
    setup do
      record_actions()
    end

    test "an alert cell runs :alert and the reply still carries the authoritative state", ctx do
      # The control plane lost a terminal transition: the data plane is `done`, the row says `open`.
      assert {:ok, %{authoritative: :open, actions: %{alert: :ok}}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :done))

      assert_receive {:action, :alert, %{believed: :done, authoritative: :open}}
    end

    test "a quiet cell runs nothing", ctx do
      Heartbeat.handle(ctx.org.id, hb(ctx, :open))
      refute_receive {:action, _, _}, 50
    end

    test "the lease is renewed only while progress advances", ctx do
      transition!(ctx, :propose)
      transition!(ctx, :start_merge, %{merge_id: uuid()})

      assert {:ok, %{lease_renewed: true}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :merging, %{merge_progress: progress(3)}))

      assert_receive {:action, :renew_lease, _}

      # The same count again: no progress, no renewal (doc 13 §7).
      assert {:ok, %{lease_renewed: false}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :merging, %{merge_progress: progress(3)}))

      refute_receive {:action, :renew_lease, _}, 50

      assert {:ok, %{lease_renewed: true}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :merging, %{merge_progress: progress(7)}))

      assert_receive {:action, :renew_lease, _}
    end

    test "completion with the compensation persisted advances the branch", ctx do
      transition!(ctx, :propose)
      transition!(ctx, :start_merge, %{merge_id: uuid()})

      Heartbeat.handle(
        ctx.org.id,
        hb(ctx, :merging, %{merge_progress: progress(12, complete: true, persisted: false)})
      )

      refute_receive {:action, :advance_merged, _}, 50

      Heartbeat.handle(
        ctx.org.id,
        hb(ctx, :merging, %{merge_progress: progress(12, complete: true)})
      )

      assert_receive {:action, :advance_merged, %{branch: %{state: :merging}}}
    end

    test "a re-sent merge is asked for when the data plane believes open but the branch is merging",
         ctx do
      transition!(ctx, :propose)
      transition!(ctx, :start_merge, %{merge_id: uuid()})

      assert {:ok, %{authoritative: :merging, freeze: true}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open))

      assert_receive {:action, :resend_merge, _}
    end

    test "terminal-branch alerts run too, with no process", ctx do
      transition!(ctx, :propose)
      transition!(ctx, :reject, %{reason: :review_rejected, terminal_by_job: "t"})
      eventually(fn -> Coordinator.whereis(ctx.branch.id) == nil end)

      # merging × rejected: "should be impossible after checkpoint".
      assert {:ok, %{authoritative: :rejected}} = Heartbeat.handle(ctx.org.id, hb(ctx, :merging))
      assert_receive {:action, :alert, %{authoritative: :rejected}}
      assert Coordinator.whereis(ctx.branch.id) == nil
    end
  end

  describe "the default actions" do
    test ":alert writes a heartbeat.anomaly event and repairs nothing", ctx do
      assert {:ok, %{authoritative: :open, actions: %{alert: :ok}}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :done))

      events =
        Ash.read!(Steward.Core.Audit.Event,
          tenant: ctx.org.id,
          actor: System.new(:api, ctx.org.id)
        )

      assert event = Enum.find(events, &(&1.type == "heartbeat.anomaly"))
      assert event.aggregate_id == ctx.branch.id
      assert event.payload["believed"] == "done"
      assert event.payload["authoritative"] == "open"

      # The branch is untouched: "alert" rows must not be auto-repaired.
      assert %{state: :open} =
               Ash.get!(Branch, ctx.branch.id, tenant: ctx.org.id, authorize?: false)
    end

    test "the merge actions are deferred to E6, visibly", ctx do
      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        [:steward, :coordinator, :heartbeat, :action_deferred],
        fn _event, _measure, meta, _ -> send(parent, {:deferred, meta.action}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      transition!(ctx, :propose)
      transition!(ctx, :start_merge, %{merge_id: uuid()})

      assert {:ok, %{lease_renewed: false, actions: %{resend_merge: {:error, :not_implemented}}}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open))

      assert_receive {:deferred, :resend_merge}
    end
  end

  describe "stale answers (doc 07 §6)" do
    test "after a failed refresh the reply says so, and still answers from the cache", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      :sys.replace_state(pid, &%{&1 | stale: true})

      assert {:ok, %{authoritative: :open, stale: true}} =
               Heartbeat.handle(ctx.org.id, hb(ctx, :open))
    end
  end
end
