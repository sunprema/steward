defmodule Steward.Authz.ReadScopeTest do
  @moduledoc """
  Reads are filtered, not refused (doc 15 §3.2, §4.1): an actor sees the rows
  on targets where they hold the scope, plus their own branches, and a row in
  another org or on another target is simply absent, so a tenant cannot tell
  absent from foreign (doc 10 §2.1, doc 15 §4.1 point 3).
  """
  use Steward.DataCase, async: true

  import Steward.AuthzFixtures

  alias Steward.Core.Branches.Branch
  alias Steward.Core.Targets.{Target, TargetMembership}

  setup do
    org = org()
    admin = principal(org, :human, org_admin: true)
    agent = principal(org, :agent)
    other_agent = principal(org, :agent)
    reviewer = principal(org, :human)
    t1 = target(org, admin)
    t2 = target(org, admin)
    membership(org, t1, reviewer, :reviewer, admin)

    %{
      org: org,
      admin: admin,
      agent: agent,
      other_agent: other_agent,
      reviewer: reviewer,
      t1: t1,
      t2: t2,
      mine: branch(org, t1, agent),
      theirs_t1: branch(org, t1, other_agent),
      theirs_t2: branch(org, t2, other_agent)
    }
  end

  defp ids(records), do: records |> Enum.map(& &1.id) |> Enum.sort()

  # Rows the actor may see, or `:forbidden` when no policy lets them read the
  # resource at all (they hold no applicable scope). A record on a target they
  # have no scope for is the other case: filtered out, so absent (404).
  defp read(resource, actor, org) do
    case Ash.read(resource, actor: actor, tenant: org.id) do
      {:ok, rows} -> rows
      {:error, %Ash.Error.Forbidden{}} -> :forbidden
    end
  end

  describe "branches" do
    test "a key sees its own branch and, with changeset:read, the branches on its targets", ctx do
      owner_only = api_key(ctx.org, ctx.agent, ["branch:write"], [ctx.t1.id])
      assert ids(read(Branch, owner_only, ctx.org)) == ids([ctx.mine])

      readers = api_key(ctx.org, ctx.agent, ["changeset:read"], [ctx.t1.id])
      assert ids(read(Branch, readers, ctx.org)) == ids([ctx.mine, ctx.theirs_t1])
    end

    test "a reviewer sees branches on the targets they are a member of, not others", ctx do
      assert ids(read(Branch, human_actor(ctx.reviewer), ctx.org)) ==
               ids([ctx.mine, ctx.theirs_t1])
    end

    test "a human with no membership sees nothing; an org_admin is not a target reader", ctx do
      nobody = principal(ctx.org, :human)
      assert read(Branch, human_actor(nobody), ctx.org) == []
      assert read(Branch, human_actor(ctx.admin), ctx.org) == []
    end

    test "system actors read everything in their org", ctx do
      all = ids([ctx.mine, ctx.theirs_t1, ctx.theirs_t2])
      assert ids(read(Branch, system(:coordinator, ctx.org), ctx.org)) == all
    end

    test "an actor from another org sees nothing, even with the right scope", ctx do
      org_b = org()
      p = principal(org_b, :agent)
      t = target(org_b, principal(org_b, :human))
      foreign = api_key(org_b, p, ["changeset:read"], [t.id])

      assert read(Branch, foreign, ctx.org) == :forbidden
      assert read(Branch, foreign, org_b) == []
    end

    test "a revoked key sees nothing", ctx do
      key = api_key(ctx.org, ctx.agent, ["changeset:read"], [ctx.t1.id])
      assert read(Branch, %{key | revoked_at: DateTime.utc_now()}, ctx.org) == :forbidden
    end
  end

  describe "targets and memberships" do
    test "an actor sees the targets they hold a scope on", ctx do
      assert ids(read(Target, human_actor(ctx.reviewer), ctx.org)) == ids([ctx.t1])

      svc = principal(ctx.org, :service)
      key = api_key(ctx.org, svc, ["review:read"], [ctx.t2.id])
      assert ids(read(Target, key, ctx.org)) == ids([ctx.t2])
    end

    test "memberships: target_admin sees all on the target, anyone sees their own", ctx do
      third = principal(ctx.org, :human)
      membership(ctx.org, ctx.t1, third, :target_admin, ctx.admin)

      reviewer_sees = read(TargetMembership, human_actor(ctx.reviewer), ctx.org)
      assert Enum.map(reviewer_sees, & &1.principal_id) == [ctx.reviewer.id]

      admin_sees = read(TargetMembership, human_actor(third), ctx.org)

      assert Enum.sort(Enum.map(admin_sees, & &1.principal_id)) ==
               Enum.sort([ctx.reviewer.id, third.id])
    end
  end

  describe "audit events" do
    test "org-level audit:read, not target scoped" do
      org = org()
      admin = principal(org, :human, org_admin: true)
      agent = principal(org, :agent)
      t = target(org, admin)
      _ = branch(org, t, agent)

      assert [_ | _] = read(Steward.Core.Audit.Event, human_actor(admin), org)

      assert [_ | _] =
               read(
                 Steward.Core.Audit.Event,
                 api_key(org, principal(org, :service), ["audit:read"], []),
                 org
               )

      reader = api_key(org, principal(org, :service), ["changeset:read"], [t.id])
      assert :forbidden = read(Steward.Core.Audit.Event, reader, org)
      assert :forbidden = read(Steward.Core.Audit.Event, human_actor(agent), org)
    end
  end
end
