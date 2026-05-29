# SQLDash — Architecture & How It Works

SQLDash is an **agentless, database-agnostic fleet monitor**. It collects inventory and health metrics
from thousands of database instances and lands them in a **DuckLake lakehouse** (ZSTD-compressed Parquet
on S3, metadata in PostgreSQL) where a SQL view chain computes a "problematic instances" health score and
an MCP server exposes it to LLM clients. SQL Server is supported today; PostgreSQL is designed-for.

This document explains the end-to-end collection process, why it is efficient, and how the storage layer
handles large data volumes cheaply. Numbers cited here are **measured** on the local stack (SQL Server
2025 + DuckLake 1.5.3 + S3) — see `bench/results/SCORECARD.md` and `docs/PHASE0-GATE.md`.

> The collector **write method** was chosen by a head-to-head benchmark — see
> [`docs/INGEST-DECISION.md`](INGEST-DECISION.md) and [`bench/results/SCORECARD.md`](../bench/results/SCORECARD.md).

---

## 1. Direct-write, two tiers

```
 COLLECTION (in-process)                         STORAGE (DuckLake)              CONSUMERS
 ───────────────────────                         ──────────────────             ─────────
 agentless collectors                            PostgreSQL catalog             MCP server (TS)
  • Windows-integrated auth (SSPI), no creds     (metadata only)                scoring view chain (SQL)
  • per-platform query packs                     +                              dashboard (planned)
  • pooled parallel reads (16–32)                S3 Parquet (data),
  • integer instance_id stamped in-process       ZSTD, partitioned by
  • writes DIRECTLY into DuckLake (DuckDB.NET) →  platform/year/month/day
        │                                                │                            │
        └──── self-describing rows, key travels ─────────┴──── read-side views (all derived) ──┘
              with the row → dumb append (no ETL)
```

The collector queries the remote DB and **writes the result set straight into DuckLake**, exactly like the
legacy `SqlBulkCopy`-into-SQL-Server — no file inbox, no separate writer service. The **PostgreSQL catalog
fronts the transactional/commit load**; the benchmark proved concurrent appends never conflict (§4), so the
indirection the old design used to avoid commit conflicts was unnecessary. Consumers only *read*.

---

## 2. Collection — step by step

### 2.1 Discovery & eligibility — ping-first
The instance registry (`registry.instances` in Postgres, the IDENTITY source of the integer `instance_id`)
drives the work list. **Every cycle's first interaction with each instance is a timed connection test** —
open + `SELECT 1`, measured in milliseconds, written to `common.pings` with a fixed **5 s** connect timeout
(DMV queries are sub-second, so a timeout surfaces as `response_time_ms = 5000`). Only ping-responsive
instances proceed to DMV collection. `common.pings` is a first-class dataset, not just a heartbeat: creeping
`response_ms` is an early warning, and a run of 5000 ms ⇒ offline — a prime alert condition.

### 2.2 The collector — pooled SSPI reads + in-process DuckLake write
The winning method (M2 in the benchmark) reads each instance with **pooled `Microsoft.Data.SqlClient`**
(`Integrated Security=SSPI` — Kerberos/NTLM, **zero credential handling** on a domain-joined host) across
16–32 parallel workers, then writes via a **single persistent in-process DuckDB.NET connection** (Appender →
staging → batched `INSERT…SELECT`). This was ~3.7–6× faster than the alternatives (DuckDB ODBC fan-out, or
a `duckdb` CLI subprocess per batch) because pooled parallel reads + one long-lived commit connection avoid
per-connection and per-`ATTACH` overhead. The technique can ship as a .NET collector or as PowerShell
hosting the same assemblies (preserving the out-of-the-box SSPI the project relies on).

- **Query packs** (`collector/packs/<platform>/`) define *what* to collect: a logical collector ("CPU",
  "Blocking", "Volume") declared once with a stable name + a `common` target table; each platform pack
  supplies the engine-specific SQL whose output column names match the target columns. Adding a metric is a
  `.sql` file + a JSON entry — no new code.
- **Agentless**: nothing installed on monitored servers — DMV/catalog reads remotely; WMI/WinRM for OS data.

### 2.3 The invariant that makes loading ETL-free
**The instance/database key travels *with* every row.** Each collected row carries a self-describing tuple
— `instance_id`, `platform`, `collected_at` (UTC) — so rows land in the lake **already correctly related**.
Loading is a **dumb append**: no joins, no lookups, no transform step. This is what let the original monitor
scale to thousands of instances with trivial load logic, preserved end-to-end.

