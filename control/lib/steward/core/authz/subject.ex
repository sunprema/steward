defmodule Steward.Core.Authz.Subject do
  @moduledoc """
  Reads what a check or resolver needs off the subject of an authorisation
  (a changeset or a record) and compares tenants.
  """

  # Defence in depth for tenancy (doc 15 §4.1): Ash filters every query by the
  # tenant, but an actor from org A that is handed org B's tenant must not pass
  # any check. A nil tenant never matches except on `Org` itself (`tenantless`).

  alias Steward.Core.Authz.Actor

  def same_org?(actor, tenant, opts \\ []) do
    actor_org = Actor.org_id(actor)

    cond do
      is_nil(actor_org) -> false
      is_nil(tenant) -> Keyword.get(opts, :tenantless, false)
      true -> to_string(tenant) == to_string(actor_org)
    end
  end

  # The attribute a check reads off a changeset or record: on update the value
  # already stored, never the incoming one, so a change cannot widen its own
  # authorisation by rewriting `target_id`.
  def attr(%Ash.Changeset{action_type: :create} = cs, name),
    do: Ash.Changeset.get_attribute(cs, name)

  def attr(%Ash.Changeset{data: data}, name), do: Map.get(data, name)
  def attr(%{__struct__: _} = record, name), do: Map.get(record, name)
  def attr(_, _), do: nil

  def tenant(%{tenant: tenant}), do: tenant
  def tenant(%{org_id: org_id}), do: org_id
  def tenant(_), do: nil

  @doc """
  The `target_id` of a parent resource reached through the foreign key `fk`
  on the subject (a `PolicyVersion` through `:policy_id`, a `Review` through
  `:changeset_id`). Authorisation reads the target from the parent instead of
  trusting a `target_id` in the request. Nil if the parent is absent or in
  another org, which makes the check fail closed.
  """
  def target_via(subject, fk, parent_resource) do
    with id when not is_nil(id) <- attr(subject, fk),
         {:ok, parent} <- Ash.get(parent_resource, id, tenant: tenant(subject), authorize?: false) do
      parent.target_id
    else
      _ -> nil
    end
  end
end
