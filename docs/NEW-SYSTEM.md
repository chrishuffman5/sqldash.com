# SQLDash (revived) — new system

Database-agnostic inventory + health-monitoring on **DuckLake/S3**. SQL Server first; PostgreSQL
designed-for-but-deferred. Full plan: `~/.claude/plans/tidy-spinning-bunny.md`.

## Architecture (split)

```
PowerShell collectors  ->  S3 inbox (node-sharded Parquet)  ->  TS writer (sole DuckLake committer)  ->  DuckLake on S3  ->  MCP / scoring views
   (Windows SSPI auth)       (self-describing rows)               (schema contract + dedupe)              common/sqlserver/postgres
```

Collectors never touch the lake — they emit typed, self-describing Parquet and hand off. One writer
is the only DuckLake committer, which sidesteps DuckLake's multi-writer commit-conflict problem.

## Layout

- `lake/ddl/*.sql` — DuckLake schema (`common.*`, `sqlserver.*`), partitioning, threshold seed.
- `lake/views/` — scoring view chain (port of `LoadMetricsIntoReportingTAble`) — WIP.
- `lake/apply-local.ps1` — stand up a LOCAL DuckLake (DuckDB catalog + local data dir as S3 stand-in) and apply DDL.
- `collector/SqlDashCollector.psm1` — SSPI connect, run pack query, stamp identity collector-side, emit typed Parquet.
- `collector/Invoke-Collection.ps1` — Phase 0 runner (registers instance + runs instance-level collectors).
- `collector/packs/<platform>/` — `collections.json` (per-collector emit contract) + `queries/*.sql`.
- `writer/src/ingest.ts` — sole DuckLake committer: contract check (column+type set), dedupe, append.
- `mcp/` — TypeScript MCP server (WIP).

## Key design points (locked)

- **Identity stamped collector-side**, never injected into the remote query (fixes the legacy
  `'@InstanceID'` string-literal hazard). Every fact row carries `instance_key, platform,
  collected_at, source_query_id`.
- **`instance_key`/`database_key` are deterministic UUIDv5** in Phase 0 (idempotent by construction;
  registration-authority UUIDv7 is the documented upgrade when rename/re-home matters).
- **snake_case aliases == target columns == types**, enforced at emit (typed Parquet) AND at ingest
  (writer rejects column/type-set mismatches to quarantine — guards against `union_by_name` silent
  NULL-padding).
- **Dedupe**: facts purge-then-insert by `source_query_id` (unique per emit); dimensions upsert by key.

## Run the Phase 0 loop locally

Requires: duckdb CLI 1.5.x, Node 20+, PowerShell 7, a reachable SQL Server (local Express works).

```powershell
pwsh lake/apply-local.ps1                       # create/upgrade local DuckLake + DDL
pwsh collector/Invoke-Collection.ps1 -Server localhost   # collect -> Parquet inbox
cd writer; npm install; npm run ingest          # inbox -> DuckLake (sole committer)
```

Inspect:
```bash
duckdb -c "ATTACH 'ducklake:<abs>/lake/local/catalog.ducklake' AS lake (DATA_PATH '<abs>/lake/local/data'); USE lake; SELECT * FROM common.metric_cpu;"
```

Local dev artifacts live under `lake/local/` (gitignored): `inbox/`, `processed/`, `quarantine/`,
`catalog.ducklake`, `data/`.

## Status (Phase 0 complete, proven end-to-end)

On SQL Server 2025 Express + DuckLake 1.5.3, the whole loop works:
- **Collect → typed Parquet → contract-checked ingest → DuckLake**, instance- and database-level
  (per-database `database_key` resolved in the collector), joining on `instance_key`/`database_key`
  with zero ETL.
- **Scoring view chain** (`lake/views/scoring.sql`) — faithful port of `LoadMetricsIntoReportingTAble`.
  Validated by a repeatable synthetic parity test (`lake/test-scoring.ps1`): IRC indices match
  hand-computed expectations exactly, including LAG latency deltas, first-bucket skip,
  restart-hour/reset guards, blocker ratio, inverted PLE bands, and the worst-DB instance rollup.
- **MCP server** (`mcp/`) over a read-only DuckLake connection: `list_instances`, `instance_detail`,
  `metric_history`, `problematic_instances`, `run_query` — smoke-tested over stdio (`npm run smoke`).

Scoring intentionally excludes the current in-flight hour (legacy parity), so freshly collected
real data scores once the hour rolls over; the synthetic test exercises complete past hours.

Run the scoring test: `pwsh lake/test-scoring.ps1`.  Apply views to the local lake: `pwsh lake/apply-views-local.ps1`.

### Deferred (next)
- Collectors: `instance_details` (+`sqlserver.instance_details_ext`) and collector-generated `pings`.
- Registration authority (UUIDv7 get-or-create) when instance rename/re-home matters — deterministic
  UUIDv5 keys are used for now.
- Phase 0 concurrency/throughput gate against a real Postgres catalog + S3 (the local lake uses a
  DuckDB-file catalog + local dir); compaction/retention jobs; WMI/volume + alerting subsystems.
