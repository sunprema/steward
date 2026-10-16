defmodule Steward.Coordinator.Reactors.Support do
  @moduledoc false
  # Shared by the lifecycle reactors' steps.

  alias Steward.Coordinator.Plane
  alias Steward.Core.Authz.System
  alias Steward.Core.Targets.Target

  def system(org_id, role \\ :coordinator), do: System.new(role, org_id)

  @doc "The data plane serving a target: `{:ok, data_plane_id}` or `{:error, :no_data_plane}`."
  def data_plane_for(org_id, target_id) do
    case Ash.get(Target, target_id, tenant: org_id, actor: system(org_id)) do
      {:ok, %{data_plane_id: dp}} when is_binary(dp) -> {:ok, dp}
      {:ok, _} -> {:error, :no_data_plane}
      {:error, _} -> {:error, :target_not_found}
    end
  end

  @doc """
  Sends an instruction and classifies the answer for a step:
  `{:ok, result}` when the data plane accepted it, `{:error, {:rejected, code}}`
  when it answered `ok: false`, `{:error, :data_plane_unreachable}` on no answer.
  """
  def instruct(org_id, data_plane_id, instruction, opts \\ []) do
    case Plane.send_instruction(org_id, data_plane_id, instruction, opts) do
      {:ok, %{ok: true} = result} -> {:ok, result}
      {:ok, %{ok: false, error_code: code}} -> {:error, {:rejected, code}}
      {:error, :timeout} -> {:error, :data_plane_unreachable}
    end
  end

  def instruction(body), do: %Steward.Plane.V1.Instruction{body: body}
end
