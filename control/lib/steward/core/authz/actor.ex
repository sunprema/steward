defprotocol Steward.Core.Authz.Actor do
  @moduledoc """
  What the authorization checks need to know about an actor (doc 15 §3.1).
  Implemented for `ApiKey` and `Principal` in `Steward.Core.Targets`, and for
  `Steward.Core.Authz.System` here. Anything else (including `nil`) holds no
  scopes and acts as no principal, so it is denied everywhere.
  """
  @fallback_to_any true

  @doc "The org the actor belongs to, or nil."
  def org_id(actor)

  @doc "The principal the actor acts as, or nil."
  def principal_id(actor)

  @doc """
  The scopes the actor holds on `target_id` (an id, `:any`, or nil for
  org-level scopes). Revoked, expired and disabled actors hold none.
  """
  def scopes(actor, target_id)

  @doc """
  The ids of the targets on which the actor holds `scope`; used to turn a
  scope into a read filter. Empty for system actors and unknown actors.
  """
  def target_ids_with(actor, scope)

  @doc "`:coordinator | :session | :jobs | :api` for system actors, else nil."
  def system_role(actor)
end

defimpl Steward.Core.Authz.Actor, for: Any do
  def org_id(_), do: nil
  def principal_id(_), do: nil
  def scopes(_, _), do: MapSet.new()
  def target_ids_with(_, _), do: []
  def system_role(_), do: nil
end
