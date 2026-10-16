defmodule Steward.Coordinator.Reactors.ProposeTest do
  @moduledoc """
  Propose (doc 13 §6.3), end to end through the real `Session` listener and the
  E13 fake data plane. Test names carry the failure row.
  """
  use Steward.CoordinatorCase

  require Ash.Query

  alias Steward.Coordinator.Flows
  alias Steward.Core.Branches.{Changeset, QueueEntry, Verdict}
  alias Steward.FakeDataPlane
  alias Steward.FakeDataPlane.Fixtures

  # Verdicts a test can ask for, in place of the policy engine (E5).
  defmodule Evaluator do
    @behaviour Steward.Coordinator.PolicyEvaluator

    @impl true
    def evaluate(_org, _branch, _changeset, _report) do
      case :persistent_term.get({__MODULE__, :answer}) do
        :raise ->
          raise "policy engine exploded"

        :error ->
          {:error, :policy_unavailable}

        outcome ->
          {:ok,
           %{
             outcome: outcome,
             reason: :policies,
             policy_outcome: outcome,
             policy_version_ids: [],
             control_plane_ms: 3,
             data_plane_ms: 4
           }}
      end
    end
  end

  setup_all do
    Steward.SessionHarness.start_listener()
  end

  setup ctx do
    put_coordinator_env(instruction_deadline_ms: 500, compute_wait_ms: 400)
    world = Steward.SessionHarness.world(ctx)

    {:ok, branch} =
      Flows.create_branch(%{
        org_id: world.org.id,
        actor: world.key,
        target_id: world.target.id,
        idempotency_key: "k"
      })

    FakeDataPlane.write(world.fake, branch.id, rows: 12)
    Map.put(world, :branch, branch)
  end

  defp answer(outcome) do
    :persistent_term.put({Evaluator, :answer}, outcome)
    put_coordinator_env(policy_evaluator: Evaluator)
    on_exit(fn -> :persistent_term.erase({Evaluator, :answer}) end)
  end

  defp propose(ctx, opts \\ [await: :finished]),
    do:
      Flows.propose(
        %{
          org_id: ctx.org.id,
          actor: ctx.key,
          branch_id: ctx.branch.id,
          rationale: "raise prices 2%"
        },
        opts
      )

  defp row(ctx), do: Ash.get!(Branch, ctx.branch.id, tenant: ctx.org.id, authorize?: false)

  defp changesets(ctx) do
    Changeset
    |> Ash.Query.filter(branch_id == ^ctx.branch.id)
    |> Ash.Query.sort(:sequence)
    |> Ash.read!(tenant: ctx.org.id, actor: System.new(:coordinator, ctx.org.id))
  end

  defp events(ctx),
    do:
      Ash.read!(Steward.Core.Audit.Event, tenant: ctx.org.id, actor: System.new(:api, ctx.org.id))

  describe "the happy path" do
    test "answers with the computing changeset at once, then evaluates it in the background",
         ctx do
      assert {:ok,
              %Changeset{
                state: :computing,
                sequence: 1,
                rationale: "raise prices 2%",
                trigger: "propose"
              } = opened} =
               propose(ctx, await: :proposed)

      assert row(ctx).state == :proposed

      # The rest of the flow runs without the caller.
      eventually(fn ->
        Ash.get!(Changeset, opened.id, tenant: ctx.org.id, authorize?: false).state == :evaluated
      end)
    end

    test "with no policy in scope the verdict is hold / no_policy_coverage (doc 06 §5.1), queued for review",
         ctx do
      assert {:ok, %{changeset: changeset, verdict: verdict}} = propose(ctx)

      assert changeset.state == :evaluated

      assert %Verdict{outcome: :hold, reason: :no_policy_coverage, policy_outcome: :hold} =
               verdict

      assert row(ctx).state == :proposed

      assert [%QueueEntry{changeset_id: cid, hold_reasons: [%{"reason" => "no_policy_coverage"}]}] =
               Ash.read!(QueueEntry,
                 tenant: ctx.org.id,
                 actor: System.new(:coordinator, ctx.org.id)
               )

      assert cid == changeset.id
    end

    test "the report's aggregates land on the changeset, in the doc 12 §5 shapes, with no row data",
         ctx do
      {:ok, %{changeset: changeset}} = propose(ctx)

      assert changeset.summary["format_version"] == 1
      assert [%{"table_name" => "products", "updates" => 12}] = changeset.summary["tables"]
      assert [%{"column_name" => "price", "changed_count" => 12}] = changeset.summary["columns"]

      assert changeset.impact == %{
               "format_version" => 1,
               "metrics" => [%{"name" => "rows_in_catalogue", "value" => 1200.0, "error" => nil}]
             }

      assert changeset.reversible == "complete"
      assert byte_size(changeset.row_delta_digest) == 32
      assert [%{"path" => "evidence/" <> _, "digest" => digest}] = changeset.evidence_refs
      assert digest =~ ~r/^[0-9a-f]{64}$/
    end

    test "the instruction sequence is freeze, then compute; the data plane froze the branch",
         ctx do
      {:ok, _} = propose(ctx)

      kinds = ctx.fake |> FakeDataPlane.received() |> Enum.map(fn %{body: {kind, _}} -> kind end)
      assert Enum.take(kinds, -2) == [:freeze_writes, :compute_changeset]
      assert %{frozen: true, freeze_marker: true} = FakeDataPlane.overlay(ctx.fake, ctx.branch.id)
      assert {:error, :branch_frozen} = FakeDataPlane.write(ctx.fake, ctx.branch.id)
    end

    test "the events: proposed, computing, evaluated, all in the audit trail", ctx do
      {:ok, _} = propose(ctx)
      types = for e <- events(ctx), do: e.type
      assert "branch.proposed" in types
      assert "changeset.computing" in types
      assert "changeset.evaluated" in types
    end

    test "compute carries the target's impact queries", ctx do
      alias Steward.Core.Targets.ImpactQuery

      ImpactQuery
      |> Ash.Changeset.for_create(
        :create,
        %{
          target_id: ctx.target.id,
          name: "catalogue.size",
          sql: "SELECT count(*) FROM products",
          created_by: ctx.admin.id
        },
        tenant: ctx.org.id,
        authorize?: false
      )
      |> Ash.create!()

      {:ok, _} = propose(ctx)

      compute =
        ctx.fake
        |> FakeDataPlane.received()
        |> Enum.find_value(fn
          %{body: {:compute_changeset, c}} -> c
          _ -> nil
        end)

      assert [%{name: "catalogue.size", sql: "SELECT count(*) FROM products", timeout_s: 30}] =
               compute.impact_queries

      assert compute.base_snapshot_ref == ctx.branch.base_snapshot_ref
    end
  end

  describe "the verdict decides what happens next (doc 13 §4)" do
    test "block rejects the branch, terminally, with the reason verdict_block", ctx do
      answer(:block)
      assert {:ok, %{verdict: %{outcome: :block}}} = propose(ctx)

      eventually(fn -> row(ctx).state == :rejected end)
      assert %{reason: :verdict_block, terminal_by_job: "policy"} = row(ctx)

      assert Ash.read!(QueueEntry,
               tenant: ctx.org.id,
               actor: System.new(:coordinator, ctx.org.id)
             ) == []

      eventually(fn -> Coordinator.whereis(ctx.branch.id) == nil end)
    end

    test "hold keeps it proposed with a queue entry", ctx do
      answer(:hold)
      assert {:ok, %{verdict: %{outcome: :hold, reason: :policies}}} = propose(ctx)
      assert row(ctx).state == :proposed

      assert [_] =
               Ash.read!(QueueEntry,
                 tenant: ctx.org.id,
                 actor: System.new(:coordinator, ctx.org.id)
               )
    end

    test "auto-merge keeps it proposed, no queue entry; starting the merge is E6 (visible in telemetry)",
         ctx do
      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        [:steward, :reactor, :merge_start_deferred],
        fn _, _, meta, _ -> send(parent, {:deferred, meta.branch_id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      answer(:"auto-merge")
      assert {:ok, %{verdict: %{outcome: :"auto-merge"}}} = propose(ctx)
      assert row(ctx).state == :proposed

      assert Ash.read!(QueueEntry,
               tenant: ctx.org.id,
               actor: System.new(:coordinator, ctx.org.id)
             ) == []

      branch_id = ctx.branch.id
      assert_receive {:deferred, ^branch_id}
    end

    test "6.3 f5: an evaluator that errors, or raises, holds with policy_error, never passes and never fails the flow",
         ctx do
      for failure <- [:error, :raise] do
        answer(failure)

        {:ok, branch} =
          Flows.create_branch(%{
            org_id: ctx.org.id,
            actor: ctx.key,
            target_id: ctx.target.id,
            idempotency_key: "k-#{failure}"
          })

        FakeDataPlane.write(ctx.fake, branch.id, rows: 1)

        assert {:ok, %{verdict: %{outcome: :hold, reason: :policy_error}}} =
                 Flows.propose(%{org_id: ctx.org.id, actor: ctx.key, branch_id: branch.id},
                   await: :finished
                 )
      end
    end
  end

  describe "6.3 f3: compute fails" do
    test "a retryable failure is retried under the same changeset id; three attempts in all",
         ctx do
      FakeDataPlane.script(ctx.fake, :compute_changeset, [
        {:compute_error, "adapter_unavailable", true},
        {:compute_error, "adapter_unavailable", true},
        :ok
      ])

      assert {:ok, %{changeset: changeset}} = propose(ctx)
      assert changeset.compute_attempts == 3
      assert changeset.state == :evaluated
      assert [only] = changesets(ctx)
      assert only.id == changeset.id
    end

    test "past the budget the flow fails and step 1 is undone: back to open, changeset superseded compute_failed",
         ctx do
      FakeDataPlane.script(
        ctx.fake,
        :compute_changeset,
        {:always, {:compute_error, "adapter_unavailable", true}}
      )

      assert {:error, {:compute_error, "adapter_unavailable", true}} = propose(ctx)

      assert row(ctx).state == :open

      assert [
               %Changeset{
                 state: :superseded,
                 superseded_reason: :compute_failed,
                 compute_attempts: 3
               }
             ] = changesets(ctx)

      assert Ash.read!(Verdict, tenant: ctx.org.id, actor: System.new(:coordinator, ctx.org.id)) ==
               []
    end

    test "a non-retryable error is one attempt, then undone", ctx do
      FakeDataPlane.script(
        ctx.fake,
        :compute_changeset,
        {:always, {:compute_error, "overlay_invalid", false}}
      )

      assert {:error, {:compute_error, "overlay_invalid", false}} = propose(ctx)

      assert [%Changeset{compute_attempts: 1, superseded_reason: :compute_failed}] =
               changesets(ctx)

      assert row(ctx).state == :open
    end

    test "a compute acknowledged but never reported times out per attempt: three attempts, then undone",
         ctx do
      FakeDataPlane.script(ctx.fake, :compute_changeset, {:always, :lose_report})
      put_coordinator_env(compute_wait_ms: 120)

      assert {:error, :compute_timeout} = propose(ctx)

      assert [%Changeset{compute_attempts: 3, superseded_reason: :compute_failed}] =
               changesets(ctx)

      assert row(ctx).state == :open
    end

    test "an engine that does not even acknowledge is the data plane being unreachable, retried the same way",
         ctx do
      FakeDataPlane.script(ctx.fake, :compute_changeset, {:always, :crash})

      assert {:error, :data_plane_unreachable} = propose(ctx)

      assert [%Changeset{compute_attempts: 3, superseded_reason: :compute_failed}] =
               changesets(ctx)

      assert row(ctx).state == :open
    end

    test "6.3 f4: a lost report is recomputed under the same id and succeeds", ctx do
      FakeDataPlane.script(ctx.fake, :compute_changeset, [:lose_report, :ok])
      put_coordinator_env(compute_wait_ms: 150)

      assert {:ok, %{changeset: changeset}} = propose(ctx)
      assert changeset.compute_attempts == 2
    end

    test "after the undo the branch can be proposed again, with a new changeset", ctx do
      FakeDataPlane.script(ctx.fake, :compute_changeset, [
        {:compute_error, "overlay_invalid", false}
      ])

      {:error, _} = propose(ctx)

      assert {:ok, %{changeset: second}} = propose(ctx)
      assert second.sequence == 2
      assert [%{state: :superseded}, %{state: :evaluated}] = changesets(ctx)
    end
  end

  test "6.2 f3: a lost base snapshot found by compute abandons the branch with snapshot_lost, and the unwind leaves it be",
       ctx do
    FakeDataPlane.lose_base_snapshot(ctx.fake, ctx.branch.id)

    assert {:error, :snapshot_lost} = propose(ctx)

    assert %{state: :abandoned, reason: :snapshot_lost} = row(ctx)
    assert [%Changeset{state: :superseded, superseded_reason: :snapshot_lost}] = changesets(ctx)
  end

  describe "6.3 f2: the freeze is lost" do
    test "the flow does not fail on it: compute reports the missing marker as retryable, and the heartbeat reply freezes the data plane in time",
         ctx do
      FakeDataPlane.script(ctx.fake, :freeze_writes, :drop)
      FakeDataPlane.script(ctx.fake, :compute_changeset, [:ok])

      task = Task.async(fn -> propose(ctx) end)
      # The branch is `proposed` now; the data plane learns it from its heartbeat reply.
      eventually(fn -> row(ctx).state == :proposed end)

      eventually(fn ->
        FakeDataPlane.heartbeat(ctx.fake) &&
          FakeDataPlane.overlay(ctx.fake, ctx.branch.id).freeze_marker
      end)

      assert {:ok, %{verdict: %{outcome: :hold}}} = Task.await(task, 10_000)
    end
  end

  describe "authority and state" do
    test "only the owner may propose, and nothing is sent to the data plane", ctx do
      stranger = principal(ctx.org, :agent)
      key = api_key(ctx.org, stranger, ~w(branch:write branch:propose), [ctx.target.id])
      before = length(FakeDataPlane.received(ctx.fake))

      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               Flows.propose(%{org_id: ctx.org.id, actor: key, branch_id: ctx.branch.id},
                 await: :finished
               )

      assert length(FakeDataPlane.received(ctx.fake)) == before
      assert row(ctx).state == :open
    end

    test "a key without branch:propose cannot", ctx do
      weak = api_key(ctx.org, ctx.agent, ~w(branch:write), [ctx.target.id])

      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               Flows.propose(%{org_id: ctx.org.id, actor: weak, branch_id: ctx.branch.id},
                 await: :finished
               )
    end

    test "proposing a branch that is not open is an invalid transition, not a second changeset",
         ctx do
      {:ok, _} = propose(ctx)
      assert {:error, :invalid_transition} = propose(ctx)
      assert length(changesets(ctx)) == 1
    end
  end

  describe "resume (a flow that died, doc 13 §6.3 f3)" do
    test "re-enters a proposed branch with a computing changeset and finishes it under the same id",
         ctx do
      {:ok, opened} =
        BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose, %{rationale: "x"})

      changeset = opened.__metadata__.changeset

      assert {:ok, %{changeset: evaluated, verdict: %{outcome: :hold}}} =
               Flows.resume_propose(%{org_id: ctx.org.id, branch_id: ctx.branch.id},
                 await: :finished
               )

      assert evaluated.id == changeset.id
      assert length(changesets(ctx)) == 1
    end

    test "has nothing to resume on an open branch", ctx do
      assert {:error, _} =
               Flows.resume_propose(%{org_id: ctx.org.id, branch_id: ctx.branch.id},
                 await: :finished
               )

      assert row(ctx).state == :open
    end
  end

  test "the revert conflict floor lifts auto-merge to hold, keeping the policy outcome (doc 13 §6.6)" do
    alias Steward.Coordinator.Reactors.Propose.Steps.Floor
    alias Steward.Plane.V1

    verdict = %{outcome: :"auto-merge", reason: :policies, policy_outcome: :"auto-merge"}
    clean = Fixtures.changeset_report("c", "b", "o")
    conflicted = %V1.ChangesetReport{clean | conflicts_count: 2}
    partial = %V1.ChangesetReport{clean | summary: %V1.Summary{partial_keys_count: 1}}

    run = fn branch, report, v ->
      {:ok, out} = Floor.run(%{opened: %{branch: branch}, report: report, verdict: v}, %{}, [])
      out
    end

    revert = %{revert_of_merge_id: Ecto.UUID.generate()}
    plain = %{revert_of_merge_id: nil}

    assert %{outcome: :hold, reason: :revert_conflict, policy_outcome: :"auto-merge"} =
             run.(revert, conflicted, verdict)

    assert %{outcome: :hold, reason: :revert_conflict} = run.(revert, partial, verdict)
    assert %{outcome: :"auto-merge"} = run.(revert, clean, verdict)
    assert %{outcome: :"auto-merge"} = run.(plain, conflicted, verdict)
    assert %{outcome: :block} = run.(revert, conflicted, %{verdict | outcome: :block})

    assert %{outcome: :hold, reason: :policies} =
             run.(revert, conflicted, %{verdict | outcome: :hold})
  end
end
