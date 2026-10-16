defmodule Steward.Coordinator.Reactors.Withdraw do
  @moduledoc """
  Withdraw a proposed branch (doc 13 §2.1, §6.3): `proposed → open`, the owner
  taking it back. The checkpoint is the transition (the live changeset superseded
  with `withdrawn`, the queue entry removed, in one transaction); then, best effort,
  the data plane is told to unfreeze. If that is lost the heartbeat reply of `open`
  unfreezes it (doc 13 §6.8).
  """
  use Reactor

  alias Steward.Coordinator.Reactors.Withdraw.Steps

  input :org_id
  input :actor
  input :branch_id

  step :withdraw, Steps.Withdraw do
    argument :org_id, input(:org_id)
    argument :actor, input(:actor)
    argument :branch_id, input(:branch_id)
  end

  step :unfreeze, Steps.Unfreeze do
    argument :org_id, input(:org_id)
    argument :branch, result(:withdraw)
  end

  return :withdraw

  defmodule Steps do
    @moduledoc false

    defmodule Withdraw do
      @moduledoc false
      use Reactor.Step

      @impl true
      def run(%{org_id: org_id, actor: actor, branch_id: branch_id}, _context, _opts) do
        Steward.Coordinator.Branch.transition(org_id, branch_id, :withdraw, %{}, actor: actor)
      end

      @impl true
      def compensate(_reason, _arguments, _context, _opts), do: :ok
    end

    defmodule Unfreeze do
      @moduledoc false
      use Steward.Coordinator.Reactors.BestEffort

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Plane.V1

      def attempt(%{org_id: org_id, branch: branch}, _context, _opts) do
        unfreeze = %V1.FreezeWrites{
          branch_id: branch.id,
          overlay_id: branch.overlay_id,
          unfreeze: true
        }

        with {:ok, dp} <- Support.data_plane_for(org_id, branch.target_id),
             {:ok, _} <-
               Support.instruct(org_id, dp, Support.instruction({:freeze_writes, unfreeze}),
                 deadline_ms: 2_000
               ) do
          :ok
        end
      end
    end
  end
end
