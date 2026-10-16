defmodule Steward.Coordinator.Reactors.Abandon do
  @moduledoc """
  Abandon a branch (doc 13 §6.7, doc 07 §5.2): the principal giving up, a target
  admin, or the TTL job. The checkpoint is the transition itself, one transaction:
  the branch to `abandoned`, its changeset superseded, its queue entry removed.
  There is nothing before it, so nothing to undo.

    1. **`abandon`**: `Branch.abandon`, as the caller, so ownership and
       `target:admin` are checked there. A `merging` branch is refused with
       `{:error, :merge_in_progress}` (doc 13 §6.7).
    2. After it, best effort: tell the data plane to stop routing (a
       `RoutingUpsert` with state `abandoned`). If that is lost, every write is
       refused anyway once the heartbeat answers `abandoned` (§6.7 f3), and the
       overlay is kept for the retention window so the principal can inspect it.
  """
  use Reactor

  alias Steward.Coordinator.Reactors.Abandon.Steps

  input :org_id
  input :actor
  input :branch_id
  input :reason
  input :terminal_by_job

  step :abandon, Steps.Abandon do
    argument :org_id, input(:org_id)
    argument :actor, input(:actor)
    argument :branch_id, input(:branch_id)
    argument :reason, input(:reason)
    argument :terminal_by_job, input(:terminal_by_job)
  end

  step :routing_remove, Steps.RoutingRemove do
    argument :org_id, input(:org_id)
    argument :branch, result(:abandon)
  end

  return :abandon

  defmodule Steps do
    @moduledoc false

    defmodule Abandon do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.Branch, as: BranchProcess
      alias Steward.Core.Authz

      # The checkpoint, and the first step: no `undo/4`.
      @impl true
      def run(args, _context, _opts) do
        %{org_id: org_id, actor: actor, branch_id: branch_id} = args

        params =
          %{reason: args.reason || :abandoned_by_principal}
          |> Map.merge(
            if args.terminal_by_job,
              do: %{terminal_by_job: args.terminal_by_job},
              else: %{terminal_by_principal_id: Authz.principal_id(actor)}
          )

        case BranchProcess.transition(org_id, branch_id, :abandon, params, actor: actor) do
          {:ok, branch} -> {:ok, branch}
          {:error, :invalid_transition} -> refine(org_id, branch_id)
          {:error, :terminal} -> {:error, :already_terminal}
          {:error, _} = error -> error
        end
      end

      # `abandon` is declared from open and proposed only; why it was refused matters to the caller.
      defp refine(org_id, branch_id) do
        case Ash.get(Steward.Core.Branches.Branch, branch_id,
               tenant: org_id,
               actor: Steward.Coordinator.Reactors.Support.system(org_id)
             ) do
          {:ok, %{state: :merging}} -> {:error, :merge_in_progress}
          {:ok, _terminal} -> {:error, :already_terminal}
          {:error, _} -> {:error, :not_found}
        end
      end

      @impl true
      def compensate(_reason, _arguments, _context, _opts), do: :ok
    end

    defmodule RoutingRemove do
      @moduledoc false
      use Steward.Coordinator.Reactors.BestEffort

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Plane.V1

      def attempt(%{org_id: org_id, branch: branch}, _context, _opts) do
        upsert = %V1.RoutingUpsert{
          branch_id: branch.id,
          overlay_id: branch.overlay_id,
          target_id: branch.target_id,
          state: :ABANDONED
        }

        with {:ok, dp} <- Support.data_plane_for(org_id, branch.target_id),
             {:ok, _} <-
               Support.instruct(org_id, dp, Support.instruction({:routing_upsert, upsert})) do
          :ok
        end
      end
    end
  end
end
