defmodule Steward.Coordinator.BranchProcessTest do
  @moduledoc """
  The per-branch process (doc 07 §4, §5.3): one process per non-terminal
  branch, state a cache of the row, every transition an Ash action guarded by
  `lock_version`, terminal branches have no process.
  """
  use Steward.CoordinatorCase

  setup do
    org = org()
    owner = principal(org, :agent)
    target = target(org, principal(org, :human))
    %{org: org, owner: owner, target: target, branch: branch(org, target, owner)}
  end

  defp abandon_params(ctx),
    do: %{reason: :abandoned_by_principal, terminal_by_principal_id: ctx.owner.id}

  defp out_of_band(ctx, record, action, params) do
    record
    |> Ash.Changeset.for_update(action, params,
      tenant: ctx.org.id,
      actor: System.new(:coordinator, ctx.org.id)
    )
    |> Ash.update!()
  end

  describe "starting" do
    test "a process is registered under the branch id and has loaded the row", ctx do
      assert {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      assert Coordinator.whereis(ctx.branch.id) == pid
      assert %{id: id, state: :open} = BranchProcess.get(pid)
      assert id == ctx.branch.id
    end

    test "starting is idempotent, even from many callers at once", ctx do
      pids =
        1..20
        |> Task.async_stream(fn _ -> BranchProcess.ensure_started(ctx.org.id, ctx.branch.id) end)
        |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)
        |> Enum.uniq()

      assert [_one] = pids
      assert Coordinator.count() == 1
    end

    test "a branch that does not exist, or is another org's, has no process", ctx do
      assert {:error, :not_found} = BranchProcess.ensure_started(ctx.org.id, uuid())

      other = org()
      assert {:error, :not_found} = BranchProcess.ensure_started(other.id, ctx.branch.id)
      assert Coordinator.count() == 0
    end

    test "a terminal branch gets no process (doc 07 §6)", ctx do
      out_of_band(ctx, ctx.branch, :abandon, abandon_params(ctx))

      assert {:error, :terminal} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      assert Coordinator.count() == 0
    end

    test "a killed process is restarted and rebuilds its cache from the row", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, :killed}

      new_pid = eventually(fn -> (p = Coordinator.whereis(ctx.branch.id)) && p != pid && p end)
      assert %{state: :open} = BranchProcess.get(new_pid)
    end

    test "a restart does not trust a stale record hint", ctx do
      previous = Application.get_env(:steward, Steward.Coordinator, [])

      Application.put_env(
        :steward,
        Steward.Coordinator,
        Keyword.put(previous, :record_hint_ms, 50)
      )

      on_exit(fn -> Application.put_env(:steward, Steward.Coordinator, previous) end)

      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id, record: ctx.branch)
      out_of_band(ctx, ctx.branch, :propose, %{})

      # Past the hint's validity a restarted process re-reads the row.
      :sys.replace_state(pid, & &1)
      Process.sleep(80)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      new_pid = eventually(fn -> (p = Coordinator.whereis(ctx.branch.id)) && p != pid && p end)

      assert %{state: :proposed} = BranchProcess.get(new_pid)
    end
  end

  describe "transitions" do
    test "run the Ash action, update the cache, and bump lock_version", ctx do
      {:ok, _} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)

      assert {:ok, record} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)
      assert record.state == :proposed
      assert record.lock_version == ctx.branch.lock_version + 1
      assert %{state: :proposed} = BranchProcess.get(Coordinator.whereis(ctx.branch.id))

      row = Ash.get!(Branch, ctx.branch.id, tenant: ctx.org.id, authorize?: false)
      assert row.state == :proposed
      assert row.lock_version == record.lock_version
    end

    test "start the process if there is none", ctx do
      assert Coordinator.whereis(ctx.branch.id) == nil

      assert {:ok, %{state: :proposed}} =
               BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)

      assert Coordinator.whereis(ctx.branch.id)
    end

    test "an undeclared transition is refused and changes nothing", ctx do
      {:ok, _} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)
      before = BranchProcess.get(Coordinator.whereis(ctx.branch.id))

      assert {:error, :invalid_transition} =
               BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)

      assert BranchProcess.get(Coordinator.whereis(ctx.branch.id)) == before
    end

    test "a terminal transition commits, then the process stops itself", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      ref = Process.monitor(pid)

      assert {:ok, %{state: :abandoned, reason: :abandoned_by_principal}} =
               BranchProcess.transition(ctx.org.id, ctx.branch.id, :abandon, abandon_params(ctx))

      assert_receive {:DOWN, ^ref, _, _, :normal}
      assert eventually(fn -> Coordinator.whereis(ctx.branch.id) == nil end)

      assert {:error, :terminal} =
               BranchProcess.transition(ctx.org.id, ctx.branch.id, :close, %{})
    end

    test "a stale cache fails as stale_transition, refreshes, and a retry succeeds (doc 07 §5)",
         ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)

      # Another writer moves the branch behind the process's back, and the notification is
      # lost (a partition, a node that was down): written straight to the row, which is
      # exactly the case the `lock_version` guard exists for.
      Ecto.Adapters.SQL.query!(
        Steward.Repo,
        "UPDATE branches SET state = 'proposed', proposed_at = now(), lock_version = lock_version + 1 WHERE id = $1",
        [Ecto.UUID.dump!(ctx.branch.id)]
      )

      moved_version = ctx.branch.lock_version + 1
      assert BranchProcess.get(pid).lock_version == ctx.branch.lock_version

      # `abandon` is valid from the cached `open`; the row has moved on, so the lock refuses it.
      assert {:error, :stale_transition} =
               BranchProcess.transition(ctx.org.id, ctx.branch.id, :abandon, abandon_params(ctx))

      assert BranchProcess.get(pid).lock_version == moved_version
      assert BranchProcess.get(pid).state == :proposed

      assert {:ok, %{state: :open}} =
               BranchProcess.transition(ctx.org.id, ctx.branch.id, :withdraw, %{})
    end

    test "concurrent transitions are serialised; exactly one propose wins", ctx do
      results =
        1..10
        |> Task.async_stream(fn _ ->
          BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_transition})) == 9
    end

    test "the actor is the coordinator system actor, and an event is appended in the same transaction",
         ctx do
      {:ok, _} =
        BranchProcess.transition(ctx.org.id, ctx.branch.id, :abandon, abandon_params(ctx))

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

    test "a user actor cannot drive a coordinator-only transition through the process", ctx do
      human = principal(ctx.org, :human, org_admin: true)
      {:ok, _} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)

      assert {:error, %Ash.Error.Forbidden{}} =
               BranchProcess.transition(
                 ctx.org.id,
                 ctx.branch.id,
                 :start_merge,
                 %{merge_id: uuid()},
                 actor: human
               )
    end
  end

  describe "the self-tick (doc 03 principle 4)" do
    test "re-reads the row, so an out-of-band change reaches the cache", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id, tick_ms: 40)
      out_of_band(ctx, ctx.branch, :propose, %{})

      assert eventually(fn -> BranchProcess.get(pid).state == :proposed end)
    end

    test "stops the process when the branch has gone terminal", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id, tick_ms: 40)
      ref = Process.monitor(pid)
      out_of_band(ctx, ctx.branch, :abandon, abandon_params(ctx))

      assert_receive {:DOWN, ^ref, _, _, :normal}, 2_000
    end
  end

  describe "notifications (Steward.Core.Branches.Notifier)" do
    test "a change made behind the process reaches its cache after commit, without waiting for the tick",
         ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      out_of_band(ctx, ctx.branch, :propose, %{})

      assert eventually(fn -> BranchProcess.get(pid).state == :proposed end)
    end

    test "a terminal change behind its back stops the process", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      ref = Process.monitor(pid)
      out_of_band(ctx, ctx.branch, :abandon, abandon_params(ctx))

      assert_receive {:DOWN, ^ref, _, _, :normal}, 2_000
    end

    test "the echo of the process's own transition is not a second read", ctx do
      {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
      {:ok, updated} = BranchProcess.transition(ctx.org.id, ctx.branch.id, :propose)
      Process.sleep(50)

      assert BranchProcess.get(pid).lock_version == updated.lock_version
    end
  end

  test "refresh/1 picks up an out-of-band change at once", ctx do
    {:ok, pid} = BranchProcess.ensure_started(ctx.org.id, ctx.branch.id)
    out_of_band(ctx, ctx.branch, :propose, %{})
    BranchProcess.refresh(pid)
    assert eventually(fn -> BranchProcess.get(pid).state == :proposed end)
  end
end
