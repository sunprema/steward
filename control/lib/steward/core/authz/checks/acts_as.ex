defmodule Steward.Core.Authz.Checks.ActsAs do
  @moduledoc """
  Passes when the actor's principal is the principal named by the action.

  Options (one of):

    * `:attribute` — the attribute holding a principal id. On a create it is
      the value in the changeset (so an actor cannot create a branch or a
      review *as someone else*); on an update, the stored value (so ownership
      is whoever owned it before the action).
    * `:resolve` — `{Module, :function}` called with the changeset and
      returning a principal id, for ownership held by a parent (a `Review`'s
      branch owner). Use with `forbid_if` for self-approval (doc 15 §3.3).
  """
  use Ash.Policy.SimpleCheck

  alias Steward.Core.Authz
  alias Steward.Core.Authz.Subject

  @impl true
  def describe(opts),
    do: "actor is the principal in #{inspect(opts[:attribute] || opts[:resolve])}"

  @impl true
  def match?(actor, %{subject: subject}, opts) do
    with true <- Subject.same_org?(actor, Subject.tenant(subject)),
         actor_id when not is_nil(actor_id) <- Authz.principal_id(actor),
         owner_id when not is_nil(owner_id) <- owner(subject, opts) do
      to_string(actor_id) == to_string(owner_id)
    else
      _ -> false
    end
  end

  defp owner(subject, opts) do
    case opts[:resolve] do
      {mod, fun} -> apply(mod, fun, [subject])
      nil -> Subject.attr(subject, Keyword.fetch!(opts, :attribute))
    end
  end
end
