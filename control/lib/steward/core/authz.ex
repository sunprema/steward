defmodule Steward.Core.Authz do
  @moduledoc """
  Capabilities and scopes (doc 15 §3, doc 10 §3.1, doc 07 §8).

  Humans hold membership *capabilities* (`reviewer`, `policy_admin`,
  `target_admin`) and `org_admin` on the principal; API keys hold *scopes* in
  `resource:verb` form. Every check in the control plane resolves to the scope
  vocabulary, so `allowed?/3` answers both (doc 15 §3.1). Resources never call
  it directly: they declare `Ash.Policy` policies built from the checks under
  `Steward.Core.Authz.Checks`, and controllers and LiveViews pass `actor:` and
  `tenant:` only (doc 07 §8).

  An actor is a `Steward.Core.Targets.ApiKey`, a `Steward.Core.Targets.Principal`
  with `:memberships` loaded, or a `Steward.Core.Authz.System`. The
  `Steward.Core.Authz.Actor` protocol is what this boundary knows about them,
  which keeps `Authz` independent of `Targets` (whose resources use these checks).
  """
  use Boundary,
    deps: [],
    exports: [
      Actor,
      Subject,
      System,
      Checks.Scope,
      Checks.ScopedRead,
      Checks.SystemActor,
      Checks.OrgAdmin,
      Checks.ActsAs
    ]

  alias Steward.Core.Authz.Actor

  # Doc 10 §3.1: the API-key scope vocabulary.
  @key_scopes ~w(
    branch:write branch:propose changeset:read review:read review:decide
    policy:read policy:write policy:admin target:admin merge:revert
    audit:read webhook:admin
  )

  # Doc 15 §3.2 / doc 06 §8: an agent key must not carry these in M0.
  @agent_forbidden_scopes ~w(review:decide policy:write policy:admin merge:revert target:admin)

  # Scope pseudo-targets that apply to the org, not to one target.
  @org_scope "org:admin"

  # Doc 10 §3.1: membership capability → scopes. `target_admin` is
  # `target:admin` + everything above (reviewer and policy_admin) and, per the
  # doc 15 §3.2 matrix, branch creation/abandonment, revert and audit reads.
  @reviewer ~w(review:read review:decide changeset:read)
  @policy_admin ~w(policy:read policy:write policy:admin changeset:read)
  @target_admin Enum.uniq(
                  ~w(target:admin merge:revert audit:read branch:write) ++
                    @reviewer ++ @policy_admin
                )

  # Org-level scopes `org_admin` carries: principals and keys, webhooks, audit.
  @org_admin [@org_scope, "webhook:admin", "audit:read"]

  @doc "The `resource:verb` scopes an API key may carry (doc 10 §3.1)."
  def key_scopes, do: @key_scopes

  @doc "Scopes an `agent` principal's key must never carry in M0 (doc 15 §3.2)."
  def agent_forbidden_scopes, do: @agent_forbidden_scopes

  @doc "The org-level scope held by `org_admin` principals."
  def org_scope, do: @org_scope

  @doc "Scopes implied by a membership capability (doc 10 §3.1)."
  def scopes_for_capability(:reviewer), do: @reviewer
  def scopes_for_capability(:policy_admin), do: @policy_admin
  def scopes_for_capability(:target_admin), do: @target_admin
  def scopes_for_capability(_), do: []

  @doc "Scopes held by an `org_admin` principal at org level."
  def org_admin_scopes, do: @org_admin

  @doc """
  Scopes implied by other scopes on an API key. Only `merge:revert` is implied
  by `target:admin` (doc 10 §3.1: "for service principals, implied by
  `target:admin`"); a key is otherwise exactly what it was minted with.
  """
  def expand_key_scopes(scopes) do
    scopes = MapSet.new(scopes)
    if "target:admin" in scopes, do: MapSet.put(scopes, "merge:revert"), else: scopes
  end

  @doc """
  Validates a scope list for a key owned by a principal of `kind`
  (doc 15 §3.2: "enforced at key creation"). Returns `:ok` or
  `{:error, reason}` where `reason` is `{:unknown_scopes, [..]}` or
  `{:forbidden_for_agent, [..]}`.
  """
  def validate_key_scopes(kind, scopes) do
    unknown = Enum.reject(scopes, &(&1 in @key_scopes))

    forbidden =
      if kind in [:agent, "agent"],
        do: Enum.filter(scopes, &(&1 in @agent_forbidden_scopes)),
        else: []

    cond do
      unknown != [] -> {:error, {:unknown_scopes, unknown}}
      forbidden != [] -> {:error, {:forbidden_for_agent, forbidden}}
      true -> :ok
    end
  end

  @doc """
  Does `actor` hold `scope` on `target_id`?

  `target_id` may be a target's id, `:any` (the scope on at least one target,
  used where no target exists yet, such as registering one), or `nil` for
  org-level scopes.
  """
  def allowed?(actor, scope, target_id \\ nil) do
    scope in Actor.scopes(actor, target_id)
  end

  @doc "The principal id an actor acts as (event attribution, ownership checks)."
  def principal_id(actor), do: Actor.principal_id(actor)
end
