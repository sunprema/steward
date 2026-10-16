defmodule Steward.Repo.Migrations.AddObanJobs do
  @moduledoc """
  Oban's own table (doc 07 §4: `oban_jobs`, durable work queue; doc 12 §10 lists it
  beside `orgs` and `schema_migrations` as carrying no `org_id`). Oban owns this
  schema, so it is the one hand-written migration besides the extensions: it is
  not an Ash resource and `mix ash.codegen` cannot produce it.
  """
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
