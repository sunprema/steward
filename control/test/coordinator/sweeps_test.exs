defmodule Steward.Coordinator.SweepsTest do
  @moduledoc """
  `BootSweeper` rebuilds processes after a restart; `TerminalProcessSweep` keeps
  processes and rows in step (doc 07 §4, §6).
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.{BootSweeper, TerminalProcessSweep}

  setup do
    org_a = org()
    org_b = org()
    owner_a = principal(org_a, :agent)
    owner_b = principal(org_b, :agent)
    target_a = target(org_a, principal(org_a, :human))
    target_b = target(org_b, principal(org_b, :human))
    %{a: {org_a, owner_a, target_a}, b: {org_b, owner_b, target_b}}
  end

  defp make(org, owner, target, to \\ :open) do
    b = branch(org, target, owner)

    update = fn record, action, params ->
      record
      |> Ash.Changeset.for_update(action, params,
        tenant: org.id,
        actor: System.new(:coordinator, org.id)
      )
      |> Ash.update!()
    end

    case to do
      :open ->
        b

      :proposed ->
        update.(b, :propose, %{})

      :merging ->
        b |> update.(:propose, %{}) |> update.(:start_merge, %{merge_id: uuid()})

      :abandoned ->
        update.(b, :abandon, %{
          reason: :abandoned_by_principal,
          terminal_by_principal_id: owner.id
        })
    end
  end

  describe "BootSweeper.run/0" do
    test "starts a process for every non-terminal branch in every org, and none for terminal ones",
         %{a: {oa, pa, ta}, b: {ob, pb, tb}} do
      open_a = make(oa, pa, ta)
      proposed_a = make(oa, pa, ta, :proposed)
      merging_b = make(ob, pb, tb, :merging)
      done_b = make(ob, pb, tb, :abandoned)

      assert %{started: 3, present: 0} = BootSweeper.run()

      for b <- [open_a, proposed_a, merging_b], do: assert(Coordinator.whereis(b.id))
      assert Coordinator.whereis(done_b.id) == nil
      assert Coordinator.count() == 3
    end

    test "is idempotent: a second run finds them all present", %{a: {oa, pa, ta}} do
      for _ <- 1..3, do: make(oa, pa, ta)
      assert %{started: 3} = BootSweeper.run()
      assert %{started: 0, present: 3} = BootSweeper.run()
      assert Coordinator.count() == 3
    end

    test "processes started by the sweep hold the right state", %{a: {oa, pa, ta}} do
      proposed = make(oa, pa, ta, :proposed)
      BootSweeper.run()

      assert %{state: :proposed} = BranchProcess.get(Coordinator.whereis(proposed.id))
    end

    test "the node is ready only once the sweep has finished", %{a: {oa, pa, ta}} do
      for _ <- 1..5, do: make(oa, pa, ta)

      start_supervised!(BootSweeper)
      assert eventually(&BootSweeper.ready?/0)
      assert Coordinator.count() == 5
    end
  end

  describe "TerminalProcessSweep.run/0" do
    test "stops a process whose row went terminal behind its back", %{a: {oa, pa, ta}} do
      b = make(oa, pa, ta)
      {:ok, pid} = BranchProcess.ensure_started(oa.id, b.id)
      ref = Process.monitor(pid)

      # Terminal behind the process's back, with the notification lost: straight to the row.
      Ecto.Adapters.SQL.query!(
        Steward.Repo,
        "UPDATE branches SET state = 'abandoned', reason = 'abandoned_by_principal', terminal_at = now(), terminal_by_job = 'test', lock_version = lock_version + 1 WHERE id = $1",
        [Ecto.UUID.dump!(b.id)]
      )

      assert %{stopped: 1} = TerminalProcessSweep.run()
      assert_receive {:DOWN, ^ref, _, _, :normal}
    end

    test "starts a non-terminal branch that has no process (a crashed or lost one)", %{
      a: {oa, pa, ta}
    } do
      b = make(oa, pa, ta)
      assert Coordinator.whereis(b.id) == nil

      assert %{started: 1, stopped: 0} = TerminalProcessSweep.run()
      assert Coordinator.whereis(b.id)
    end

    test "leaves live processes alone", %{a: {oa, pa, ta}} do
      b = make(oa, pa, ta)
      {:ok, pid} = BranchProcess.ensure_started(oa.id, b.id)

      assert %{stopped: 0, started: 0} = TerminalProcessSweep.run()
      assert Coordinator.whereis(b.id) == pid
    end

    test "stops processes for branches that no longer exist at all", %{a: {oa, pa, ta}} do
      b = make(oa, pa, ta)
      {:ok, pid} = BranchProcess.ensure_started(oa.id, b.id)

      Ecto.Adapters.SQL.query!(Steward.Repo, "DELETE FROM branches WHERE id = $1", [
        Ecto.UUID.dump!(b.id)
      ])

      assert %{stopped: 1} = TerminalProcessSweep.run()
      refute Process.alive?(pid)
    end
  end
end
