# sqldash

Database-agnostic inventory + health monitoring for database fleets, built on a **DuckLake** lakehouse
(Parquet on object storage). A revival of an enterprise SQL Server fleet monitor, rebuilt to scale and to
support multiple database platforms. **SQL Server first; PostgreSQL by design.**

## How it works

```
collectors  ──(query remote DB · stamp integer instance_id · write the result set)──►  DuckLake  ──►  MCP server / scoring views
   Windows-integrated auth (SSPI, no creds)                                            PG catalog +    problematic instances,
   per-platform query packs · pooled parallel reads                                    S3 (ZSTD),      instance detail, history
   in-process DuckDB.NET writer (direct commit)                                        common/sqlserver/postgres
```

The one invariant that makes loading ETL-free: **the integer instance/database key is stamped onto every
row at collection time**, so writing into the lake is a dumb append — no joins, no transform — exactly like
the legacy `SqlBulkCopy`-into-SQL-Server. The collector commits **directly** into DuckLake (no file inbox,
no separate writer service); the PostgreSQL catalog fronts the transactional load, and a benchmark showed
concurrent appends never conflict. All derived metrics (CPU/memory/latency/blocking indices, the 0–10 IRC
health score) are computed **read-side** by a SQL view chain. Full design: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Components

| Dir | What |
|-----|------|
| `collector/` | Per-platform query packs (`packs/<platform>/`: `collections.json` emit contract + `queries/*.sql`). The production direct-write collector is the next build (see the decision doc). |
| `lake/` | DuckLake DDL (`ddl/`), the scoring view chain (`views/scoring.sql`), the Postgres registry (`registry.sql`), and apply/test scripts. |
| `bench/` | Ingest-method evaluation harness — 4 write-method runners + Postgres/S3 telemetry + scorecard. |
| `mcp/` | TypeScript MCP server exposing the fleet store to LLM clients (problematic instances, instance detail, metric history, ad-hoc query). |
| `docs/` | [`ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`INGEST-DECISION.md`](docs/INGEST-DECISION.md), [`PHASE0-GATE.md`](docs/PHASE0-GATE.md); `bench/results/SCORECARD.md`. |

## Quick start

Requires the DuckDB CLI (1.5.x), Node 20+, .NET 8 SDK, PowerShell 7, ODBC Driver 18, and a reachable SQL
Server (local Express is fine). For the cloud lake: AWS CLI v2 + a PostgreSQL 17 (see Cloud setup below).

```powershell
pwsh lake/apply-cloud.ps1 -Rebuild        # cloud lake: PG catalog + S3 data + schema + views + ZSTD
#  or, fully offline:  pwsh lake/apply-local.ps1   (DuckDB-file catalog + local dir as an S3 stand-in)
pwsh lake/apply-registry.ps1              # Postgres registry.instances (IDENTITY) + seed the fleet
pwsh lake/test-scoring.ps1                # repeatable scoring parity test (synthetic fixture)
pwsh bench/run-bench.ps1 -Methods M1,M2,M3,M4 -FleetLimit 1000 -Compact   # ingest-method benchmark
cd mcp; npm install; npm run smoke        # MCP stdio smoke test
```

## Cloud setup (S3 data store + Secrets Manager)

In production the DuckLake lakehouse keeps its **data files in S3** and its **catalog (metadata) in
PostgreSQL**. Two AWS resources back this. PostgreSQL itself is a **prerequisite you provide** (e.g. a
local Docker `postgres:17` during development) — its setup is out of scope here.

**Prerequisites**
- AWS CLI v2 configured with valid credentials in `~/.aws` (this repo's region is `us-east-1`). If your
  session has expired, reauthenticate first (e.g. `aws sso login`).
- A reachable **PostgreSQL 17** — the DuckLake catalog DB.

### 1. S3 bucket (DuckLake data)

Bucket names are globally unique, so suffix with your AWS **account ID** (`<account-id>`):

```bash
aws sts get-caller-identity --query Account --output text     # prints your <account-id>
aws s3 mb s3://sqldash-data-<account-id> --region us-east-1
```

PowerShell, filling in the account ID automatically:

```powershell
$acct = aws sts get-caller-identity --query Account --output text
aws s3 mb "s3://sqldash-data-$acct" --region us-east-1
```

This bucket is the DuckLake `DATA_PATH`; point the collector/MCP at it with
`SQLDASH_DATA=s3://sqldash-data-<account-id>/`.

### 2. Secrets Manager secret (Postgres catalog admin creds)

Store the catalog DB connection in Secrets Manager so the collector/MCP never carry the password
in config. Template:

```bash
aws secretsmanager create-secret \
  --name sqldash-postgres-admin \
  --secret-string '{"host":"<pg-host>","port":5432,"username":"<admin-user>","password":"<admin-pass>"}'
```

On Windows, pull the values straight from your PowerShell secret vault so the password is never written to
disk or committed:

```powershell
# parse the stored "key=value;" connection string -> JSON -> Secrets Manager
$cs     = Get-Secret Postgres17_ConnectionString -AsPlainText
$kv     = @{}; $cs.Split(';') | Where-Object { $_ } | ForEach-Object { $k,$v = $_.Split('=',2); $kv[$k.Trim()] = $v }
$secret = @{ host = $kv['Server']; port = [int]$kv['Port']; username = $kv['User Id']; password = $kv['Password'] } | ConvertTo-Json -Compress
aws secretsmanager create-secret --name sqldash-postgres-admin --secret-string $secret
```

> Set `host` to the address the collector/MCP can actually reach — use `localhost` only when those processes
> run on the same host as Postgres. (If JSON quoting trips up your shell, write the JSON to a temp file and
> pass `--secret-string file://secret.json`, then delete it.)

Verify:

```bash
aws s3 ls | grep sqldash-data
aws secretsmanager get-secret-value --secret-id sqldash-postgres-admin --query SecretString --output text
```

These two resources are where the production lake plugs in: `SQLDASH_DATA` → the S3 bucket, and the
`sqldash-postgres-admin` secret → the DuckLake catalog connection (`SQLDASH_CATALOG`). The local-dev loop
above uses a DuckDB-file catalog + local directory instead, so neither AWS resource is required to run it.

## Status

On SQL Server 2025 + DuckLake 1.5.3 + S3: the integer-keyed schema (`instance_id` from a Postgres registry
+ native `database_id`, no GUIDs), cloud lake (PG catalog + S3, ZSTD), and faithfully-ported IRC health
score are in place and **parity-tested**. The storage acceptance gate passed (0 conflicts, ~9.6 commits/sec,
201→1 compaction), and a 4-method **ingest benchmark** chose the direct-write approach: in-process DuckDB.NET
+ pooled SSPI reads (~3.7–6× faster than the alternatives) — see [`docs/INGEST-DECISION.md`](docs/INGEST-DECISION.md)
and [`bench/results/SCORECARD.md`](bench/results/SCORECARD.md).

**Next:** build the production direct-write collector on the winning method (ping-first → pooled SSPI reads
→ in-process batched write, data-inlining/flush tuned), schedule maintenance, then `instance_details` /
AlwaysOn / volume + alerting. See `docs/NEW-SYSTEM.md` for the component map.
