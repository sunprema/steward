defmodule Steward.Coordinator.HeartbeatActions do
  @moduledoc """
  Executes the actions a heartbeat matrix cell declares (doc 07 §5.3): the
  single seam between the pure `HeartbeatMatrix.decide/3` and the world.

  The default implementation runs `:alert` (writes a `heartbeat.anomaly` event
  and never repairs, doc 13 §6.8) and defers the three that need the merge
  machinery, which E6 provides:

    * `:renew_lease` — `Target.renew_merge_lease` (doc 07 §5.4)
    * `:advance_merged` — `Branch.complete_merge` with the lease release
    * `:resend_merge` — re-sending the `Merge` instruction

  A deferred action returns `{:error, :not_implemented}` and is counted in the
  `[:steward, :coordinator, :heartbeat, :action_deferred]` telemetry event, so
  nothing is silently dropped. Tests substitute their own module with
  `config :steward, Steward.Coordinator, heartbeat_actions: MyModule`.
  """

  @type context :: %{
          org_id: String.t(),
          branch: struct(),
          believed: atom(),
          authoritative: atom(),
          merge_progress: map() | nil
        }

  @callback execute(action :: atom(), context()) :: :ok | {:error, term()}

  @behaviour __MODULE__

  alias Steward.Core.Audit.Event
  alias Steward.Core.Authz.System

  @impl true
  def execute(:alert, ctx) do
    Event
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "heartbeat.anomaly",
        aggregate_type: "branch",
        aggregate_id: ctx.branch.id,
        payload: %{
          believed: ctx.believed,
          authoritative: ctx.authoritative,
          overlay_id: ctx.branch.overlay_id
        },
        occurred_at: DateTime.utc_now()
      },
      tenant: ctx.org_id,
      actor: System.new(:coordinator, ctx.org_id)
    )
    |> Ash.create()
    |> case do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  def execute(action, ctx) when action in [:renew_lease, :advance_merged, :resend_merge] do
    :telemetry.execute(
      [:steward, :coordinator, :heartbeat, :action_deferred],
      %{count: 1},
      %{action: action, branch_id: ctx.branch.id}
    )

    {:error, :not_implemented}
  end

  @doc false
  def impl do
    Application.get_env(:steward, Steward.Coordinator, [])
    |> Keyword.get(:heartbeat_actions, __MODULE__)
  end
end
