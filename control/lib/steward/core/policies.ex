defmodule Steward.Core.Policies do
  @moduledoc "The `Steward.Policies` domain (doc 07 §4, doc 06): policies, versions, assertions, tests."
  use Boundary,
    deps: [Steward.Core.Types, Steward.Core.Authz, Steward.Core.Targets, Steward.Core.Audit],
    exports: [Policy, PolicyVersion, PolicyAssertion, PolicyTest]

  use Ash.Domain

  resources do
    resource Steward.Core.Policies.Policy
    resource Steward.Core.Policies.PolicyVersion
    resource Steward.Core.Policies.PolicyAssertion
    resource Steward.Core.Policies.PolicyTest
  end
end
