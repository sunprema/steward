defmodule Steward.Jobs.BranchJobsTest do
  @moduledoc """
  The AshOban triggers on `Branch` and `Changeset` (doc 07 §6, doc 13 §6.3 f7,
  §6.7): TTL expiry, and the reconciliations of a `block` verdict whose branch was
  never rejected and a `hold` verdict with no queue entry. Each is driven with
  `AshOban.Test`, which schedules and drains synchronously.
  """
  use Steward.CoordinatorCase
  use AshOban.Test, repo: Steward.Repo

  require Ash.Query

  alias Steward.Core.Branches.{Changeset, QueueEntry, Verdict}

  setup do
    org = org()
    owner = principal(org, :agent)
    target = target(org, principal(org, :human))
    %{org: org, owner: owner, target: target}
  end

  defp sys(ctx), do: System.new(:coordinator, ctx.org.id)
  defp row(ctx, b), do: Ash.get!(Branch, b.id, tenant: ctx.org.id, authorize?: false)

  defp changesets(ctx, b),
    do:
      Changeset
      |> Ash.Query.filter(branch_id == ^b.id)
      |> Ash.read!(tenant: ctx.org.id, actor: sys(ctx))

  defp queue(ctx), do: Ash.read!(QueueEntry, tenant: ctx.org.id, actor: sys(ctx))

  defp expire_at(b, offset_seconds) do
    at = DateTime.add(DateTime.utc_now(), offset_seconds)

    Ecto.Adapters.SQL.query!(
      Steward.Repo,
      "UPDATE branches SET ttl_expires_at = $1 WHERE id = $2",
      [at, Ecto.UUID.dump!(b.id)]
    )
  end

  defp run(trigger_resource_and_name),
    do: AshOban.Test.schedule_and_run_triggers(trigger_resource_and_name)

  # A proposed branch whose changeset was computed and evaluated with `outcome`, but whose follow-up never ran.
  defp evaluated(ctx, outcome) do
    b = branch(ctx.org, ctx.target, ctx.owner)
    {:ok, proposed} = BranchProcess.transition(ctx.org.id, b.id, :propose)
    cs = proposed.__metadata__.changeset
    actor = sys(ctx)

    {:ok, computed} =
      cs
      |> Ash.Changeset.for_update(
        :record_computed,
        %{
          summary: %{"format_version" => 1},
          impact: %{"format_version" => 1, "metrics" => []},
          row_delta_digest: :crypto.hash(:sha256, "d")
        },
        tenant: ctx.org.id,
        actor: actor
      )
      |> Ash.update()

    verdict = %{
      outcome: outcome,
      reason: :policies,
      policy_outcome: outcome,
      policy_version_ids: [],
      control_plane_ms: 1,
      data_plane_ms: 1
    }

    {:ok, evaluated} =
      computed
      |> Ash.Changeset.for_update(:record_verdict, %{verdict: verdict},
        tenant: ctx.org.id,
        actor: actor
      )
      |> Ash.update()

    {b, evaluated}
  end

  describe "TTL expiry (doc 13 §6.7)" do
    test "an open branch past its TTL is abandoned with ttl_expired, by the job", ctx do
      b = branch(ctx.org, ctx.target, ctx.owner)
      expire_at(b, -60)

      assert %{success: 2} = run({Branch, :expire_ttl})

      assert %{
               state: :abandoned,
               reason: :ttl_expired,
               terminal_by_job: "ttl",
               terminal_at: %DateTime{}
             } = row(ctx, b)
    end

    test "a branch with time left is left alone, and so is a proposed one (no held TTL in M0)",
         ctx do
      fresh = branch(ctx.org, ctx.target, ctx.owner)
      late = branch(ctx.org, ctx.target, ctx.owner)
      {:ok, _} = BranchProcess.transition(ctx.org.id, late.id, :propose)
      expire_at(late, -60)

      run({Branch, :expire_ttl})

      assert row(ctx, fresh).state == :open
      assert row(ctx, late).state == :proposed
    end

    test "runs for every org, each as its own tenant", ctx do
      other = org()
      other_owner = principal(other, :agent)
      other_target = target(other, principal(other, :human))
      mine = branch(ctx.org, ctx.target, ctx.owner)
      theirs = branch(other, other_target, other_owner)
      expire_at(mine, -1)
      expire_at(theirs, -1)

      run({Branch, :expire_ttl})

      assert row(ctx, mine).state == :abandoned
      assert Ash.get!(Branch, theirs.id, tenant: other.id, authorize?: false).state == :abandoned
    end

    test "writes the event, in the same transaction", ctx do
      b = branch(ctx.org, ctx.target, ctx.owner)
      expire_at(b, -1)
      run({Branch, :expire_ttl})

      events =
        Ash.read!(Steward.Core.Audit.Event,
          tenant: ctx.org.id,
          actor: System.new(:api, ctx.org.id)
        )

      assert Enum.any?(
               events,
               &(&1.type == "branch.abandoned" and &1.aggregate_id == b.id and
                   &1.payload["reason"] == "ttl_expired")
             )
    end

    test "the branch's process hears of it after commit and stops (the job bypasses the process)",
         ctx do
      b = branch(ctx.org, ctx.target, ctx.owner)
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, b.id)
      ref = Process.monitor(pid)
      expire_at(b, -1)

      run({Branch, :expire_ttl})

      assert_receive {:DOWN, ^ref, _, _, :normal}, 2_000
    end

    test "an abandoned branch's heartbeat is then answered abandoned, from the row", ctx do
      b = branch(ctx.org, ctx.target, ctx.owner)
      expire_at(b, -1)
      run({Branch, :expire_ttl})
      eventually(fn -> Coordinator.whereis(b.id) == nil end)

      assert {:ok, %{authoritative: :abandoned}} =
               Steward.Coordinator.Heartbeat.handle(ctx.org.id, %{
                 branch_id: b.id,
                 overlay_id: b.overlay_id,
                 believed: :open,
                 merge_progress: nil
               })
    end
  end

  describe "a block verdict whose branch was never rejected (doc 13 §6.3 f7)" do
    test "the branch is rejected with verdict_block, by the reconciliation", ctx do
      {b, _} = evaluated(ctx, :block)
      assert row(ctx, b).state == :proposed

      run({Branch, :reject_blocked})

      assert %{state: :rejected, reason: :verdict_block, terminal_by_job: "reconcile"} =
               row(ctx, b)

      # "A rejected branch may keep its last changeset live for audit."
      assert [%Changeset{state: :evaluated}] = changesets(ctx, b)
    end

    test "a hold or auto-merge branch is not touched", ctx do
      {hold, _} = evaluated(ctx, :hold)
      {auto, _} = evaluated(ctx, :"auto-merge")
      run({Branch, :reject_blocked})
      assert row(ctx, hold).state == :proposed
      assert row(ctx, auto).state == :proposed
    end

    test "a branch already rejected is not rejected again", ctx do
      {b, _} = evaluated(ctx, :block)

      {:ok, _} =
        BranchProcess.transition(ctx.org.id, b.id, :reject, %{
          reason: :verdict_block,
          terminal_by_job: "policy"
        })

      run({Branch, :reject_blocked})
      assert row(ctx, b).terminal_by_job == "policy"
    end
  end

  describe "a hold verdict with no queue entry (doc 13 §6.3 f7)" do
    test "gets one; running again is the same as once", ctx do
      {b, cs} = evaluated(ctx, :hold)
      assert queue(ctx) == []

      run({Changeset, :ensure_queue_entry})

      assert [
               %QueueEntry{
                 changeset_id: id,
                 branch_id: branch_id,
                 hold_reasons: [%{"reason" => "policies"}]
               }
             ] = queue(ctx)

      assert id == cs.id
      assert branch_id == b.id

      run({Changeset, :ensure_queue_entry})
      assert length(queue(ctx)) == 1
    end

    test "a block or auto-merge verdict gets none, nor does a hold on a branch that left proposed",
         ctx do
      {_, _} = evaluated(ctx, :block)
      {_, _} = evaluated(ctx, :"auto-merge")
      {left, _} = evaluated(ctx, :hold)
      {:ok, _} = BranchProcess.transition(ctx.org.id, left.id, :withdraw)

      run({Changeset, :ensure_queue_entry})
      assert queue(ctx) == []
    end

    test "an entry that already exists is left as it is", ctx do
      {_, _} = evaluated(ctx, :hold)
      run({Changeset, :ensure_queue_entry})
      [entry] = queue(ctx)
      run({Changeset, :ensure_queue_entry})
      assert [%{id: id}] = queue(ctx)
      assert id == entry.id
    end
  end

  test "a verdict is unique per changeset (a changeset is never re-evaluated, doc 13 invariant 4)",
       ctx do
    {_, cs} = evaluated(ctx, :hold)

    again = %{
      outcome: :hold,
      reason: :policies,
      policy_outcome: :hold,
      policy_version_ids: [],
      control_plane_ms: 0,
      data_plane_ms: 0
    }

    assert {:error, _} =
             Verdict
             |> Ash.Changeset.for_create(:create, Map.put(again, :changeset_id, cs.id),
               tenant: ctx.org.id,
               actor: sys(ctx)
             )
             |> Ash.create()
  end
end
