# SQLDash (revived) — status & component map

Database-agnostic inventory + health monitoring on **DuckLake/S3** (ZSTD Parquet on S3 + PostgreSQL
catalog). SQL Server first; PostgreSQL designed-for-but-deferred.

- **How it works:** [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)
- **Write-method decision + evidence:** [`docs/INGEST-DECISION.md`](INGEST-DECISION.md) · [`bench/results/SCORECARD.md`](../bench/results/SCORECARD.md)
- **Storage acceptance gate:** [`docs/PHASE0-GATE.md`](PHASE0-GATE.md)

## Model (direct-write, two tiers)

```
collectors  ──(query remote DB, stamp integer instance_id, write the result set)──►  DuckLake (PG catalog + S3)  ──►  MCP / scoring views
 (SSPI auth, pooled parallel reads, in-process DuckDB.NET writer)                     common.* / sqlserver.* / postgres.*
```

No file inbox, no separate writer service — the collector commits directly, like the legacy
`SqlBulkCopy`-into-SQL-Server, with the Postgres catalog fronting the transactional load. Keys are
**integers**: `instance_id` from the Postgres registry (IDENTITY) + native `database_id` — no GUIDs.

## Component map

| Path | Role | State |
|---|---|---|
| `lake/ddl/*.sql` | DuckLake schema (`common.*`, `sqlserver.*`), partitioning, threshold seed | ✅ integer-keyed |
| `lake/views/scoring.sql` | scoring view chain (port of `LoadMetricsIntoReportingTAble`) | ✅ parity test passes |
| `lake/registry.sql` + `apply-registry.ps1` | Postgres `registry.instances` (IDENTITY) + fleet seed | ✅ |
| `lake/apply-cloud.ps1` | attach cloud lake (PG catalog + S3) + schema/views + ZSTD (`-Rebuild`) | ✅ |
| `lake/test-scoring.ps1` | repeatable scoring parity test | ✅ |
| `collector/packs/<platform>/` | `collections.json` (emit contract) + `queries/*.sql` | ✅ integer-keyed |
| `bench/` | ingest-method evaluation harness (4 runners + PG/S3 telemetry + scorecard) | ✅ complete |
| `collector/SqlDashCollector.psm1`, `Invoke-Collection.ps1` | legacy inbox collector | ⏳ to be rewritten to direct-write |
| `mcp/` | read-only MCP server over the lake | ✅ integer-keyed |

## What's done vs next

**Done:** integer-key refactor (DDL/views/packs/fixture), cloud lake provisioned + ZSTD, registry seeded,
scoring parity, the storage gate (0 conflicts, ~9.6 commits/sec, 201→1 compaction), and the ingest-method
benchmark (M2 — in-process DuckDB.NET + pooled SSPI — wins; see the decision doc).

**Next:** build the production collector on the winning method (ping-first → pooled SSPI reads → in-process
batched write, inlining/flush tuned), schedule maintenance, then `instance_details`/AlwaysOn/volume +
alerting. The collector packaging (PowerShell-hosting-DuckDB.NET vs a .NET exe) is the open decision in
[`docs/INGEST-DECISION.md`](INGEST-DECISION.md).
