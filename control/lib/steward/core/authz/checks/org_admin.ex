defmodule Steward.Core.Authz.Checks.OrgAdmin do
  @moduledoc """
  Passes for a human principal with `org_admin` set (doc 15 §3.2: principals,
  API keys, webhooks). API keys never hold `org:admin` (it is not in the doc 10
  scope list), so a key cannot pass this check.
  """
  use Ash.Policy.SimpleCheck

  alias Steward.Core.Authz
  alias Steward.Core.Authz.Subject

  @impl true
  def describe(_opts), do: "actor is an org_admin"

  @impl true
  def match?(actor, %{subject: subject}, opts) do
    Subject.same_org?(actor, Subject.tenant(subject), opts) and
      Authz.allowed?(actor, Authz.org_scope(), nil)
  end
end
