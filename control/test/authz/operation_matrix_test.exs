defmodule Steward.Authz.OperationMatrixTest do
  @moduledoc """
  Doc 15 §3.2, transcribed: each operation × actor cell is an expected `true`
  or `false` from `Ash.can?/3`, so a change to the matrix must change this
  file (doc 07 §10). No database: records are structs and every check here
  reads the actor and the record.

  Operations whose authority is read off a parent row (review, policy
  activation, revert) are in `parent_resolved_test.exs`; read filters are in
  `read_scope_test.exs`.

  Columns follow the doc: A agent key, S service key, R reviewer, P
  policy_admin, T target_admin, O org_admin. "S" is exercised with the scope the
  matrix names for it.
  """
  use ExUnit.Case, async: true

  alias Steward.Core.Authz
  alias Steward.Core.Audit.Webhook
  alias Steward.Core.Branches.{Branch, CreateIntent}
  alias Steward.Core.Policies.Policy

  alias Steward.Core.Targets.{
    ApiKey,
    ImpactQuery,
    Principal,
    Target,
    TargetMembership,
    TargetSettings
  }

  @org "6c0f1f4e-0000-4000-8000-000000000001"
  @other_org "6c0f1f4e-0000-4000-8000-000000000002"
  @t1 "6c0f1f4e-0000-4000-8000-0000000000a1"
  @t2 "6c0f1f4e-0000-4000-8000-0000000000a2"

  # Principal ids double as the owner of the branch under test.
  @agent_p "6c0f1f4e-0000-4000-8000-0000000000b1"
  @svc_p "6c0f1f4e-0000-4000-8000-0000000000b2"
  @human_p "6c0f1f4e-0000-4000-8000-0000000000b3"
  @other_p "6c0f1f4e-0000-4000-8000-0000000000b4"

  defp key(principal, scopes, targets \\ [@t1]),
    do: %ApiKey{
      id: "key-#{principal}",
      org_id: @org,
      principal_id: principal,
      scopes: scopes,
      target_ids: targets
    }

  defp human(caps, opts \\ []) do
    memberships = for cap <- caps, do: %TargetMembership{target_id: @t1, capability: cap}

    %Principal{
      id: Keyword.get(opts, :id, @human_p),
      org_id: @org,
      org_admin: Keyword.get(opts, :org_admin, false),
      memberships: memberships
    }
  end

  defp actors do
    %{
      agent: key(@agent_p, ~w(branch:write branch:propose changeset:read)),
      reviewer: human([:reviewer]),
      policy_admin: human([:policy_admin]),
      target_admin: human([:target_admin]),
      org_admin: human([], org_admin: true)
    }
  end

  defp branch(owner \\ @agent_p),
    do: %Branch{
      id: Ecto.UUID.generate(),
      org_id: @org,
      target_id: @t1,
      principal_id: owner,
      state: :open
    }

  defp can?(actor, subject, tenant \\ @org), do: Ash.can?(subject, actor, tenant: tenant)

  # Runs `rows`, each `{label, actor, subject, expected}`, collecting every
  # mismatch so one run shows the whole picture.
  defp check(rows) do
    wrong =
      for {label, actor, subject, expected} <- rows, can?(actor, subject) != expected do
        "#{label}: expected #{expected}"
      end

    assert wrong == []
  end

  describe "create branch, write via proxy, withdraw, abandon own branch (A S ✓ · R P — · T ✓ · O —)" do
    test "create (the caller-facing step is the create intent)" do
      intent = fn principal, target ->
        {CreateIntent, :create,
         %{target_id: target, principal_id: principal, idempotency_key: "k"}}
      end

      %{agent: a, reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()

      check([
        {"A", a, intent.(@agent_p, @t1), true},
        {"S with branch:write", key(@svc_p, ["branch:write"]), intent.(@svc_p, @t1), true},
        {"R", r, intent.(@human_p, @t1), false},
        {"P", p, intent.(@human_p, @t1), false},
        {"T", t, intent.(@human_p, @t1), true},
        {"O", o, intent.(@human_p, @t1), false},
        {"A on a target outside the key", a, intent.(@agent_p, @t2), false},
        {"A creating as another principal", a, intent.(@other_p, @t1), false},
        {"S without branch:write", key(@svc_p, ["branch:propose"]), intent.(@svc_p, @t1), false}
      ])
    end

    test "withdraw is the owner's only; the abandon rule adds target:admin" do
      %{agent: a, reviewer: r, target_admin: t} = actors()
      other_agent = key(@other_p, ~w(branch:write))

      check([
        {"withdraw: owner A", a, {branch(), :withdraw}, true},
        {"withdraw: another agent", other_agent, {branch(), :withdraw}, false},
        {"withdraw: R", r, {branch(), :withdraw}, false},
        {"withdraw: T is not the owner", t, {branch(), :withdraw}, false},
        {"abandon: owner A", a, {branch(), :abandon}, true},
        {"abandon: another agent", other_agent, {branch(), :abandon}, false},
        {"abandon: T may abandon any branch", t, {branch(), :abandon}, true},
        {"abandon: R", r, {branch(), :abandon}, false},
        {"abandon: owner whose key lost branch:write", key(@agent_p, ["changeset:read"]),
         {branch(), :abandon}, false}
      ])
    end
  end

  describe "propose (A S ✓ owner only · R P T O —)" do
    test "owner with branch:propose only" do
      %{agent: a, reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()
      svc = key(@svc_p, ["branch:propose"])

      check([
        {"A owner", a, {branch(), :propose}, true},
        {"S owner", svc, {branch(@svc_p), :propose}, true},
        {"A, not the owner", a, {branch(@other_p), :propose}, false},
        {"owner without branch:propose", key(@agent_p, ["branch:write"]), {branch(), :propose},
         false},
        {"R", r, {branch(@human_p), :propose}, false},
        {"P", p, {branch(@human_p), :propose}, false},
        {"T, even as owner", t, {branch(@human_p), :propose}, false},
        {"O", o, {branch(@human_p), :propose}, false}
      ])
    end
  end

  describe "policy (S policy:write · P T ✓ · A R O —)" do
    defp new_policy(creator),
      do: {Policy, :create, %{target_id: @t1, slug: "p", created_by: creator}}

    test "save a policy: policy:write, as oneself" do
      %{agent: a, reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()

      check([
        {"S with policy:write", key(@svc_p, ["policy:write"]), new_policy(@svc_p), true},
        {"S with policy:read only", key(@svc_p, ["policy:read"]), new_policy(@svc_p), false},
        {"A", a, new_policy(@agent_p), false},
        {"R", r, new_policy(@human_p), false},
        {"P", p, new_policy(@human_p), true},
        {"T", t, new_policy(@human_p), true},
        {"O", o, new_policy(@human_p), false},
        {"P attributing the policy to someone else", p, new_policy(@other_p), false}
      ])
    end

    test "retire needs policy:admin; policy:write is not enough" do
      pol = %Policy{id: Ecto.UUID.generate(), org_id: @org, target_id: @t1, slug: "p"}
      %{reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()

      check([
        {"S with policy:admin", key(@svc_p, ["policy:admin"]), {pol, :archive}, true},
        {"S with policy:write", key(@svc_p, ["policy:write"]), {pol, :archive}, false},
        {"R", r, {pol, :archive}, false},
        {"P", p, {pol, :archive}, true},
        {"T", t, {pol, :archive}, true},
        {"O", o, {pol, :archive}, false}
      ])
    end
  end

  describe "target administration (S target:admin · T ✓ · A R P O —)" do
    test "impact queries write" do
      iq = %ImpactQuery{id: Ecto.UUID.generate(), org_id: @org, target_id: @t1}
      %{agent: a, reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()

      check([
        {"S", key(@svc_p, ["target:admin"]), {iq, :update}, true},
        {"A", a, {iq, :update}, false},
        {"R", r, {iq, :update}, false},
        {"P", p, {iq, :update}, false},
        {"T", t, {iq, :update}, true},
        {"O", o, {iq, :update}, false},
        {"S on another target", key(@svc_p, ["target:admin"], [@t2]), {iq, :update}, false}
      ])
    end

    test "settings, memberships" do
      settings = %TargetSettings{target_id: @t1, org_id: @org}

      grant = fn by ->
        {TargetMembership, :create,
         %{target_id: @t1, principal_id: @other_p, capability: :reviewer, granted_by: by}}
      end

      %{reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()
      svc = key(@svc_p, ["target:admin"])

      check([
        {"settings: S", svc, {settings, :update}, true},
        {"settings: T", t, {settings, :update}, true},
        {"settings: R", r, {settings, :update}, false},
        {"settings: P", p, {settings, :update}, false},
        {"settings: O", o, {settings, :update}, false},
        {"membership: S", svc, grant.(@svc_p), true},
        {"membership: T", t, grant.(@human_p), true},
        {"membership: R", r, grant.(@human_p), false},
        {"membership: O", o, grant.(@human_p), false},
        {"membership: T naming another grantor", t, grant.(@other_p), false}
      ])
    end

    test "register a target needs target:admin on some target; org_admin alone does not (matrix, and see E1b notes)" do
      new = {Target, :create, %{slug: "x", name: "x", kind: :postgres, credential_ref: "env://X"}}
      %{agent: a, reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()

      check([
        {"S", key(@svc_p, ["target:admin"]), new, true},
        {"A", a, new, false},
        {"R", r, new, false},
        {"P", p, new, false},
        {"T", t, new, true},
        {"O", o, new, false}
      ])
    end

    test "target:admin does not reach another org's targets" do
      iq = %ImpactQuery{id: Ecto.UUID.generate(), org_id: @org, target_id: @t1}
      refute can?(actors().target_admin, {iq, :update}, @other_org)
    end
  end

  describe "principals, API keys, webhooks (org_admin · everyone else —)" do
    test "principals and keys" do
      principal = %Principal{id: @other_p, org_id: @org}

      api_key = %ApiKey{
        id: Ecto.UUID.generate(),
        org_id: @org,
        principal_id: @other_p,
        scopes: []
      }

      %{agent: a, reviewer: r, policy_admin: p, target_admin: t, org_admin: o} = actors()
      svc = key(@svc_p, Authz.key_scopes())

      check([
        {"principal create: O", o,
         {Principal, :create, %{kind: :agent, slug: "x", display_name: "x"}}, true},
        {"principal update: O", o, {principal, :update}, true},
        {"principal update: T", t, {principal, :update}, false},
        {"principal update: S holding every key scope", svc, {principal, :update}, false},
        {"principal update: A", a, {principal, :update}, false},
        {"key mint: O", o, {ApiKey, :create, %{principal_id: @other_p, scopes: []}}, true},
        {"key mint: T", t, {ApiKey, :create, %{principal_id: @other_p, scopes: []}}, false},
        {"key revoke: O", o, {api_key, :update}, true},
        {"key revoke: R", r, {api_key, :update}, false},
        {"key revoke: P", p, {api_key, :update}, false}
      ])
    end

    test "webhooks" do
      hook = %Webhook{id: Ecto.UUID.generate(), org_id: @org}

      new = fn by ->
        {Webhook, :create, %{url: "https://example.test/h", event_types: [], created_by: by}}
      end

      %{agent: a, reviewer: r, target_admin: t, org_admin: o} = actors()

      check([
        {"create: S with webhook:admin", key(@svc_p, ["webhook:admin"]), new.(@svc_p), true},
        {"create: O", o, new.(@human_p), true},
        {"create: T", t, new.(@human_p), false},
        {"create: R", r, new.(@human_p), false},
        {"create: A", a, new.(@agent_p), false},
        {"delete: S with webhook:admin", key(@svc_p, ["webhook:admin"]), {hook, :destroy}, true},
        {"delete: T", t, {hook, :destroy}, false},
        {"create naming another creator", o, new.(@other_p), false}
      ])
    end
  end

  describe "lifecycle actions no API caller may run (doc 13 invariant 4)" do
    @internal [
      :start_merge,
      :complete_merge,
      :fail_merge,
      :reject,
      :lose_snapshot,
      :close,
      :heartbeat_touch,
      :return_to_open,
      :expire_ttl,
      :reject_blocked
    ]

    test "no user actor, however privileged, can run them" do
      b = branch(@human_p)
      everyone = actors() |> Map.values()
      svc = key(@svc_p, Authz.key_scopes())

      for action <- @internal, actor <- [svc | everyone] do
        refute can?(actor, {b, action}), "#{inspect(action)} must be system-only"
      end
    end

    test "named system roles can; other roles cannot" do
      b = branch()
      sys = fn role -> Authz.System.new(role, @org) end

      assert can?(sys.(:coordinator), {b, :start_merge})
      refute can?(sys.(:session), {b, :start_merge})
      refute can?(sys.(:jobs), {b, :start_merge})
      assert can?(sys.(:session), {b, :heartbeat_touch})
      assert can?(sys.(:jobs), {b, :close})
      refute can?(sys.(:session), {b, :close})
    end

    test "a system actor of another org is refused" do
      refute can?(Authz.System.new(:coordinator, @other_org), {branch(), :start_merge})
    end
  end

  describe "who is the actor" do
    test "a revoked key, an expired key and a disabled principal are refused everywhere" do
      past = DateTime.add(DateTime.utc_now(), -60)
      grant = {Policy, :create, %{target_id: @t1, slug: "p", created_by: @svc_p}}
      live = key(@svc_p, ["policy:write"])
      assert can?(live, grant)

      refute can?(%{live | revoked_at: DateTime.utc_now()}, grant)
      refute can?(%{live | expires_at: past}, grant)

      refute can?(
               %{human([:policy_admin]) | disabled_at: DateTime.utc_now()},
               new_policy(@human_p)
             )
    end

    test "a missing actor is refused" do
      refute can?(nil, {branch(), :propose})
    end

    test "an actor from another org is refused even with the right scope" do
      other = %ApiKey{key(@agent_p, ["branch:propose"]) | org_id: @other_org}
      refute can?(other, {branch(), :propose})
    end
  end
end
