defmodule Steward.Coordinator.Plane.Handlers do
  @moduledoc """
  Where the data plane's reports go once the session host has authenticated and
  decoded them. The session host owns the stream; what to *do* with a
  `ChangesetReport` or a `MergeOutcome` belongs to the flows that asked for it:
  the `Propose` reactor and policy engine (E4, E5) and the `Merge` reactor (E6).
  A `ChangesetReport` goes to `Steward.Coordinator.Reports`, where the `Propose`
  reactor (E4) waits for it. A `MergeOutcome` has no consumer until the `Merge`
  reactor (E6): the default counts it in telemetry
  (`[:steward, :plane, :report_deferred]`) and drops it, which is safe because the
  data plane re-reports on the next heartbeat (doc 13 §6.5 f8–f9).

  Replace with `config :steward, Steward.Coordinator, plane_handlers: MyModule`.
  """
  @callback changeset_report(org_id :: String.t(), data_plane_id :: String.t(), struct()) ::
              :ok | {:error, term()}
  @callback merge_outcome(org_id :: String.t(), data_plane_id :: String.t(), struct()) ::
              :ok | {:error, term()}

  @behaviour __MODULE__

  @impl true
  def changeset_report(_org_id, _data_plane_id, report),
    do: Steward.Coordinator.Reports.deliver(report)

  @impl true
  def merge_outcome(_org_id, data_plane_id, outcome),
    do: deferred(:merge_outcome, data_plane_id, outcome.merge_id)

  defp deferred(kind, data_plane_id, id) do
    :telemetry.execute([:steward, :plane, :report_deferred], %{count: 1}, %{
      kind: kind,
      data_plane_id: data_plane_id,
      id: id
    })

    :ok
  end

  @doc false
  def impl,
    do:
      Application.get_env(:steward, Steward.Coordinator, [])
      |> Keyword.get(:plane_handlers, __MODULE__)
end
