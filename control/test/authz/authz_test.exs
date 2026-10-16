defmodule Steward.Authz.AuthzTest do
  @moduledoc "Scope vocabulary, expansion, and actor resolution (doc 15 §3.1, doc 10 §3.1). No database."
  use ExUnit.Case, async: true

  alias Steward.Core.Authz
  alias Steward.Core.Authz.Actor
  alias Steward.Core.Targets.{ApiKey, Principal, TargetMembership}

  @org "6c0f1f4e-0000-4000-8000-000000000001"
  @t1 "6c0f1f4e-0000-4000-8000-0000000000a1"
  @t2 "6c0f1f4e-0000-4000-8000-0000000000a2"

  defp key(attrs) do
    struct!(
      ApiKey,
      Keyword.merge([org_id: @org, principal_id: "p1", scopes: [], target_ids: [@t1]], attrs)
    )
  end

  defp human(caps, attrs \\ []) do
    memberships =
      for {target, cap} <- caps, do: %TargetMembership{target_id: target, capability: cap}

    struct!(Principal, Keyword.merge([id: "h1", org_id: @org, memberships: memberships], attrs))
  end

  describe "membership capabilities resolve to scopes (doc 10 §3.1)" do
    test "reviewer = review:read + review:decide + changeset:read" do
      assert MapSet.new(Authz.scopes_for_capability(:reviewer)) ==
               MapSet.new(~w(review:read review:decide changeset:read))
    end

    test "policy_admin carries policy:* and no review or target rights" do
      scopes = MapSet.new(Authz.scopes_for_capability(:policy_admin))
      assert MapSet.subset?(MapSet.new(~w(policy:read policy:write policy:admin)), scopes)
      refute "review:decide" in scopes
      refute "target:admin" in scopes
    end

    test "target_admin is target:admin plus everything reviewer and policy_admin hold" do
      scopes = MapSet.new(Authz.scopes_for_capability(:target_admin))
      assert "target:admin" in scopes

      assert MapSet.subset?(MapSet.new(Authz.scopes_for_capability(:reviewer)), scopes)
      assert MapSet.subset?(MapSet.new(Authz.scopes_for_capability(:policy_admin)), scopes)
    end

    test "no membership capability lets a human propose (doc 15 §3.2: propose is agents and services)" do
      for cap <- [:reviewer, :policy_admin, :target_admin],
          do: refute("branch:propose" in Authz.scopes_for_capability(cap))
    end
  end

  describe "humans" do
    test "memberships are per target" do
      h = human([{@t1, :reviewer}])
      assert Authz.allowed?(h, "review:decide", @t1)
      refute Authz.allowed?(h, "review:decide", @t2)
      assert Actor.target_ids_with(h, "review:decide") == [@t1]
    end

    test "memberships that are not loaded grant nothing" do
      h =
        struct!(Principal,
          id: "h1",
          org_id: @org,
          memberships: %Ash.NotLoaded{field: :memberships, type: :relationship}
        )

      refute Authz.allowed?(h, "review:decide", @t1)
      assert Actor.target_ids_with(h, :any) == []
    end

    test "org_admin holds org-level scopes only, no target scope" do
      h = human([], org_admin: true)
      assert Authz.allowed?(h, Authz.org_scope())
      assert Authz.allowed?(h, "webhook:admin")
      assert Authz.allowed?(h, "audit:read")
      refute Authz.allowed?(h, "target:admin", @t1)
      refute Authz.allowed?(h, "review:decide", @t1)
    end

    test "a disabled principal holds nothing" do
      h = human([{@t1, :target_admin}], org_admin: true, disabled_at: DateTime.utc_now())
      assert Actor.scopes(h, @t1) == MapSet.new()
      assert Actor.target_ids_with(h, :any) == []
    end
  end

  describe "api keys" do
    test "scopes apply to the key's targets only" do
      k = key(scopes: ["branch:write"])
      assert Authz.allowed?(k, "branch:write", @t1)
      refute Authz.allowed?(k, "branch:write", @t2)
      assert Authz.allowed?(k, "branch:write", :any)
    end

    test "target:admin implies merge:revert and nothing else (doc 10 §3.1)" do
      k = key(scopes: ["target:admin"])
      assert Authz.allowed?(k, "merge:revert", @t1)
      refute Authz.allowed?(k, "review:decide", @t1)
      refute Authz.allowed?(k, "changeset:read", @t1)
    end

    test "org:admin is not a key scope even if a row carries it" do
      k = key(scopes: ["org:admin", "bogus:scope"])
      refute Authz.allowed?(k, "org:admin")
      refute Authz.allowed?(k, "bogus:scope", @t1)
    end

    test "revoked and expired keys hold nothing" do
      now = DateTime.utc_now()
      assert Actor.scopes(key(scopes: ["branch:write"], revoked_at: now), @t1) == MapSet.new()

      assert Actor.scopes(key(scopes: ["branch:write"], expires_at: DateTime.add(now, -1)), @t1) ==
               MapSet.new()

      assert Authz.allowed?(
               key(scopes: ["branch:write"], expires_at: DateTime.add(now, 60)),
               "branch:write",
               @t1
             )
    end
  end

  test "unknown actors hold nothing" do
    assert Actor.scopes(nil, @t1) == MapSet.new()
    assert Actor.scopes(%{scopes: ["target:admin"]}, @t1) == MapSet.new()
    assert Authz.principal_id(nil) == nil
  end

  describe "validate_key_scopes/2 (doc 15 §3.2: enforced at key creation)" do
    test "service and human keys may carry any known scope" do
      assert :ok = Authz.validate_key_scopes(:service, Authz.key_scopes())
    end

    test "agent keys must not carry the gate-editing scopes" do
      for scope <- ~w(review:decide policy:write policy:admin merge:revert target:admin) do
        assert {:error, {:forbidden_for_agent, [^scope]}} =
                 Authz.validate_key_scopes(:agent, [scope])
      end

      assert :ok =
               Authz.validate_key_scopes(:agent, ~w(branch:write branch:propose changeset:read))
    end

    test "unknown scopes are refused" do
      assert {:error, {:unknown_scopes, ["policy:*"]}} =
               Authz.validate_key_scopes(:service, ["policy:*"])
    end
  end
end
