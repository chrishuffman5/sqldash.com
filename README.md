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

## Status

Phase 0 is proven end-to-end on SQL Server 2025 + DuckLake 1.5.3: collect → typed Parquet →
contract-checked ingest → cross-table join on the surrogate keys → faithfully-ported IRC health score
(parity-tested) → MCP readout. See `docs/NEW-SYSTEM.md` for what's validated and what's next (Postgres
catalog + S3 concurrency gate, remaining collectors, alerting/volume subsystems).
