-- tools/fixtures/schema.sql — the sample governed target for the local stack.
--
-- Idempotent: safe to run repeatedly against the same database (tools/fixtures/load
-- does so on every `stack up`). Run with psql; it uses psql variables:
--
--   psql "$DSN" -v adapter_password='...' -f tools/fixtures/schema.sql
--
-- Part 1 is the retail schema from doc 17 §11, used by every example in docs 06,
-- 10 and 11. Each table has a primary key (doc 05: tables without a PK are not
-- branchable) and a `last_modified timestamptz` column so the doc 13 §6.5 /
-- doc 05 staleness rule has a per-row modified marker to compare against.
--
-- Part 2 is the Steward-owned `steward` schema that the adapter creates in the
-- target at registration (doc 08 §4, §5.2) and the least-privilege role with
-- exactly the grants listed in doc 08 §8.

\set ON_ERROR_STOP on
SET client_min_messages = warning;   -- quiet "already exists, skipping" on reruns

\if :{?adapter_password}
\else
\set adapter_password 'steward_adapter'
\endif

-- ============================================================================
-- Part 1: retail schema (doc 17 §11), governed schema = public
-- ============================================================================

CREATE TABLE IF NOT EXISTS products (
  sku           text PRIMARY KEY,
  name          text,
  category      text,
  cost          numeric(12,2),
  last_modified timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS prices (
  sku           text PRIMARY KEY REFERENCES products,
  price         numeric(12,2),
  currency      text,
  updated_at    timestamptz,
  last_modified timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS inventory (
  sku           text PRIMARY KEY REFERENCES products,
  qty           int,
  received_at   timestamptz,
  last_modified timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS customers (
  id            uuid PRIMARY KEY,
  name          text,
  email         text,
  segment       text,
  last_modified timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS invoices (
  id            uuid PRIMARY KEY,
  customer_id   uuid REFERENCES customers,
  status        text,
  total         numeric(12,2),
  issued_at     timestamptz,
  last_modified timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger_entries (
  id            bigint PRIMARY KEY,
  account       text,
  amount        numeric(14,2),
  posted_at     timestamptz,
  last_modified timestamptz NOT NULL DEFAULT now()
);

-- Indexes on FK columns. `prices.sku` and `inventory.sku` are also the PK, so
-- only `invoices.customer_id` needs one.
CREATE INDEX IF NOT EXISTS invoices_customer_id_idx ON invoices (customer_id);

-- Keep `last_modified` honest for out-of-band edits made during E2E scenarios
-- (doc 17 §5 scenario 5, `stale_base`). The fixture loader uses COPY, which
-- fires the trigger too, so loaded rows carry the load time.
CREATE OR REPLACE FUNCTION public.steward_touch_last_modified() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.last_modified := now();
  RETURN NEW;
END
$$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['products','prices','inventory','customers','invoices','ledger_entries'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgname = t || '_touch_last_modified' AND tgrelid = ('public.' || t)::regclass
    ) THEN
      EXECUTE format(
        'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.steward_touch_last_modified()',
        t || '_touch_last_modified', t);
    END IF;
  END LOOP;
END
$$;

-- ============================================================================
-- Part 2: Steward-owned schema and least-privilege role (doc 08 §4, §5.2, §8)
-- ============================================================================

-- Role used for snapshots, reads, and apply. Created idempotently; the password
-- is (re)set on every run so .env stays the source of truth. (psql does not
-- interpolate :'vars' inside dollar-quoted DO bodies, hence \gexec.)
SELECT format('CREATE ROLE steward_adapter LOGIN PASSWORD %L', :'adapter_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'steward_adapter')
\gexec
SELECT format('ALTER ROLE steward_adapter WITH LOGIN PASSWORD %L', :'adapter_password')
\gexec

-- No superuser, no CREATEDB, no REPLICATION (doc 08 §8). REPLICATION is only
-- required in the pinned-replica fallback (doc 08 §11), which the local stack
-- does not use by default.
ALTER ROLE steward_adapter NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;

SELECT format('GRANT CONNECT ON DATABASE %I TO steward_adapter', current_database())
\gexec

GRANT USAGE ON SCHEMA public TO steward_adapter;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON products, prices, inventory, customers, invoices, ledger_entries
  TO steward_adapter;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO steward_adapter;

-- Steward's own schema for idempotency state.
CREATE SCHEMA IF NOT EXISTS steward AUTHORIZATION steward_adapter;

-- Row-level idempotency: one row per (merge, table, pk) written in the same
-- transaction as the data write (doc 08 §5.2). `pk` is the row's primary key as
-- a JSON object so composite keys fit without a per-table shape.
CREATE TABLE IF NOT EXISTS steward.applied_rows (
  merge_id   text        NOT NULL,
  table_name text        NOT NULL,
  pk         jsonb       NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (merge_id, table_name, pk)
);

-- One row per committed chunk on the chunked apply path (deltas above 50,000
-- rows, 10,000 rows per chunk; doc 08 §5.2, doc 13 §6.5).
CREATE TABLE IF NOT EXISTS steward.apply_progress (
  merge_id     text        NOT NULL,
  chunk_no     integer     NOT NULL,
  rows_applied integer     NOT NULL DEFAULT 0,
  committed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (merge_id, chunk_no)
);

ALTER TABLE steward.applied_rows   OWNER TO steward_adapter;
ALTER TABLE steward.apply_progress OWNER TO steward_adapter;