### 2.4 Integer keys, stamped in-process (not injected into SQL)
The remote query is **pure platform SQL** — it does not contain the key. The collector stamps the identity
columns onto the result set **after** reading it. (The legacy system string-injected `'@InstanceID'` into
the query text — an escaping/injection hazard and unportable; stamping in-process removes that and works for
SQL Server, PostgreSQL, and WMI alike.) Keys are **integers**: `instance_id` minted by the Postgres registry
(IDENTITY, start 1000, get-or-create on the normalized FQN) and the **native `database_id`** from
`sys.databases`. `instance_id` (+ `database_id`) + `collected_at` is the unique grain — no surrogate GUIDs.

---

## 3. Write path — direct into DuckLake

A single persistent in-process DuckLake connection commits the collected rows. Two levers keep the hot path
cheap (both point the same way — **commit less often, keep the hot path off S3**):

1. **Batch, don't trickle** — commit *large multi-instance batches* (hundreds of instances/commit), not one
   commit per instance. Commit *rate* is the ceiling (§4), so fewer/larger commits = fewer S3 files = faster.
2. **Data inlining** — with `data_inlining_row_limit ≥ per-commit rows`, hot-cycle commits stay in the
   Postgres catalog (**zero S3 PUTs**, ~14× faster in the benchmark); a scheduled
   `ducklake_flush_inlined_data` + compaction rolls them into ZSTD parquet in bulk.

No write-path computation: all derived metrics/scoring are read-side views (§6). The hot path is a pure append.

---

## 4. What makes it efficient

| Design choice | Why it's efficient |
|---|---|
| **Agentless + SSPI auth** | Nothing to install on targets; no credential storage/rotation for the common case. |
| **Key travels with the row** | Loading is a dumb append — **no ETL, no joins** on the write path. |
| **Direct write (no inbox/writer)** | The benchmark disproved the multi-writer-conflict fear, so the file-handoff tier was removed: query → stage in-process → commit, like the legacy bulk load. |
| **Batch, don't trickle** | DuckLake commit throughput is **commit-rate-bound** (~9.6 commits/sec in the gate), so collectors commit *large multi-instance batches*; at ~5.4 bytes/row, hundreds of thousands of rows/sec on one committer — ample for thousands of instances at a 5–15 min cadence. |
| **Data inlining** | Tuning the inlining limit ≥ batch size keeps hot-cycle commits in Postgres → **zero S3 PUTs** on the collection path (~14× faster), with bulk flush to parquet on a timer. |
| **Pooled parallel reads** | `Microsoft.Data.SqlClient` connection pooling + 16–32 parallel workers read 1000 instances ~30× faster than a non-pooled DuckDB ODBC fan-out. |
| **No write-path computation** | The 0–10 IRC health score is computed **read-side** by a SQL view chain, never during write. |
| **Concurrency is a non-issue for appends** | 8 concurrent writers into the same hot partition → **0 serialization conflicts** (gate); every benchmarked method hit 0 conflicts. DuckLake appends create new files, so concurrent appends don't contend. |

---

## 5. Storage — DuckLake on S3, and how it handles large data cheaply

### 5.1 Catalog + data split
DuckLake separates **metadata** from **data**:
- **Catalog (PostgreSQL):** table definitions, snapshots, per-file statistics, partition info, options, and
  *inlined* small-commit rows. Metadata-only — it grows with files/snapshots, not data volume.
- **Data (Parquet on S3):** the actual rows, as immutable ZSTD-compressed Parquet files. S3 is cheap,
  durable, effectively unbounded.

Classic lakehouse storage/compute separation: any number of readers (dashboard, MCP, ad-hoc DuckDB) attach
the catalog and read Parquet directly from S3; storage cost is just S3 $/GB.

### 5.2 ZSTD columnar compression (measured)
Data files are **ZSTD-compressed Parquet** (`parquet_compression='zstd'`, persisted in the catalog — see
`lake/apply-cloud.ps1`). Columnar layout + dictionary encoding + ZSTD is extremely effective on telemetry,
which is highly repetitive per column. **Measured ≈ 5.4 bytes/row** for `metric_cpu` at 1000-instance
cardinality (the UUID-era figure; the integer `instance_id` keys are lower-entropy, so current rows are
smaller still).

