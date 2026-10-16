defmodule Steward.Authz.ParentResolvedTest do
  @moduledoc """
  Operations whose target (and, for reviews, owner) is read from a parent row
  rather than trusted from the request: review decisions, policy version
  activation, and revert (doc 15 §3.2, §3.3). Each case that a caller could
  win by lying about `target_id` or `branch_id` is here.
  """
  use Steward.DataCase, async: true

  import Steward.AuthzFixtures

  alias Steward.Core.Branches.Revert
  alias Steward.Core.Reviews.Review

  setup do
    org = org()
    admin = principal(org, :human, org_admin: true)
    agent = principal(org, :agent)
    svc = principal(org, :service)
    reviewer = principal(org, :human)
    reviewer_t2 = principal(org, :human)
    t1 = target(org, admin)
    t2 = target(org, admin)
    membership(org, t1, reviewer, :reviewer, admin)
    membership(org, t2, reviewer_t2, :reviewer, admin)

    branch = branch(org, t1, agent)
    changeset = changeset(org, branch)

    %{
      org: org,
      admin: admin,
      agent: agent,
      svc: svc,
      reviewer: human_actor(reviewer),
      reviewer_t2: human_actor(reviewer_t2),
      t1: t1,
      t2: t2,
      branch: branch,
      changeset: changeset
    }
  end

  defp can?(ctx, actor, subject), do: Ash.can?(subject, actor, tenant: ctx.org.id)

  describe "review decisions (R T ✓ · not the owner · A P O —)" do
    defp decide(ctx, by, overrides \\ %{}) do
      {Review, :create,
       Map.merge(
         %{
           changeset_id: ctx.changeset.id,
           branch_id: ctx.branch.id,
           target_id: ctx.t1.id,
           reviewer_principal_id: by.id,
           decision: :approved
         },
         overrides
       )}
    end

    test "a reviewer on the changeset's target may decide", ctx do
      assert can?(ctx, ctx.reviewer, decide(ctx, ctx.reviewer))
    end

    test "a reviewer on another target may not, however the request names the target", ctx do
      refute can?(ctx, ctx.reviewer_t2, decide(ctx, ctx.reviewer_t2))
      refute can?(ctx, ctx.reviewer_t2, decide(ctx, ctx.reviewer_t2, %{target_id: ctx.t2.id}))
    end

    test "a service key with review:decide may decide on a branch it does not own", ctx do
      key = api_key(ctx.org, ctx.svc, ["review:decide"], [ctx.t1.id])
      assert can?(ctx, key, decide(ctx, ctx.svc))

      refute can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["review:read"], [ctx.t1.id]),
               decide(ctx, ctx.svc)
             )
    end

    test "the branch owner may not approve their own branch, even holding review:decide", ctx do
      owner_svc = principal(ctx.org, :service)
      branch = branch(ctx.org, ctx.t1, owner_svc)
      cs = changeset(ctx.org, branch)
      key = api_key(ctx.org, owner_svc, ["review:decide"], [ctx.t1.id])

      input = %{
        changeset_id: cs.id,
        branch_id: branch.id,
        target_id: ctx.t1.id,
        reviewer_principal_id: owner_svc.id,
        decision: :approved
      }

      refute can?(ctx, key, {Review, :create, input})

      other = api_key(ctx.org, ctx.svc, ["review:decide"], [ctx.t1.id])
      assert can?(ctx, other, {Review, :create, %{input | reviewer_principal_id: ctx.svc.id}})
    end

    test "naming another branch cannot dodge the self-approval rule", ctx do
      owner_svc = principal(ctx.org, :service)
      mine = branch(ctx.org, ctx.t1, owner_svc)
      mine_cs = changeset(ctx.org, mine)
      key = api_key(ctx.org, owner_svc, ["review:decide"], [ctx.t1.id])

      lie = %{
        changeset_id: mine_cs.id,
        branch_id: ctx.branch.id,
        target_id: ctx.t1.id,
        reviewer_principal_id: owner_svc.id,
        decision: :approved
      }

      refute can?(ctx, key, {Review, :create, lie})
    end

    test "a reviewer cannot decide as someone else", ctx do
      refute can?(ctx, ctx.reviewer, decide(ctx, ctx.reviewer_t2))
    end

    test "a changeset that does not exist authorises nothing", ctx do
      refute can?(ctx, ctx.reviewer, decide(ctx, ctx.reviewer, %{changeset_id: uuid()}))
    end
  end

  describe "policy versions" do
    setup ctx do
      policy = policy(ctx.org, ctx.t1, ctx.admin)
      %{policy: policy, version: policy_version(ctx.org, policy, ctx.admin)}
    end

    test "activate needs policy:admin on the policy's target", ctx do
      policy_admin = principal(ctx.org, :human)
      membership(ctx.org, ctx.t1, policy_admin, :policy_admin, ctx.admin)

      assert can?(ctx, human_actor(policy_admin), {ctx.version, :activate})
      refute can?(ctx, ctx.reviewer, {ctx.version, :activate})

      assert can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["policy:admin"], [ctx.t1.id]),
               {ctx.version, :activate}
             )

      refute can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["policy:admin"], [ctx.t2.id]),
               {ctx.version, :activate}
             )

      refute can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["policy:write"], [ctx.t1.id]),
               {ctx.version, :activate}
             )
    end

    test "saving a version needs policy:write and records the caller as author", ctx do
      key = api_key(ctx.org, ctx.svc, ["policy:write"], [ctx.t1.id])

      input = fn saved_by ->
        {Steward.Core.Policies.PolicyVersion, :create,
         %{
           policy_id: ctx.policy.id,
           version: 2,
           yaml: "x",
           name: "x",
           scope: %{},
           outcome: :hold,
           saved_by: saved_by
         }}
      end

      assert can?(ctx, key, input.(ctx.svc.id))
      refute can?(ctx, key, input.(ctx.admin.id))

      refute can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["policy:write"], [ctx.t2.id]),
               input.(ctx.svc.id)
             )
    end

    test "the audit event names the principal, not the key", ctx do
      key = api_key(ctx.org, ctx.svc, ["policy:write"], [ctx.t1.id])

      Steward.Core.Policies.PolicyVersion
      |> Ash.Changeset.for_create(
        :create,
        %{
          policy_id: ctx.policy.id,
          version: 2,
          yaml: "x",
          name: "x",
          scope: %{},
          outcome: :hold,
          saved_by: ctx.svc.id
        },
        actor: key,
        tenant: ctx.org.id
      )
      |> Ash.create!()

      events =
        Ash.read!(Steward.Core.Audit.Event, actor: system(:api, ctx.org), tenant: ctx.org.id)

      event =
        Enum.find(
          events,
          &(&1.type == "policy.version_saved" and &1.payload != nil and
              &1.actor_principal_id == ctx.svc.id)
        )

      assert event
      refute Enum.any?(events, &(&1.actor_principal_id == key.id))
    end
  end

  describe "revert (T ✓ · S merge:revert · agents never)" do
    setup ctx do
      %{merge: merge(ctx.org, ctx.branch, ctx.changeset)}
    end

    defp revert(ctx, by, overrides \\ %{}) do
      {Revert, :create,
       Map.merge(%{target_id: ctx.t1.id, merge_id: ctx.merge.id, requested_by: by.id}, overrides)}
    end

    test "target_admin, or a service key with merge:revert or target:admin", ctx do
      t_admin = principal(ctx.org, :human)
      membership(ctx.org, ctx.t1, t_admin, :target_admin, ctx.admin)

      assert can?(ctx, human_actor(t_admin), revert(ctx, t_admin))

      assert can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["merge:revert"], [ctx.t1.id]),
               revert(ctx, ctx.svc)
             )

      assert can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["target:admin"], [ctx.t1.id]),
               revert(ctx, ctx.svc)
             )
    end

    test "not a reviewer, not an agent key, not a key on another target", ctx do
      refute can?(ctx, ctx.reviewer, revert(ctx, ctx.reviewer))

      refute can?(
               ctx,
               api_key(ctx.org, ctx.agent, ["branch:write", "changeset:read"], [ctx.t1.id]),
               revert(ctx, ctx.agent)
             )

      refute can?(
               ctx,
               api_key(ctx.org, ctx.svc, ["merge:revert"], [ctx.t2.id]),
               revert(ctx, ctx.svc)
             )
    end

    test "the target is the merge's own, whatever the request says", ctx do
      key = api_key(ctx.org, ctx.svc, ["merge:revert"], [ctx.t2.id])
      refute can?(ctx, key, revert(ctx, ctx.svc, %{target_id: ctx.t2.id}))
    end

    test "requested_by must be the caller", ctx do
      key = api_key(ctx.org, ctx.svc, ["merge:revert"], [ctx.t1.id])
      refute can?(ctx, key, revert(ctx, ctx.admin))
    end
  end
end
