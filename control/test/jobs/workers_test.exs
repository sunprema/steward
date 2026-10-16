defmodule Steward.Jobs.WorkersTest do
  @moduledoc """
  The two cron workers that call into the coordinator (`Steward.Jobs`): the
  terminal-process sweep, and the resumption of a `Propose` flow that died
  (doc 13 §6.3 f3, doc 07 §6).
  """
  use Steward.CoordinatorCase

  require Ash.Query

  alias Steward.Core.Branches.Changeset
  alias Steward.FakeDataPlane
  alias Steward.Jobs.{ResumeComputing, TerminalProcessSweep}

  setup_all do
    Steward.SessionHarness.start_listener()
  end

  setup ctx do
    put_coordinator_env(instruction_deadline_ms: 400, compute_wait_ms: 400)
    world = Steward.SessionHarness.world(ctx)

    {:ok, branch} =
      Steward.Coordinator.Flows.create_branch(%{
        org_id: world.org.id,
        actor: world.key,
        target_id: world.target.id,
        idempotency_key: "k"
      })

    FakeDataPlane.write(world.fake, branch.id, rows: 3)
    Map.put(world, :branch, branch)
  end

  defp row(ctx), do: Ash.get!(Branch, ctx.branch.id, tenant: ctx.org.id, authorize?: false)
  defp sys(ctx), do: System.new(:coordinator, ctx.org.id)

  defp changesets(ctx),
    do:
      Changeset
      |> Ash.Query.filter(branch_id == ^ctx.branch.id)
      |> Ash.read!(tenant: ctx.org.id, actor: sys(ctx))

  defp job, do: %Oban.Job{args: %{}}

  describe "TerminalProcessSweep" do
    test "starts a process for a live branch that has none (the stopping half is tested with the sweep itself)",
         ctx do
      stop_all()
      eventually(fn -> Coordinator.whereis(ctx.branch.id) == nil end)

      assert :ok = TerminalProcessSweep.perform(job())
      assert Coordinator.whereis(ctx.branch.id)
    end

    test "is on the crontab, every ten minutes" do
      {_, opts} =
        :steward
        |> Application.fetch_env!(Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

      assert {"*/10 * * * *", TerminalProcessSweep} in opts[:crontab]
      assert {"* * * * *", ResumeComputing} in opts[:crontab]
    end
  end

  describe "ResumeComputing (doc 13 §6.3 f3)" do
    # The flow that opened the changeset died before computing it: the branch is
    # proposed, the changeset computing, and nothing is working on either.
    defp orphaned_flow(ctx) do
      {:ok, branch} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)
      branch.__metadata__.changeset
    end

    test "re-enters Propose for a changeset left computing past the threshold; the same changeset is evaluated",
         ctx do
      put_coordinator_env(resume_after_ms: 0)
      changeset = orphaned_flow(ctx)
      Process.sleep(5)

      assert :ok = ResumeComputing.perform(job())

      eventually(fn ->
        Ash.get!(Changeset, changeset.id, tenant: ctx.org.id, authorize?: false).state ==
          :evaluated
      end)

      assert [only] = changesets(ctx)
      assert only.id == changeset.id
      assert row(ctx).state == :proposed
    end

    test "leaves a changeset younger than the threshold alone (its flow may be alive)", ctx do
      put_coordinator_env(resume_after_ms: 60_000)
      changeset = orphaned_flow(ctx)

      assert :ok = ResumeComputing.perform(job())
      Process.sleep(100)

      assert Ash.get!(Changeset, changeset.id, tenant: ctx.org.id, authorize?: false).state ==
               :computing

      refute Enum.any?(
               FakeDataPlane.received(ctx.fake),
               &match?(%{body: {:compute_changeset, _}}, &1)
             )
    end

    test "a resumed flow that cannot compute ends as any other: superseded compute_failed, the branch open again",
         ctx do
      put_coordinator_env(resume_after_ms: 0)

      FakeDataPlane.script(
        ctx.fake,
        :compute_changeset,
        {:always, {:compute_error, "overlay_invalid", false}}
      )

      changeset = orphaned_flow(ctx)
      Process.sleep(5)

      ResumeComputing.perform(job())

      eventually(fn -> row(ctx).state == :open end)

      assert %Changeset{state: :superseded, superseded_reason: :compute_failed} =
               Ash.get!(Changeset, changeset.id, tenant: ctx.org.id, authorize?: false)
    end

    test "a branch with nothing computing is untouched", ctx do
      put_coordinator_env(resume_after_ms: 0)
      assert :ok = ResumeComputing.perform(job())
      assert row(ctx).state == :open
      assert changesets(ctx) == []
    end
  end
end
