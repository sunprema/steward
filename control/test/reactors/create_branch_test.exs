defmodule Steward.Coordinator.Reactors.CreateBranchTest do
  @moduledoc """
  Create branch (doc 13 §6.1), end to end: the reactor, the real `Session`
  listener, and the E13 fake data plane. Test names carry the failure row.
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.Flows
  alias Steward.Core.Branches.CreateIntent
  alias Steward.FakeDataPlane
  alias Steward.Plane.V1

  setup_all do
    Steward.SessionHarness.start_listener()
  end

  setup ctx do
    put_coordinator_env(instruction_deadline_ms: 400)
    Steward.SessionHarness.world(ctx)
  end

  defp params(ctx, key \\ "key-1", extra \\ %{}),
    do:
      Map.merge(
        %{org_id: ctx.org.id, actor: ctx.key, target_id: ctx.target.id, idempotency_key: key},
        extra
      )

  defp intents(ctx),
    do: Ash.read!(CreateIntent, tenant: ctx.org.id, actor: System.new(:coordinator, ctx.org.id))

  defp branches(ctx),
    do: Ash.read!(Branch, tenant: ctx.org.id, actor: System.new(:coordinator, ctx.org.id))

  defp kinds(fake), do: Enum.map(FakeDataPlane.received(fake), fn %{body: {kind, _}} -> kind end)

  test "creates a branch: overlay on the data plane, row open, process running, route added",
       ctx do
    assert {:ok, branch} = Flows.create_branch(params(ctx))

    assert branch.state == :open
    assert branch.target_id == ctx.target.id
    assert branch.principal_id == ctx.agent.id
    assert branch.idempotency_key == "key-1"

    # The ids agree on both sides: the control plane picked the branch id, the data plane the overlay id.
    overlay = FakeDataPlane.overlay(ctx.fake, branch.id)
    assert overlay.overlay_id == branch.overlay_id
    assert overlay.target_id == ctx.target.id

    # TTL: the default branch_ttl, 24 hours.
    assert_in_delta DateTime.diff(branch.ttl_expires_at, DateTime.utc_now()), 24 * 3600, 5

    assert Coordinator.whereis(branch.id)
    eventually(fn -> FakeDataPlane.write(ctx.fake, branch.id) == :ok end)
    assert kinds(ctx.fake) == [:initialise_overlay, :routing_upsert]
  end

  test "the intent is committed once the branch exists", ctx do
    {:ok, branch} = Flows.create_branch(params(ctx))
    assert [%{state: :committed, branch_id: branch_id}] = intents(ctx)
    assert branch_id == branch.id
  end

  test "the routing entry carries the principal's key hashes, never a secret", ctx do
    {:ok, branch} = Flows.create_branch(params(ctx))

    assert %V1.Instruction{body: {:routing_upsert, upsert}} =
             List.last(FakeDataPlane.received(ctx.fake))

    assert upsert.branch_id == branch.id
    assert upsert.overlay_id == branch.overlay_id
    assert upsert.state == :AUTH_OPEN

    assert [%V1.ApiKeyEntry{key_hash: hash, principal_id: principal_id, revoked: false}] =
             upsert.api_keys

    assert hash == ctx.key.secret_sha256
    assert principal_id == ctx.agent.id
  end

  test "6.1 f7: the same idempotency key returns the same branch, with no new data-plane traffic",
       ctx do
    {:ok, first} = Flows.create_branch(params(ctx))
    before = length(FakeDataPlane.received(ctx.fake))

    assert {:ok, again} = Flows.create_branch(params(ctx))
    assert again.id == first.id
    assert length(FakeDataPlane.received(ctx.fake)) == before
    assert length(branches(ctx)) == 1
  end

  test "different keys make different branches", ctx do
    {:ok, a} = Flows.create_branch(params(ctx, "a"))
    {:ok, b} = Flows.create_branch(params(ctx, "b"))
    assert a.id != b.id
    assert a.overlay_id != b.overlay_id
  end

  describe "failures before the checkpoint leave nothing (doc 13 §6.1)" do
    test "6.1 f2: data plane unreachable → :data_plane_unreachable, no branch, intent failed",
         ctx do
      FakeDataPlane.script(ctx.fake, :initialise_overlay, :drop)

      assert {:error, :data_plane_unreachable} = Flows.create_branch(params(ctx))
      assert branches(ctx) == []
      assert [%{state: :failed}] = intents(ctx)
    end

    test "6.1 f3: the data plane refuses the overlay → {:rejected, code}", ctx do
      FakeDataPlane.script(
        ctx.fake,
        :initialise_overlay,
        {:error, "object_store_unavailable", "synthetic"}
      )

      assert {:error, {:rejected, "object_store_unavailable"}} = Flows.create_branch(params(ctx))
      assert branches(ctx) == []
      assert [%{state: :failed}] = intents(ctx)
    end

    test "a retry after a failure uses fresh ids and succeeds; one intent per key, started again",
         ctx do
      FakeDataPlane.script(ctx.fake, :initialise_overlay, :drop)
      {:error, :data_plane_unreachable} = Flows.create_branch(params(ctx))

      assert {:ok, branch} = Flows.create_branch(params(ctx))
      assert [%{state: :committed, branch_id: id}] = intents(ctx)
      assert id == branch.id
    end

    test "6.1 f4/f5: the reply is lost; the overlay is an orphan, the retry gets fresh ids, the heartbeat kills the orphan",
         ctx do
      FakeDataPlane.script(ctx.fake, :initialise_overlay, :lose_reply)
      assert {:error, :data_plane_unreachable} = Flows.create_branch(params(ctx))
      assert [{orphan_id, orphan}] = Enum.to_list(FakeDataPlane.overlays(ctx.fake))
      assert branches(ctx) == []

      {:ok, branch} = Flows.create_branch(params(ctx))
      assert branch.id != orphan_id
      assert branch.overlay_id != orphan.overlay_id

      FakeDataPlane.heartbeat(ctx.fake)
      eventually(fn -> FakeDataPlane.overlay(ctx.fake, orphan_id) == nil end)
      assert FakeDataPlane.overlay(ctx.fake, branch.id)
    end

    test "a target with no data plane, or no such target, is refused before any instruction",
         ctx do
      bare = target(ctx.org, ctx.admin)
      key = api_key(ctx.org, ctx.agent, ~w(branch:write), [bare.id])

      assert {:error, :no_data_plane} =
               Flows.create_branch(%{params(ctx) | target_id: bare.id, actor: key})

      assert FakeDataPlane.received(ctx.fake) == []
    end
  end

  describe "authority is checked on the intent, as the caller" do
    test "a key without branch:write is refused, and nothing reaches the data plane", ctx do
      weak = api_key(ctx.org, ctx.agent, ~w(changeset:read), [ctx.target.id])

      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               Flows.create_branch(%{params(ctx) | actor: weak})

      assert FakeDataPlane.received(ctx.fake) == []
      assert branches(ctx) == []
    end

    test "a key for another target is refused", ctx do
      elsewhere = api_key(ctx.org, ctx.agent, ~w(branch:write), [Ecto.UUID.generate()])

      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               Flows.create_branch(%{params(ctx) | actor: elsewhere})

      assert FakeDataPlane.received(ctx.fake) == []
    end

    test "a reviewer cannot create branches", ctx do
      reviewer = principal(ctx.org, :human)
      membership(ctx.org, ctx.target, reviewer, :reviewer, ctx.admin)

      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               Flows.create_branch(%{params(ctx) | actor: human_actor(reviewer)})
    end
  end

  describe "6.1 f6: the routing add is best effort" do
    test "a lost routing add does not undo the branch; the heartbeat reply repairs it", ctx do
      FakeDataPlane.script(ctx.fake, :routing_upsert, :drop)

      assert {:ok, branch} = Flows.create_branch(params(ctx))
      assert {:error, :branch_not_routable} = FakeDataPlane.write(ctx.fake, branch.id)

      FakeDataPlane.heartbeat(ctx.fake)
      eventually(fn -> FakeDataPlane.write(ctx.fake, branch.id) == :ok end)
    end

    test "the branch is open and its process runs even when every post-checkpoint step failed",
         ctx do
      FakeDataPlane.script(ctx.fake, :routing_upsert, {:always, :drop})
      assert {:ok, branch} = Flows.create_branch(params(ctx))
      assert %{state: :open} = Ash.get!(Branch, branch.id, tenant: ctx.org.id, authorize?: false)
      assert Coordinator.whereis(branch.id)
    end
  end

  test "an event records the creation, attributed to the system actor that wrote the row", ctx do
    {:ok, branch} = Flows.create_branch(params(ctx))

    events =
      Ash.read!(Steward.Core.Audit.Event, tenant: ctx.org.id, actor: System.new(:api, ctx.org.id))

    assert Enum.any?(events, &(&1.type == "branch.created" and &1.aggregate_id == branch.id))
  end
end
