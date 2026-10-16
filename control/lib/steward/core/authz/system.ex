defmodule Steward.Core.Authz.System do
  @moduledoc """
  The actor for code that is part of the control plane rather than a caller:
  the branch coordinator and reactors (`:coordinator`), the `Session` host
  speaking for a data plane (`:session`), Oban jobs and sweeps (`:jobs`), and
  the REST layer's own bookkeeping such as the idempotency store (`:api`).

  Lifecycle actions that no API caller may invoke (every transition except
  propose, withdraw and abandon) are authorised to named system roles only, so
  a request-handling bug cannot reach them with a user's actor (doc 13
  invariant 4: the data plane never advances branch state; only the control
  plane does). Nothing in this module is a bypass: a `System` actor still
  passes through the same policies, and a role not named by an action is
  refused.
  """
  @enforce_keys [:role, :org_id]
  defstruct [:role, :org_id]

  @type t :: %__MODULE__{role: :coordinator | :session | :jobs | :api, org_id: String.t() | :all}
  @roles [:coordinator, :session, :jobs, :api]

  @doc "Builds a system actor for `role` acting within `org_id`."
  def new(role, org_id) when role in @roles, do: %__MODULE__{role: role, org_id: org_id}

  @doc """
  The actor of a scheduled job that runs for every org (`Steward.Jobs`, AshOban
  triggers): role `:jobs`, org `:all`. Only the jobs role may span orgs, and it
  still needs a tenant on every query it makes: the scheduler lists the tenants
  and runs each trigger once per org (doc 15 §4.1 point 1, doc 07 §8).
  """
  def jobs, do: %__MODULE__{role: :jobs, org_id: :all}
  def roles, do: @roles

  defimpl Steward.Core.Authz.Actor do
    def org_id(%{org_id: org_id}), do: org_id
    def principal_id(_), do: nil
    def scopes(_, _), do: MapSet.new()
    def target_ids_with(_, _), do: []
    def system_role(%{role: role}), do: role
  end
end
