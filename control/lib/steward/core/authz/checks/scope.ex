defmodule Steward.Core.Authz.Checks.Scope do
  @moduledoc """
  Passes when the actor holds `scope` on the target the action touches
  (doc 15 §3.2). For a create, that is the target in the changeset; for an
  update or destroy, the target on the stored record.

  Options:

    * `:scope` (required) — a doc 10 §3.1 scope, e.g. `"review:decide"`.
    * `:target` — where the target id comes from: `:target_id` (default, the
      resource's own attribute), `:id` (the resource is a `Target`),
      `{Module, :function}` (called with the changeset, for resources that
      reach their target through a parent), `:any` (the scope on at least one
      target, for acts like registering a target), or `:org` (an org-level
      scope; use with `"org:admin"`, `"webhook:admin"`).
  """
  use Ash.Policy.SimpleCheck

  alias Steward.Core.Authz
  alias Steward.Core.Authz.Subject

  @impl true
  def describe(opts), do: "actor holds #{opts[:scope]} on the #{describe_target(opts[:target])}"

  @impl true
  def match?(actor, %{subject: subject}, opts) do
    scope = Keyword.fetch!(opts, :scope)

    Subject.same_org?(actor, Subject.tenant(subject)) and
      case target(subject, Keyword.get(opts, :target, :target_id)) do
        {:ok, target_id} -> Authz.allowed?(actor, scope, target_id)
        :error -> false
      end
  end

  defp target(_subject, :any), do: {:ok, :any}
  defp target(_subject, :org), do: {:ok, nil}
  defp target(subject, :id), do: present(Subject.attr(subject, :id))
  defp target(subject, :target_id), do: present(Subject.attr(subject, :target_id))
  defp target(subject, {mod, fun}), do: present(apply(mod, fun, [subject]))

  # No target id means nothing to authorise against: fail closed.
  defp present(nil), do: :error
  defp present(id), do: {:ok, id}

  defp describe_target({mod, fun}), do: "target resolved by #{inspect(mod)}.#{fun}"
  defp describe_target(other), do: "target (#{inspect(other || :target_id)})"
end
