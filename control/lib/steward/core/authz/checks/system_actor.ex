defmodule Steward.Core.Authz.Checks.SystemActor do
  @moduledoc """
  Passes for a `Steward.Core.Authz.System` actor whose role is one of
  `roles:` (or any role, with `roles: :any`). Lifecycle actions name the roles
  that may run them, so the session host cannot, say, approve a changeset and
  an Oban job cannot open a branch.
  """
  use Ash.Policy.SimpleCheck

  alias Steward.Core.Authz.Actor
  alias Steward.Core.Authz.Subject

  @impl true
  def describe(opts), do: "actor is a system actor with role in #{inspect(opts[:roles])}"

  @impl true
  def match?(actor, %{subject: subject}, opts) do
    role = Actor.system_role(actor)

    role != nil and Subject.same_org?(actor, Subject.tenant(subject), opts) and
      (opts[:roles] == :any or role in List.wrap(opts[:roles]))
  end
end
