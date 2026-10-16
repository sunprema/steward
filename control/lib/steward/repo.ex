defmodule Steward.Repo do
  @moduledoc """
  The only module in the application allowed to touch Ecto/the database
  directly; every other module writes through an Ash action (doc 18 §2).
  """
  use Boundary, deps: []

  use AshPostgres.Repo,
    otp_app: :steward

  def installed_extensions do
    ["ash-functions", "uuid-ossp", "pg_trgm"]
  end

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
