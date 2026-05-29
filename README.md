# sqldash

Database-agnostic inventory + health monitoring for database fleets, built on a **DuckLake** lakehouse
(Parquet on object storage). A revival of an enterprise SQL Server fleet monitor, rebuilt to scale and to
support multiple database platforms. **SQL Server first; PostgreSQL by design.**

## How it works

```
PowerShell collectors  ─►  inbox (node-sharded Parquet)  ─►  TypeScript writer  ─►  DuckLake  ─►  MCP server / scoring views
   Windows-integrated         self-describing rows            sole committer,        common.* /     problematic instances,
   auth (SSPI), no creds      (key travels with row)          schema contract +      sqlserver.* /   instance detail, history
   per-platform query packs                                   idempotent dedupe      postgres.*
```

The one invariant that makes loading ETL-free: **the instance/database key is stamped onto every row at
collection time**, so bulk-loading into the lake is a dumb append — no joins, no transform. Collectors
never touch the lake; a single writer is the only DuckLake committer, which sidesteps multi-writer commit
conflicts. All derived metrics (CPU/memory/latency/blocking indices, the 0–10 IRC health score) are
computed **read-side** by a SQL view chain.

## Components

| Dir | What |
|-----|------|
| `collector/` | PowerShell collectors + per-platform query packs (`packs/<platform>/`). Connect with Windows auth, stamp identity, emit typed Parquet. |
| `lake/` | DuckLake DDL (`ddl/`), the health-scoring view chain (`views/scoring.sql`), and local-dev / test scripts. |
| `writer/` | TypeScript DuckLake writer/ingester — the sole committer; enforces the column/type schema contract. |
| `mcp/` | TypeScript MCP server exposing the fleet store to LLM clients (problematic instances, instance detail, metric history, ad-hoc query). |
| `docs/NEW-SYSTEM.md` | Architecture, run instructions, and status. |

## Quick start (local dev)

Requires the DuckDB CLI (1.5.x), Node 20+, PowerShell 7, and a reachable SQL Server (local Express is fine).

```powershell
pwsh lake/apply-local.ps1                          # create a local DuckLake (DuckDB catalog + local dir) + DDL
pwsh collector/Invoke-Collection.ps1 -Server localhost   # collect -> typed Parquet inbox
cd writer; npm install; npm run ingest             # inbox -> DuckLake (sole committer)
cd ../lake; pwsh apply-views-local.ps1             # apply the scoring view chain
pwsh test-scoring.ps1                              # repeatable scoring parity test (synthetic fixture)
cd ../mcp; npm install; npm run smoke              # MCP stdio smoke test
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

This bucket is the DuckLake `DATA_PATH`; point the writer/MCP at it with
`SQLDASH_DATA=s3://sqldash-data-<account-id>/`.

### 2. Secrets Manager secret (Postgres catalog admin creds)

Store the catalog DB connection in Secrets Manager so the collector/writer/MCP never carry the password
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

> Set `host` to the address the writer/MCP can actually reach — use `localhost` only when those processes
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

Phase 0 is proven end-to-end on SQL Server 2025 + DuckLake 1.5.3: collect → typed Parquet →
contract-checked ingest → cross-table join on the surrogate keys → faithfully-ported IRC health score
(parity-tested) → MCP readout. See `docs/NEW-SYSTEM.md` for what's validated and what's next (Postgres
catalog + S3 concurrency gate, remaining collectors, alerting/volume subsystems).
