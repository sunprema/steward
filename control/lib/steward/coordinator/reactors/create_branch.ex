defmodule Steward.Coordinator.Reactors.CreateBranch do
  @moduledoc """
  Create a branch (doc 13 §6.1, doc 07 §5.1). The checkpoint is the `Branch` row.

      intent ─ ids ─ target ─ overlay ─▶ **checkpoint** ─▶ commit_intent
                                                         ─▶ start_process
                                                         ─▶ routing

    1. `intent`: the `CreateIntent` row, as the *caller* (so `branch:write` on the
       target is checked here); compensable by `CreateIntent.fail`. Its purpose is
       to make an orphaned overlay identifiable (doc 13 §6.1).
    2. `ids`: the branch id, chosen by the control plane before the data plane is
       asked for anything, because the overlay is initialised for it.
    3. `target`: which data plane serves the target, and the TTL.
    4. `overlay`: `InitialiseOverlay` on the data plane, *outside any transaction*
       (doc 13 invariant 10). The data plane generates the overlay id. Nothing to
       undo: an overlay whose branch row never lands is an orphan that its own
       heartbeat gets answered `unknown` (§6.1 f4–f5).
    5. **`checkpoint`**: `Branch.create` with the ids and base snapshot the data
       plane returned. No undo (doc 07 §5.0).
    6. After it, best effort: mark the intent committed, start the branch process
       (its `init` re-reads the row, so it cannot start before the commit is
       visible), and add the routing entry (repaired by the heartbeat reply, §6.1 f6).

  Failures before the checkpoint leave nothing: the caller retries and gets fresh
  ids. Use `Steward.Coordinator.Flows.create_branch/1`, which first returns an
  existing branch for the same idempotency key (§6.1, "Retry with fresh IDs").
  """
  use Reactor

  require Ash.Query

  alias Steward.Coordinator.Reactors.CreateBranch.Steps

  input :org_id
  input :actor
  input :target_id
  input :idempotency_key
  input :copy_overlay_from

  step :intent, Steps.Intent do
    argument :org_id, input(:org_id)
    argument :actor, input(:actor)
    argument :target_id, input(:target_id)
    argument :idempotency_key, input(:idempotency_key)
  end

  step :ids, Steps.Ids do
    wait_for :intent
  end

  step :target, Steps.Target do
    argument :org_id, input(:org_id)
    argument :target_id, input(:target_id)
    wait_for :intent
  end

  step :overlay, Steps.Overlay do
    argument :org_id, input(:org_id)
    argument :target_id, input(:target_id)
    argument :copy_overlay_from, input(:copy_overlay_from)
    argument :ids, result(:ids)
    argument :target, result(:target)
  end

  step :checkpoint, Steps.Checkpoint do
    argument :org_id, input(:org_id)
    argument :actor, input(:actor)
    argument :target_id, input(:target_id)
    argument :idempotency_key, input(:idempotency_key)
    argument :ids, result(:ids)
    argument :target, result(:target)
    argument :overlay, result(:overlay)
  end

  step :commit_intent, Steps.CommitIntent do
    argument :org_id, input(:org_id)
    argument :intent, result(:intent)
    argument :branch, result(:checkpoint)
  end

  step :start_process, Steps.StartProcess do
    argument :org_id, input(:org_id)
    argument :branch, result(:checkpoint)
    wait_for :commit_intent
  end

  step :routing, Steps.Routing do
    argument :org_id, input(:org_id)
    argument :target, result(:target)
    argument :branch, result(:checkpoint)
    wait_for :start_process
  end

  return :checkpoint

  defmodule Steps do
    @moduledoc false

    defmodule Intent do
      @moduledoc false
      use Reactor.Step

      require Ash.Query

      alias Steward.Core.Authz
      alias Steward.Core.Branches.CreateIntent
      alias Steward.Coordinator.Reactors.Support

      @impl true
      def run(
            %{org_id: org_id, actor: actor, target_id: target_id, idempotency_key: key},
            _context,
            _opts
          ) do
        principal_id = Authz.principal_id(actor)

        case existing(org_id, principal_id, key) do
          nil ->
            CreateIntent
            |> Ash.Changeset.for_create(
              :create,
              %{target_id: target_id, principal_id: principal_id, idempotency_key: key},
              tenant: org_id,
              actor: actor
            )
            |> Ash.create()

          intent ->
            # A retry of an attempt that did not complete: one intent per
            # (principal, key), started again.
            intent
            |> Ash.Changeset.for_update(:restart, %{},
              tenant: org_id,
              actor: Support.system(org_id)
            )
            |> Ash.update()
        end
      end

      @impl true
      def compensate(_reason, _arguments, _context, _opts), do: :ok

      @impl true
      def undo(intent, %{org_id: org_id}, _context, _opts) do
        intent
        |> Ash.Changeset.for_update(:fail, %{}, tenant: org_id, actor: Support.system(org_id))
        |> Ash.update()
        |> case do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end
      end

      defp existing(org_id, principal_id, key) do
        CreateIntent
        |> Ash.Query.filter(principal_id == ^principal_id and idempotency_key == ^key)
        |> Ash.read_one!(tenant: org_id, actor: Support.system(org_id))
      end
    end

    defmodule Ids do
      @moduledoc false
      use Reactor.Step

      @impl true
      def run(_arguments, _context, _opts), do: {:ok, %{branch_id: Ash.UUIDv7.generate()}}
    end

    defmodule Target do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Core.Targets.TargetSettings

      @impl true
      def run(%{org_id: org_id, target_id: target_id}, _context, _opts) do
        with {:ok, data_plane_id} <- Support.data_plane_for(org_id, target_id) do
          {:ok, %{data_plane_id: data_plane_id, ttl_seconds: ttl_seconds(org_id, target_id)}}
        end
      end

      defp ttl_seconds(org_id, target_id) do
        case Ash.get(TargetSettings, target_id, tenant: org_id, actor: Support.system(org_id)) do
          {:ok, %{branch_ttl: ttl}} -> Duration.to_iso8601(ttl) |> duration_seconds()
          _ -> 24 * 3600
        end
      end

      defp duration_seconds(iso) do
        {:ok, d} = Duration.from_iso8601(iso)
        d.day * 86_400 + d.hour * 3600 + d.minute * 60 + d.second
      end
    end

    defmodule Overlay do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Plane.V1

      @impl true
      def run(
            %{
              org_id: org_id,
              target_id: target_id,
              copy_overlay_from: from,
              ids: ids,
              target: target
            },
            _context,
            _opts
          ) do
        init = %V1.InitialiseOverlay{
          branch_id: ids.branch_id,
          target_id: target_id,
          copy_overlay_from: from
        }

        case Support.instruct(
               org_id,
               target.data_plane_id,
               Support.instruction({:initialise_overlay, init})
             ) do
          {:ok, %{body: {:overlay_initialised, initialised}}} -> {:ok, initialised}
          {:ok, _no_body} -> {:error, :overlay_init_malformed}
          {:error, _} = error -> error
        end
      end

      # Nothing durable exists to undo: an overlay with no branch row is an orphan
      # that the heartbeat kills (doc 13 §6.1 f4–f5).
      @impl true
      def compensate(_reason, _arguments, _context, _opts), do: :ok
    end

    defmodule Checkpoint do
      @moduledoc false
      use Reactor.Step

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Core.Authz
      alias Steward.Core.Branches.Branch

      @fidelity %{"TRUE_SNAPSHOT" => :TRUE_SNAPSHOT, "TIMESTAMP_BOUNDED" => :TIMESTAMP_BOUNDED}

      # The checkpoint (doc 13 §6.1 step 6): the branch row with state `open`. It
      # has no `undo/4` by design (doc 07 §5.0).
      @impl true
      def run(args, _context, _opts) do
        %{org_id: org_id, actor: actor, ids: ids, target: target, overlay: overlay} = args

        Branch
        |> Ash.Changeset.for_create(
          :create,
          %{
            id: ids.branch_id,
            target_id: args.target_id,
            principal_id: Authz.principal_id(actor),
            overlay_id: overlay.overlay_id,
            base_snapshot_ref: overlay.base_snapshot_ref,
            base_snapshot_fidelity: Map.fetch!(@fidelity, overlay.fidelity),
            base_snapshot_at: DateTime.from_unix!(overlay.opened_at.seconds),
            idempotency_key: args.idempotency_key,
            ttl_expires_at: DateTime.add(DateTime.utc_now(), target.ttl_seconds)
          },
          tenant: org_id,
          actor: Support.system(org_id)
        )
        |> Ash.create()
      end

      @impl true
      def compensate(_reason, _arguments, _context, _opts), do: :ok
    end

    defmodule CommitIntent do
      @moduledoc false
      use Steward.Coordinator.Reactors.BestEffort

      alias Steward.Coordinator.Reactors.Support

      def attempt(%{org_id: org_id, intent: intent, branch: branch}, _context, _opts) do
        intent
        |> Ash.Changeset.for_update(:commit, %{branch_id: branch.id},
          tenant: org_id,
          actor: Support.system(org_id)
        )
        |> Ash.update()
        |> case do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end
      end
    end

    defmodule StartProcess do
      @moduledoc false
      use Steward.Coordinator.Reactors.BestEffort

      # `init` re-reads the row; a failure here is repaired by the next heartbeat or sweep.
      def attempt(%{org_id: org_id, branch: branch}, _context, _opts) do
        case Steward.Coordinator.Branch.ensure_started(org_id, branch.id) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defmodule Routing do
      @moduledoc false
      use Steward.Coordinator.Reactors.BestEffort

      alias Steward.Coordinator.Reactors.Support
      alias Steward.Plane.V1

      def attempt(%{org_id: org_id, target: target, branch: branch}, _context, _opts) do
        upsert = %V1.RoutingUpsert{
          branch_id: branch.id,
          overlay_id: branch.overlay_id,
          target_id: branch.target_id,
          base_snapshot_ref: branch.base_snapshot_ref,
          state: :AUTH_OPEN,
          principal_id: branch.principal_id,
          api_keys: Steward.Coordinator.Reactors.CreateBranch.api_key_entries(org_id, branch)
        }

        case Support.instruct(
               org_id,
               target.data_plane_id,
               Support.instruction({:routing_upsert, upsert})
             ) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end
    end
  end

  @doc false
  # The principal's live keys for the target, as the proxy needs them to authenticate
  # the connection (doc 04 §3.1): SHA-256 of the secret, never the secret.
  def api_key_entries(org_id, branch) do
    alias Steward.Core.Targets.ApiKey

    principal_id = branch.principal_id

    ApiKey
    |> Ash.Query.filter(principal_id == ^principal_id and is_nil(revoked_at))
    |> Ash.read!(tenant: org_id, actor: Steward.Coordinator.Reactors.Support.system(org_id))
    |> Enum.filter(&(branch.target_id in &1.target_ids))
    |> Enum.map(
      &%Steward.Plane.V1.ApiKeyEntry{
        key_hash: &1.secret_sha256,
        principal_id: &1.principal_id,
        revoked: false
      }
    )
  end
end
