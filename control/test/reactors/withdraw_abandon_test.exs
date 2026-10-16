defmodule Steward.Coordinator.Reactors.WithdrawAbandonTest do
  @moduledoc """
  Withdraw and abandon (doc 13 §6.3, §6.7), end to end. Abandon is a single
  transaction (the checkpoint) followed by best-effort routing removal; withdraw is
  the owner taking a proposed branch back.
  """
  use Steward.CoordinatorCase

  require Ash.Query

  alias Steward.Coordinator.Flows
  alias Steward.Core.Branches.{Changeset, QueueEntry}
  alias Steward.FakeDataPlane

  setup_all do
    Steward.SessionHarness.start_listener()
  end

  setup ctx do
    put_coordinator_env(instruction_deadline_ms: 400, compute_wait_ms: 400)
    world = Steward.SessionHarness.world(ctx)

    {:ok, branch} =
      Flows.create_branch(%{
        org_id: world.org.id,
        actor: world.key,
        target_id: world.target.id,
        idempotency_key: "k"
      })

    Map.put(world, :branch, branch)
  end

  defp args(ctx, extra \\ %{}),
    do: Map.merge(%{org_id: ctx.org.id, actor: ctx.key, branch_id: ctx.branch.id}, extra)

  defp row(ctx), do: Ash.get!(Branch, ctx.branch.id, tenant: ctx.org.id, authorize?: false)
  defp system(ctx), do: System.new(:coordinator, ctx.org.id)

  defp changesets(ctx),
    do:
      Changeset
      |> Ash.Query.filter(branch_id == ^ctx.branch.id)
      |> Ash.read!(tenant: ctx.org.id, actor: system(ctx))

  defp proposed(ctx) do
    {:ok, result} = Flows.propose(args(ctx), await: :finished)
    result
  end

  describe "abandon (doc 13 §6.7)" do
    test "an open branch: abandoned by the principal, with a reason and the principal recorded",
         ctx do
      assert {:ok, branch} = Flows.abandon(args(ctx))

      assert %{state: :abandoned, reason: :abandoned_by_principal} = branch
      assert branch.terminal_by_principal_id == ctx.agent.id
      assert %{state: :abandoned} = row(ctx)
      eventually(fn -> Coordinator.whereis(ctx.branch.id) == nil end)
    end

    test "a proposed branch: the changeset is superseded and the queue entry removed, in the one transaction",
         ctx do
      %{changeset: cs} = proposed(ctx)
      assert [_] = Ash.read!(QueueEntry, tenant: ctx.org.id, actor: system(ctx))

      assert {:ok, %{state: :abandoned}} = Flows.abandon(args(ctx))

      assert [%Changeset{id: id, state: :superseded, superseded_reason: :abandoned_by_principal}] =
               changesets(ctx)

      assert id == cs.id
      assert Ash.read!(QueueEntry, tenant: ctx.org.id, actor: system(ctx)) == []
    end

    test "after the checkpoint the data plane is told to stop routing, and writes are refused",
         ctx do
      FakeDataPlane.write(ctx.fake, ctx.branch.id)
      {:ok, _} = Flows.abandon(args(ctx))

      eventually(fn ->
        FakeDataPlane.write(ctx.fake, ctx.branch.id) == {:error, :branch_abandoned}
      end)

      assert %{body: {:routing_upsert, %{state: :ABANDONED}}} =
               List.last(FakeDataPlane.received(ctx.fake))
    end

    test "6.7 f3: a lost routing removal does not undo the abandon; the heartbeat answer ends the writes",
         ctx do
      FakeDataPlane.script(ctx.fake, :routing_upsert, :drop)
      assert {:ok, %{state: :abandoned}} = Flows.abandon(args(ctx))
      assert %{state: :abandoned} = row(ctx)

      # The route still resolves, and writes land in the doomed overlay (§6.7 f2) ...
      assert :ok = FakeDataPlane.write(ctx.fake, ctx.branch.id)
      # ... until the heartbeat reply says abandoned.
      FakeDataPlane.heartbeat(ctx.fake)

      eventually(fn ->
        FakeDataPlane.write(ctx.fake, ctx.branch.id) == {:error, :branch_abandoned}
      end)
    end

    test "the overlay is kept: abandoning does not release it (it is released after the retention window)",
         ctx do
      {:ok, _} = Flows.abandon(args(ctx))
      assert FakeDataPlane.overlay(ctx.fake, ctx.branch.id)
    end

    test "a merging branch is refused with merge_in_progress", ctx do
      {:ok, _} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)

      {:ok, _} =
        BranchProcess.transition(ctx.org.id, ctx.branch.id, :start_merge, %{merge_id: uuid()})

      assert {:error, :merge_in_progress} = Flows.abandon(args(ctx))
      assert row(ctx).state == :merging
    end

    test "an already terminal branch is reported as such", ctx do
      {:ok, _} = Flows.abandon(args(ctx))
      assert {:error, :already_terminal} = Flows.abandon(args(ctx))
    end

    test "only the owner, or a target_admin, may abandon", ctx do
      stranger = principal(ctx.org, :agent)
      key = api_key(ctx.org, stranger, ~w(branch:write), [ctx.target.id])
      assert {:error, %Ash.Error.Forbidden.Policy{}} = Flows.abandon(args(ctx, %{actor: key}))
      assert row(ctx).state == :open

      assert {:ok, %{state: :abandoned, terminal_by_principal_id: by}} =
               Flows.abandon(args(ctx, %{actor: ctx.t_admin}))

      assert by == ctx.t_admin.id
    end

    test "a job abandons with a job name and a reason, as a system actor (the TTL path)", ctx do
      job = System.new(:jobs, ctx.org.id)

      assert {:ok, %{state: :abandoned, reason: :ttl_expired, terminal_by_job: "ttl"}} =
               Flows.abandon(
                 args(ctx, %{actor: job, reason: :ttl_expired, terminal_by_job: "ttl"})
               )
    end

    test "the event is appended in the same transaction", ctx do
      {:ok, _} = Flows.abandon(args(ctx))

      events =
        Ash.read!(Steward.Core.Audit.Event,
          tenant: ctx.org.id,
          actor: System.new(:api, ctx.org.id)
        )

      assert Enum.any?(
               events,
               &(&1.type == "branch.abandoned" and &1.aggregate_id == ctx.branch.id)
             )
    end
  end

  describe "withdraw (doc 13 §2.1)" do
    test "proposed → open: the changeset superseded as withdrawn, the queue entry removed", ctx do
      proposed(ctx)

      assert {:ok, %{state: :open}} = Flows.withdraw(args(ctx))

      assert [%Changeset{state: :superseded, superseded_reason: :withdrawn}] = changesets(ctx)
      assert Ash.read!(QueueEntry, tenant: ctx.org.id, actor: system(ctx)) == []
      assert row(ctx).state == :open
    end

    test "the data plane is told to unfreeze, and can write again", ctx do
      proposed(ctx)
      assert {:error, :branch_frozen} = FakeDataPlane.write(ctx.fake, ctx.branch.id)

      {:ok, _} = Flows.withdraw(args(ctx))
      eventually(fn -> FakeDataPlane.write(ctx.fake, ctx.branch.id) == :ok end)
    end

    test "a lost unfreeze is repaired by the heartbeat reply of open (doc 13 §6.8)", ctx do
      proposed(ctx)
      FakeDataPlane.script(ctx.fake, :freeze_writes, :drop)
      {:ok, %{state: :open}} = Flows.withdraw(args(ctx))
      assert {:error, :branch_frozen} = FakeDataPlane.write(ctx.fake, ctx.branch.id)

      FakeDataPlane.heartbeat(ctx.fake)
      eventually(fn -> FakeDataPlane.write(ctx.fake, ctx.branch.id) == :ok end)
    end

    test "and the branch can be proposed again, with a second changeset", ctx do
      proposed(ctx)
      {:ok, _} = Flows.withdraw(args(ctx))
      FakeDataPlane.heartbeat(ctx.fake)

      %{changeset: second} = proposed(ctx)
      assert second.sequence == 2

      assert [%{state: :superseded}, %{state: :evaluated}] =
               Enum.sort_by(changesets(ctx), & &1.sequence)
    end

    test "only the owner may withdraw; an open branch has nothing to withdraw", ctx do
      assert {:error, :invalid_transition} = Flows.withdraw(args(ctx))

      proposed(ctx)
      stranger = principal(ctx.org, :agent)
      key = api_key(ctx.org, stranger, ~w(branch:write), [ctx.target.id])
      assert {:error, %Ash.Error.Forbidden.Policy{}} = Flows.withdraw(args(ctx, %{actor: key}))

      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               Flows.withdraw(args(ctx, %{actor: ctx.t_admin}))
    end

    test "emits branch.withdrawn", ctx do
      proposed(ctx)
      {:ok, _} = Flows.withdraw(args(ctx))

      events =
        Ash.read!(Steward.Core.Audit.Event,
          tenant: ctx.org.id,
          actor: System.new(:api, ctx.org.id)
        )

      assert Enum.any?(events, &(&1.type == "branch.withdrawn"))
    end
  end

  test "a rejected branch's changeset stays live for audit; only its queue entry goes (doc 13 §3)",
       ctx do
    %{changeset: cs} = proposed(ctx)

    {:ok, _} =
      BranchProcess.transition(ctx.org.id, ctx.branch.id, :reject, %{
        reason: :review_rejected,
        terminal_by_job: "t"
      })

    assert [%Changeset{id: id, state: :evaluated}] = changesets(ctx)
    assert id == cs.id
    assert Ash.read!(QueueEntry, tenant: ctx.org.id, actor: system(ctx)) == []
  end
end
