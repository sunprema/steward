defmodule Steward.Core.Targets.ApiKey.ValidateScopes do
  @moduledoc """
  Enforces the doc 10 §3.1 / doc 15 §3.2 key rules when a key is minted or its
  scopes change: only known scopes, and an `agent` principal's key never
  carries `review:decide`, `policy:write`, `policy:admin`, `merge:revert`, or
  `target:admin`. The failure mode the product exists to prevent is an agent
  editing the gate in front of it (doc 15 §3.3), so this is checked here and
  not left to whoever calls the action.
  """
  use Ash.Resource.Change

  alias Steward.Core.Authz

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action_type == :create or Ash.Changeset.changing_attribute?(changeset, :scopes) do
      Ash.Changeset.before_action(changeset, &validate/1)
    else
      changeset
    end
  end

  defp validate(changeset) do
    scopes = Ash.Changeset.get_attribute(changeset, :scopes) || []
    principal_id = Ash.Changeset.get_attribute(changeset, :principal_id)

    with {:ok, principal} <-
           Ash.get(Steward.Core.Targets.Principal, principal_id,
             tenant: changeset.tenant,
             authorize?: false
           ),
         :ok <- Authz.validate_key_scopes(principal.kind, scopes) do
      changeset
    else
      {:error, {:unknown_scopes, scopes}} ->
        Ash.Changeset.add_error(changeset,
          field: :scopes,
          message: "unknown scopes: #{Enum.join(scopes, ", ")}"
        )

      {:error, {:forbidden_for_agent, scopes}} ->
        Ash.Changeset.add_error(changeset,
          field: :scopes,
          message: "an agent key must not carry #{Enum.join(scopes, ", ")}"
        )

      {:error, _not_found} ->
        Ash.Changeset.add_error(changeset, field: :principal_id, message: "principal not found")
    end
  end
end
