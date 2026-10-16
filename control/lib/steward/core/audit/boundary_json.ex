defmodule Steward.Core.Audit.BoundaryJson do
  @moduledoc """
  SQL for the `validate_boundary_json()` trigger function (doc 12 §2.4):
  rejects any boundary jsonb column containing a row-data key at any depth.
  Defence in depth behind the Ash-level check. `CREATE OR REPLACE` is
  idempotent, so every resource with a boundary jsonb column declares this
  same statement before its own trigger — cross-resource statement
  ordering isn't reliable, but every resource ordering itself is.
  """

  def create_function_sql do
    """
    CREATE OR REPLACE FUNCTION validate_boundary_json() RETURNS trigger AS $BODY$
    DECLARE
      val jsonb;
    BEGIN
      val := (row_to_json(NEW)::jsonb) -> TG_ARGV[0];
      IF val IS NOT NULL AND (
        jsonb_path_exists(val, '$.**.rows') OR jsonb_path_exists(val, '$.**.row') OR
        jsonb_path_exists(val, '$.**.sample_keys') OR jsonb_path_exists(val, '$.**.before_image') OR
        jsonb_path_exists(val, '$.**.after_image') OR jsonb_path_exists(val, '$.**.values') OR
        jsonb_path_exists(val, '$.**.key') OR jsonb_path_exists(val, '$.**.keys')
      ) THEN
        RAISE EXCEPTION 'boundary violation: % contains a banned key', TG_ARGV[0];
      END IF;
      RETURN NEW;
    END;
    $BODY$ LANGUAGE plpgsql;
    """
  end

  def drop_function_sql, do: "DROP FUNCTION IF EXISTS validate_boundary_json();"

  def create_trigger_sql(table, column) do
    "CREATE TRIGGER validate_boundary_json_#{column} BEFORE INSERT OR UPDATE ON #{table} " <>
      "FOR EACH ROW EXECUTE FUNCTION validate_boundary_json('#{column}');"
  end

  def drop_trigger_sql(table, column) do
    "DROP TRIGGER IF EXISTS validate_boundary_json_#{column} ON #{table};"
  end
end
