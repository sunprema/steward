defmodule Steward.PolicyCoverageTest do
  @moduledoc """
  Doc 07 §10 / §8: every resource of every domain carries the
  `Ash.Policy.Authorizer`, and every action of every resource is matched by at
  least one policy. A new action with no policy is refused by Ash at runtime;
  this test makes it a CI failure instead, so the author must decide who may
  call it (doc 15 §3.2) rather than discover it in production.
  """
  use ExUnit.Case, async: true

  @domains [
    Steward.Core.Targets,
    Steward.Core.Branches,
    Steward.Core.Policies,
    Steward.Core.Reviews,
    Steward.Core.Audit
  ]

  defp resources, do: Enum.flat_map(@domains, &Ash.Domain.Info.resources/1)

  # Policy conditions are normalised by Ash to `{Check module, opts}`. This test
  # understands exactly two (`action/1` and `action_type/1`); any other
  # condition fails the test rather than being assumed to cover an action.
  defp applies?(%{condition: condition}, action) do
    Enum.all?(condition, fn
      {Ash.Policy.Check.Action, opts} -> action.name in List.wrap(opts[:action])
      {Ash.Policy.Check.ActionType, opts} -> action.type in List.wrap(opts[:type])
      other -> flunk("policy condition #{inspect(other)} is not understood by the coverage test")
    end)
  end

  test "the domains hold every resource (guards the test itself)" do
    assert length(resources()) >= 30
  end

  test "every resource has the policy authorizer" do
    missing =
      for resource <- resources(),
          Ash.Policy.Authorizer not in Ash.Resource.Info.authorizers(resource),
          do: resource

    assert missing == []
  end

  test "every action of every resource has at least one policy" do
    uncovered =
      for resource <- resources(),
          policies = Ash.Policy.Info.policies(resource),
          action <- Ash.Resource.Info.actions(resource),
          not Enum.any?(policies, &applies?(&1, action)),
          do: {resource, action.name}

    assert uncovered == []
  end

  test "no policy authorises unconditionally" do
    blanket =
      for resource <- resources(),
          policy <- Ash.Policy.Info.policies(resource),
          %{type: :authorize_if, check_module: Ash.Policy.Check.Static, check_opts: opts} <-
            policy.policies,
          opts[:result] == true,
          do: resource

    assert blanket == []
  end
end
