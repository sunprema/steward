defmodule Steward.Core.Targets do
  @moduledoc """
  The `Steward.Targets` domain (doc 07 §4): targets, settings, memberships,
  impact queries — plus identity (`Org`, `Principal`, `ApiKey`, `DataPlane`),
  which doc 07 §4's table does not explicitly place in any of the five
  domains; decided here as the closest fit (doc 18 §5).
  """
  use Boundary,
    deps: [Steward.Core.Types, Steward.Core.Authz, Steward.Core.Audit],
    exports: [
      Org,
      Principal,
      ApiKey,
      DataPlane,
      Target,
      TargetSettings,
      TargetMembership,
      Adapter,
      ImpactQuery
    ]

  use Ash.Domain

  resources do
    resource Steward.Core.Targets.Org
    resource Steward.Core.Targets.Principal
    resource Steward.Core.Targets.ApiKey
    resource Steward.Core.Targets.DataPlane
    resource Steward.Core.Targets.Target
    resource Steward.Core.Targets.TargetSettings
    resource Steward.Core.Targets.TargetMembership
    resource Steward.Core.Targets.Adapter
    resource Steward.Core.Targets.ImpactQuery
  end
end
