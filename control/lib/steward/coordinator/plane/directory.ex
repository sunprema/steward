defmodule Steward.Coordinator.Plane.Directory do
  @moduledoc """
  Which org owns a data-plane identity (doc 15 §4.2). The stream's certificate
  names only the data plane (SAN = `data_plane_id`), so the org has to be found
  from the id, across tenants.

  This is the one deliberately tenant-less read of the session host, and it is a
  single-row lookup on the primary key, reviewed as a read-model query (doc 18
  §2). Everything after it carries the org as the tenant.
  """
  require Ash.Query

  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Branch
  alias Steward.Core.Targets.DataPlane

  @sql "SELECT org_id, cert_serial FROM data_planes WHERE id = $1"

  @doc "`{:ok, %{org_id, cert_serial}}` or `:error`; a malformed id is `:error`."
  def lookup(data_plane_id) do
    with {:ok, raw} <- Ecto.UUID.dump(data_plane_id),
         {:ok, %{rows: [[org, serial]]}} <- Ecto.Adapters.SQL.query(Steward.Repo, @sql, [raw]) do
      {:ok, %{org_id: Ecto.UUID.load!(org), cert_serial: serial}}
    else
      _ -> :error
    end
  end

  @doc "Records that the data plane has a stream open (`data_planes.last_session_at`). Best effort."
  def touch(org_id, data_plane_id) do
    actor = System.new(:session, org_id)

    with {:ok, plane} <- Ash.get(DataPlane, data_plane_id, tenant: org_id, actor: actor) do
      plane
      |> Ash.Changeset.for_update(:update, %{last_session_at: DateTime.utc_now()},
        tenant: org_id,
        actor: actor
      )
      |> Ash.update()
    end
  end

  @doc """
  How many non-terminal branches live on targets served by this data plane. It
  sizes the heartbeat bucket (`Plane.Limiter.rate_for/1`); 0 if it cannot be read.
  """
  def non_terminal_count(org_id, data_plane_id) do
    Branch
    |> Ash.Query.filter(
      state in [:open, :proposed, :merging] and target.data_plane_id == ^data_plane_id
    )
    |> Ash.count(tenant: org_id, actor: System.new(:coordinator, org_id))
    |> case do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end
end
