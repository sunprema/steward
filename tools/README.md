# tools/

Developer tooling: the local stack (`stack/`) and the synthetic fixture generator
(`fixtures/`). Specs: doc 18 §7–8 (conventions), doc 17 §5 and §11 (testing
strategy), doc 14 §9 (environments), doc 08 §4, §5.2, §8 (Steward schema in
the target, least-privilege grants).

**Rule (doc 18 §8): every component must run under the local stack. If a change
breaks `tools/stack/stack up`, the PR is not done.**

## Local stack

Requirements: Docker with Compose v2 (`docker compose version`), Python 3.11+,
and `psql` on PATH (the loader falls back to the container's psql through
`stack psql`, but `stack up` needs a local `psql` to run `fixtures/load`).

```
cp tools/stack/.env.example tools/stack/.env   # optional; defaults match the example
tools/stack/stack up                           # start, wait for health, load fixtures, print DSNs
tools/stack/stack ps
tools/stack/stack logs target-db
tools/stack/stack psql target                  # psql into the retail target
tools/stack/stack psql control                 # psql into the control-plane metadata DB
tools/stack/stack psql adapter                 # psql as the least-privilege steward_adapter role
tools/stack/stack down                         # stop; volumes kept
tools/stack/stack reset                        # down -v, then up: clean databases between scenarios
```

`STEWARD_FIXTURE_SIZE=m tools/stack/stack up` loads a different fixture size
(default `s`). `stack` sources `tools/stack/.env` if present; docker compose
reads the same file.

### What runs, and where

| Service | Image | Host port | What it is |
|---|---|---|---|
| `control-db` | postgres:16 | 5433 | Control-plane metadata DB `steward_control` (doc 12) |
| `target-db` | postgres:16 | 5434 | Sample governed target, DB `retail`, doc 17 §11 schema, `wal_level=logical` so the Neon-replica-by-logical-replication shape (doc 08 §11) can subscribe to it |
| `minio` | minio | 9000 (API), 9001 (console) | Object store; bucket `steward` created by the one-shot `minio-init` |
| `steward-proxy` | commented out | 5432 (Postgres wire) | Enabled when M0 R-proxy lands |
| `steward-engine` | commented out | 8443 (grant endpoint); gRPC on `/run/steward/engine.sock` | Enabled with the engine |
| `steward-adapters` | commented out | none (gRPC on `/run/steward/adapter.sock`) | Enabled with the adapter host |
| `steward-control` | commented out | 4000 (HTTP), 50051 (gRPC `Session`) | Enabled with the control plane |

The three data-plane containers share the `steward-run` volume for their Unix
sockets, mirroring the pod layout in doc 14 §2. Each placeholder is uncommented
as its milestone lands (doc 19); keep `stack up` green when you do.

Default credentials (local only, see `.env.example`): `steward/steward` on
control-db, `retail/retail` on target-db, `steward_adapter/steward_adapter` for
the adapter role, `steward/stewardsteward` on MinIO.

After `stack up` you should see: three healthy services, `minio-init` exited 0,
the fixture row counts for the six retail tables, `underpriced: 20 of 1000
prices rows (2.00 %)` for size `s`, and the connection strings.

Not yet implemented from doc 17 §5: the `neon` / `fallback` / `iceberg`
profiles, the fake OIDC provider, and the chaos hooks (`kill`, `partition`,
`fill wal`, `gc-branch`). They are added with the components that need them.

## Fixtures

`fixtures/generate.py` is the single synthetic-data generator (doc 18 §7: never
real customer data, however anonymised). Standard library only.

```
python3 tools/fixtures/generate.py --size s            # -> tools/fixtures/out/s/*.csv + MANIFEST
python3 tools/fixtures/generate.py --size m --seed 7
tools/fixtures/load --size s                            # into target-db (DSN from .env)
tools/fixtures/load --size m --dsn postgres://u:p@host:port/db
```

| Size | products / prices / inventory | customers | invoices / ledger_entries |
|---|---|---|---|
| `s` | 1k | 500 | 5k |
| `m` | 100k | 20k | 200k |
| `l` | 1M | 200k | 2M |
| `xl` | 10M | 1M | 10M |

Guarantees:

- **Deterministic.** Output is byte-identical for a given `(seed, size,
  GENERATOR_VERSION)`; `MANIFEST` records the SHA-256 and row count of every
  file. Bump `GENERATOR_VERSION` when you change the generator (doc 17 §11).
- **Sentinel.** 1 in 100 rows carries `ZQX-<seed>` in every string column, so
  log-leak tests can `grep ZQX-` any output.
- **Policy examples.** Exactly 2 % of `prices` rows have `price < products.cost`
  (`underpriced_every=50`); all others have `price > cost`.
- **Streaming.** Rows go straight to disk; `xl` runs in constant memory (size
  `m` peaks under 20 MB RSS).

`fixtures/load` applies `schema.sql` (idempotent), truncates the six retail
tables, `\copy`s the CSVs in FK order, runs `ANALYZE`, and prints row counts and
the underpriced rate. It generates `out/<size>` first if it is missing.

`fixtures/schema.sql` contains:

- the doc 17 §11 retail schema (`products`, `prices`, `inventory`, `customers`,
  `invoices`, `ledger_entries`), every table with a primary key (no-PK tables
  are not branchable, doc 05) and a `last_modified timestamptz` maintained by a
  trigger, for the staleness check (doc 13 §6.5);
- the Steward-owned `steward` schema with `applied_rows` and `apply_progress`
  (doc 08 §4, §5.2);
- the `steward_adapter` role with exactly the doc 08 §8 grants: `CONNECT`,
  `USAGE` on `public`, `SELECT/INSERT/UPDATE/DELETE` on the governed tables,
  `USAGE, SELECT` on sequences, ownership of schema `steward`; no superuser,
  `CREATEDB` or `REPLICATION`.

`out/` is generated and ignored by git. Doc 17 §11 says `s` and `m` are
checked in as Parquet; that conversion lands with the first consumer that
needs Parquet (CSV is what `\copy` wants today).
