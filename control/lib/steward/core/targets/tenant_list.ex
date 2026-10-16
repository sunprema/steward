defmodule Steward.Core.Targets.TenantList do
  @moduledoc """
  The orgs a scheduled trigger runs for: AshOban asks for the tenants and runs
  each trigger once per org with that org as the tenant (doc 07 §8: `skip_org_check`
  only in system scans, reviewed). Orgs are listed with authorisation off, since
  there is no org yet to scope an actor to; everything the trigger then reads or
  writes carries the tenant and is authorised as `Steward.Core.Authz.System.jobs/0`.
  Archived orgs are skipped.
  """
  @behaviour AshOban.ListTenants

  require Ash.Query

  alias Steward.Core.Targets.Org

  @impl true
  def list_tenants(_opts) do
    Org
    |> Ash.Query.filter(is_nil(archived_at))
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end
end
