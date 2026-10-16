defmodule Steward.Core.Authz.Checks.ScopedRead do
  @moduledoc """
  A read check that turns a scope into a row filter: the actor sees only rows
  on targets where they hold `scope` (doc 15 §3.2 "scoped to the targets of
  the key or the memberships"). Org isolation is separate and comes from
  multitenancy; this check also refuses an actor from a different org.

  Options:

    * `:scope` — a scope, or `:any` for "any scope on the target" (plain
      read access to a target). Omit it with `:or_principal` for an
      ownership-only rule.
    * `:target` — how the row reaches its target: `:target_id` (default),
      `:id` (the resource is a `Target`), `{:via, [:relationship, ...]}` for a
      to-one path ending at a `target_id` (e.g. a `Verdict` via its
      `:changeset`), `:org` (an org-level scope: all rows or none), or
      `:own_org` (the resource is `Org`: the actor's own org's row).
    * `:or_principal` — also pass rows whose attribute of this name is the
      actor's own principal id (ownership: "get branch: `changeset:read` or
      owner").
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias Steward.Core.Authz
  alias Steward.Core.Authz.Actor
  alias Steward.Core.Authz.Subject

  @impl true
  def describe(opts),
    do: "actor holds #{opts[:scope]}, as a filter on #{inspect(opts[:target] || :target_id)}"

  @impl true
  def filter(actor, authorizer, opts) do
    scope = Keyword.get(opts, :scope)
    target = Keyword.get(opts, :target, :target_id)
    tenant = authorizer.subject.tenant

    if Subject.same_org?(actor, tenant, tenantless: Keyword.get(opts, :tenantless, false)) do
      by_scope = by_scope(actor, scope, target)

      case {by_scope, owner(actor, opts[:or_principal])} do
        {by_scope, nil} -> by_scope
        {false, owned} -> owned
        {by_scope, owned} -> Ash.Expr.expr(^by_scope or ^owned)
      end
    else
      false
    end
  end

  defp by_scope(actor, _scope, :own_org), do: Ash.Expr.expr(id == ^Actor.org_id(actor))

  defp by_scope(_actor, nil, _target), do: false

  defp by_scope(actor, scope, :org),
    do: Authz.allowed?(actor, scope, :any) and Actor.org_id(actor) != nil

  defp by_scope(actor, scope, target) do
    case Actor.target_ids_with(actor, scope) do
      [] -> false
      ids -> Ash.Expr.expr(^target_ref(target) in ^ids)
    end
  end

  defp target_ref(:target_id), do: Ash.Expr.ref(:target_id)
  defp target_ref(:id), do: Ash.Expr.ref(:id)
  defp target_ref({:via, path}), do: Ash.Expr.ref(path, :target_id)

  defp owner(_actor, nil), do: nil

  defp owner(actor, attribute) do
    case Authz.principal_id(actor) do
      nil -> false
      id -> Ash.Expr.expr(^Ash.Expr.ref(attribute) == ^id)
    end
  end
end