**Illustrative scale:** an instance-level metric stream for 5,000 instances at a 5-min cadence is ≈ 1.44M
rows/day ≈ ~7.8 MB/day ≈ ~2.8 GB/year — pennies/month on S3.

### 5.3 Partitioning & pruning
Hot streams are partitioned by `(platform, year, month, day)`, stamped at write. DuckLake records per-file
min/max stats in the catalog, so "last 24h, SQL Server" reads **only the relevant day partitions** — total
lake size doesn't matter. `instance_id` is **not** a partition column (high cardinality → file explosion)
but is kept as a column with catalog stats, so per-instance filters still prune by file.

### 5.4 Small files → compaction (measured)
Frequent small commits create many small Parquet files (the gate produced 201 × ~7 KB). Scheduled
maintenance collapses them cleanly: `ducklake_merge_adjacent_files` → `ducklake_expire_snapshots` →
`ducklake_cleanup_old_files` reduced **201 files (~2 MB) to a single 681 KB file** (and 62→1 in the bench).
The DuckLake equivalent of the legacy partition-management procedures; run it on a schedule, single-writer.

### 5.5 Snapshots, time-travel, schema evolution
Every commit creates a snapshot; readers can query `AT (VERSION => …)` / a point in time. Schema evolves
additively (new nullable columns) without rewriting data — important for the `common` superset as new
platforms contribute columns.

---

## 6. Scoring (read-side)

The "problematic instances" health score is a faithful port of the legacy `LoadMetricsIntoReportingTAble`,
expressed as a DuckLake **SQL view chain** (`lake/views/scoring.sql`): hourly bucketing, CPU = engine+other
sum, inverted PLE bands, LAG-based IO latency deltas with reset/restart-hour guards, blocker-ratio join, all
at per-`(instance_id, database_id, hour)` grain with a worst-database instance rollup. Band-driven by data
in `common.score_thresholds` (a tweak is a row change, not a schema change) and validated by a synthetic
parity test (`lake/test-scoring.ps1` — passes on the integer-keyed schema).

---

## 7. Consumers

- **MCP server** (`mcp/`) — tools for problematic instances, instance detail, metric history, and bounded
  ad-hoc queries over the `common` views, with snapshot/time-travel support.
- **Dashboard** — planned; reads the same views.

All logic lives in read-side views, so new consumers add nothing to the write path.

---

## 8. Multi-platform (schema-per-platform)

- **`common.*`** — cross-platform concepts; rows distinguished by a `platform` column. A *curated additive
  superset* (e.g. `metric_memory.page_residency_seconds` is SQL-only PLE; `buffer_hit_ratio` is PG-only).
- **`sqlserver.*`** — engine-only concepts (AlwaysOn/HADR, mirroring, buffer pool).
- **`postgres.*`** — future, same pattern.

Adding PostgreSQL = a new schema + a query pack whose SQL normalizes into the existing `common` columns;
the dashboard and scoring views are unchanged.

---

## 9. Operations

```powershell
# Cloud lake (PostgreSQL catalog + S3 data, ZSTD, S3 auth via the aws-extension credential_chain)
pwsh lake/apply-cloud.ps1          # provision/attach + schema + views + ZSTD option (-Rebuild to drop+recreate)
pwsh lake/apply-registry.ps1       # Postgres registry.instances (IDENTITY) + fleet seed
pwsh lake/test-scoring.ps1         # scoring parity test

# Ingest-method benchmark (the evidence behind the write-path decision)
pwsh bench/run-bench.ps1 -Methods M1,M2,M3,M4 -FleetLimit 1000 -Compact

# Maintenance (schedule this, single-writer): flush inlined + compact + expire + cleanup
#   CALL ducklake_flush_inlined_data('lake');
#   CALL ducklake_merge_adjacent_files('lake');
#   CALL ducklake_expire_snapshots('lake', older_than => now() - INTERVAL 180 DAY);
#   CALL ducklake_cleanup_old_files('lake', cleanup_all => true);
```

**Evidence:** `bench/results/SCORECARD.md` (4-method comparison; inlining/flush levers); `docs/PHASE0-GATE.md`
(concurrency 0 conflicts, ~9.6 commits/sec, 201→1 compaction); ZSTD ≈ 5.4 bytes/row.
**Next build:** the production collector — see `docs/INGEST-DECISION.md`.
