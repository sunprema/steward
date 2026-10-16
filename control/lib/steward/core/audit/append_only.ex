defmodule Steward.Core.Audit.AppendOnly do
  @moduledoc """
  SQL for doc 12 §2.5's append-only enforcement: `REVOKE UPDATE, DELETE`
  from the application role plus an immutability trigger, belt and
  braces. Applies to `events`, `audit_log`, `reviews`, `verdicts`,
  `verdict_assertions`, `review_features`, and `counter_deltas` (the last
  is delete-only by `CounterDrain`, so it keeps `DELETE` and only loses
  `UPDATE`).

  `steward_app` is the role the `Repo` connects as locally (doc 15); if it
  doesn't exist yet in a given environment the `REVOKE` is a no-op rather
  than an error, so this migration doesn't depend on role-provisioning
  order.
  """

  def raise_immutable_function_sql do
    """
    CREATE OR REPLACE FUNCTION raise_immutable() RETURNS trigger AS $BODY$
    BEGIN
      RAISE EXCEPTION 'table % is append-only', TG_TABLE_NAME;
    END;
    $BODY$ LANGUAGE plpgsql;
    """
  end

  def drop_raise_immutable_function_sql, do: "DROP FUNCTION IF EXISTS raise_immutable();"

  def create_trigger_sql(table) do
    "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} " <>
      "FOR EACH ROW EXECUTE FUNCTION raise_immutable();"
  end

  def drop_trigger_sql(table), do: "DROP TRIGGER IF EXISTS #{table}_immutable ON #{table};"

  def revoke_sql(table) do
    """
    DO $BODY$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'steward_app') THEN
        EXECUTE 'REVOKE UPDATE, DELETE ON #{table} FROM steward_app';
      END IF;
    END;
    $BODY$;
    """
  end

  def revoke_delete_only_sql(table) do
    """
    DO $BODY$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'steward_app') THEN
        EXECUTE 'REVOKE UPDATE ON #{table} FROM steward_app';
      END IF;
    END;
    $BODY$;
    """
  end

  def grant_sql(table) do
    """
    DO $BODY$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'steward_app') THEN
        EXECUTE 'GRANT INSERT, SELECT ON #{table} TO steward_app';
      END IF;
    END;
    $BODY$;
    """
  end

  def grant_delete_only_sql(table) do
    """
    DO $BODY$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'steward_app') THEN
        EXECUTE 'GRANT INSERT, SELECT, DELETE ON #{table} TO steward_app';
      END IF;
    END;
    $BODY$;
    """
  end
end
