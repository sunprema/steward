defimpl Steward.Core.Authz.Actor, for: Steward.Core.Targets.ApiKey do
  alias Steward.Core.Authz

  def org_id(key), do: key.org_id
  # A revoked or expired key acts as no one: ownership rules must not honour it.
  def principal_id(key), do: if(usable?(key), do: key.principal_id)

  def scopes(key, target_id) do
    if usable?(key) and on_target?(key, target_id), do: held(key), else: MapSet.new()
  end

  def target_ids_with(key, :any) do
    if usable?(key) and MapSet.size(held(key)) > 0, do: key.target_ids, else: []
  end

  def target_ids_with(key, scope) do
    if usable?(key) and scope in held(key), do: key.target_ids, else: []
  end

  def system_role(_), do: nil

  # Only doc 10 scopes count, so a key row carrying `org:admin` (or garbage)
  # gains nothing.
  defp held(key),
    do:
      key.scopes
      |> Authz.expand_key_scopes()
      |> Enum.filter(&(&1 in Authz.key_scopes()))
      |> MapSet.new()

  # Org-level scopes and "any target" have no target to match against.
  defp on_target?(_key, nil), do: true
  defp on_target?(_key, :any), do: true

  defp on_target?(key, target_id),
    do: to_string(target_id) in Enum.map(key.target_ids, &to_string/1)

  defp usable?(key) do
    now = DateTime.utc_now()

    is_nil(key.revoked_at) and
      (is_nil(key.expires_at) or DateTime.compare(key.expires_at, now) == :gt)
  end
end

defimpl Steward.Core.Authz.Actor, for: Steward.Core.Targets.Principal do
  alias Steward.Core.Authz

  def org_id(principal), do: principal.org_id
  def principal_id(%{disabled_at: disabled_at}) when not is_nil(disabled_at), do: nil
  def principal_id(principal), do: principal.id

  def scopes(%{disabled_at: disabled_at}, _) when not is_nil(disabled_at), do: MapSet.new()

  def scopes(principal, target_id) do
    org = if principal.org_admin, do: Authz.org_admin_scopes(), else: []

    member =
      principal
      |> memberships()
      |> Enum.filter(&matches?(&1, target_id))
      |> Enum.flat_map(&Authz.scopes_for_capability(&1.capability))

    MapSet.new(org ++ member)
  end

  def target_ids_with(%{disabled_at: disabled_at}, _) when not is_nil(disabled_at), do: []

  def target_ids_with(principal, :any) do
    principal |> memberships() |> Enum.map(& &1.target_id) |> Enum.uniq()
  end

  def target_ids_with(principal, scope) do
    principal
    |> memberships()
    |> Enum.filter(&(scope in Authz.scopes_for_capability(&1.capability)))
    |> Enum.map(& &1.target_id)
    |> Enum.uniq()
  end

  def system_role(_), do: nil

  # Not loaded (or not a list) grants nothing: fail closed.
  defp memberships(%{memberships: memberships}) when is_list(memberships), do: memberships
  defp memberships(_), do: []

  defp matches?(_membership, nil), do: false
  defp matches?(_membership, :any), do: true

  defp matches?(membership, target_id),
    do: to_string(membership.target_id) == to_string(target_id)
end
