defmodule Steward.Jobs.ResumeComputing do
  @moduledoc """
  Every minute (doc 13 §6.3 f3, doc 07 §5.2): a branch that is `proposed` with a
  changeset still `computing` long after it should have been evaluated lost the
  flow that was computing it (a node died). Re-enter `Propose` for it under the
  same changeset id; the flow's own retry budget then applies, and past it the
  changeset is superseded `compute_failed` and the branch returns to `open`.

  "Long after" is `:resume_after_ms` (default 20 minutes), well beyond the compute
  budget of three attempts over about five minutes, so a flow that is merely slow
  is not resumed underneath itself. If two did run, the second's verdict insert
  would conflict (a changeset has exactly one verdict), harmlessly.
  """
  use Oban.Worker, queue: :reconcile, max_attempts: 1

  require Ash.Query

  alias Steward.Coordinator.Flows
  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Changeset
  alias Steward.Core.Targets.TenantList

  @default_after_ms 20 * 60_000

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -after_ms(), :millisecond)

    resumed =
      for org_id <- TenantList.list_tenants([]), changeset <- stuck(org_id, cutoff), reduce: 0 do
        count ->
          Flows.resume_propose(%{org_id: org_id, branch_id: changeset.branch_id})
          count + 1
      end

    :telemetry.execute([:steward, :jobs, :resume_computing], %{resumed: resumed}, %{})
    :ok
  end

  @doc false
  def stuck(org_id, cutoff) do
    Changeset
    |> Ash.Query.filter(
      state == :computing and inserted_at < ^cutoff and branch.state == :proposed
    )
    |> Ash.read!(tenant: org_id, actor: System.jobs())
  end

  defp after_ms,
    do:
      Application.get_env(:steward, Steward.Coordinator, [])
      |> Keyword.get(:resume_after_ms, @default_after_ms)
end
