# SQLDash ingest-method evaluation — scorecard & verdict

Head-to-head of four ways to get a remote SQL Server DMV result set directly into DuckLake (no inbox,
no separate writer tier), measured against the **real** stack: DuckDB 1.5.3 + ducklake/postgres/aws/odbc,
a Postgres catalog (`sqldash_bench`) and S3 data (`s3://sqldash-data-…/sqldash-bench/`, ZSTD).

**Fleet model:** the `registry.instances` table seeded with **1000 rows, all `connect_target='localhost'`**
(one SQL Server 2025 Express). Each cycle does a real per-instance connect + DMV read; the registry is the
source of truth (instance_id 1000–1999). Metric = `metric_cpu` (1 row/instance, the hot single-partition case).

The four methods (all write the integer `instance_id` key straight into the lake — dumb append, no ETL):

| | Read path | Write / commit path |
|---|---|---|
| **M1** | DuckDB `odbc` fan-out (one `odbc_connect` per instance, in one process) | in-memory stage → `INSERT` per wave |
| **M2** | Microsoft.Data.SqlClient (SSPI), pooled, `Parallel.ForEach` | in-process **DuckDB.NET** Appender → `INSERT…SELECT` per batch |
| **M3** | Microsoft.Data.SqlClient (SSPI), pooled (PowerShell) | **`duckdb` CLI subprocess** per batch (multi-row `VALUES`) |
| **M4** | DuckDB `odbc` fan-out (same as M1) | **durable local DuckDB stage → `MERGE`** per wave |

## 1. Primary 4-method comparison — 1000 instances, flush 32, threads 24, inlining 10

| Method | elapsed (s) | commits | commits/s | S3 objects (pre-compact) | conflicts | errors | compacted |
|---|--:|--:|--:|--:|--:|--:|--:|
| **M2** ★ | **16.99** | 64 | 3.77 | 62 | 0 | 0 | → 1 file |
| M1 | 63.25 | 32 | 0.51 | 62 | 0 | 0 | → 1 file |
| M4 | 65.85 | 32 | 0.49 | 63 | 0 | 0 | → 1 file |
| M3 | 104.47 | 64 | 0.61 | 62 | 0 | 0 | → 1 file |

All four: **0 commit conflicts, 0 errors, 100% PG cache hit**, identical compacted footprint. The spread is
entirely about *speed*, and it is large: **M2 is 3.7× faster than M1/M4 and 6× faster than M3.**

## 2. Read-bound isolation — M1/M4 fully inlined (≈ no S3 writes), 1000 instances

| Method | inlining | elapsed (s) | S3 objects |
|---|--:|--:|--:|
| M1 | 1000 | 47.05 | 0 |
| M4 | 1000 | 57.88 | 32 |
| M2 | 1000 | **1.48** | 0 |

Removing the S3 write path entirely barely helps M1 (63→47s): the bottleneck is the **DuckDB `odbc`
fan-out read** — a fresh `odbc_connect` per instance (SSPI+TLS handshake, no pooling) that does not
parallelize well inside a single statement. M2's pooled, truly-parallel `Microsoft.Data.SqlClient` reads
do the same 1000 instances ~30× faster. **No storage tuning can rescue the ODBC-fan-out read.**

## 3. S3-PUT lever — inlining sweep (M2, 1000 instances, flush 32, threads 24)

| `data_inlining_row_limit` | elapsed (s) | S3 objects | WAL (MB) |
|---|--:|--:|--:|
| 0 (always parquet) | 18.46 | 64 | 0.21 |
| 10 (default) | 20.71 | 62 | 0.33 |
| **100** | **1.36** | **0** | 0.77 |
| 1000 | 1.48 | 0 | 0.31 |

When the per-commit row count (32) fits under the inlining limit, **every commit stays in the Postgres
catalog — zero S3 PUTs — and the cycle is ~14× faster.** Cost shifts to PG/WAL; data is rolled to ZSTD
parquet later in bulk via `ducklake_flush_inlined_data` + compaction. This is the DuckLake equivalent of
the legacy "one efficient bulk load," and it minimizes S3 API cost on the hot path by construction.

## 4. Flush-batch lever (M2, 1000 instances, threads 24, inlining 10 → forces parquet)

| flush (instances/commit) | elapsed (s) | commits | S3 objects |
|---|--:|--:|--:|
| 32 | 23.09 | 64 | 62 |
| 100 | 6.32 | 20 | 20 |
| 500 | 1.22 | 4 | 4 |

The other lever: **fewer, larger commits → fewer (larger) S3 files → faster.** Commit *rate* is the ceiling
(~3/s here; ~9.6/s in the Phase-0 gate), so the win comes from committing *less often*, not faster.

---

## Verdict

**Winner: M2 — in-process DuckDB.NET writer + pooled Microsoft.Data.SqlClient (SSPI) reader.**

- **Read:** `Microsoft.Data.SqlClient` with connection pooling + real thread parallelism is ~30× faster than
  DuckDB's `odbc` fan-out and gives the same out-of-the-box Windows-integrated auth (SSPI).
- **Write:** a single persistent in-process DuckLake connection (Appender → `INSERT…SELECT`) avoids the
  per-batch `ATTACH` that makes M3 (subprocess) 6× slower, and matches the legacy `SqlBulkCopy` shape.
- **Safety:** 0 conflicts / 0 errors at every setting — concurrency is a non-issue for the append path
  (consistent with the Phase-0 gate's 8-writer / 0-conflict result).
- DuckDB.NET is needed elsewhere anyway, so this consolidates on one engine.

**Recommended settings (both levers point the same way — minimize commit count + keep the hot path off S3):**
- **Large flush batches** (≈250–500 instances/commit), and/or
- **`data_inlining_row_limit` ≥ per-commit rows** so hot-cycle commits inline into Postgres (zero S3 PUTs),
- then **periodic bulk `ducklake_flush_inlined_data` + `merge_adjacent_files` + `expire_snapshots` +
  `cleanup_old_files`** to roll inlined/small files into compacted ZSTD parquet (proven 201→1, 62→1 here).

**Open packaging decision (for the follow-up plan):** M2's *technique* (in-process DuckDB.NET + pooled MDS
SSPI) can be shipped either as a .NET collector exe or as **PowerShell 7 hosting the DuckDB.NET + MDS
assemblies** — the latter preserves the project's "PowerShell collectors" preference with no loss of the
winning performance. Either way, ODBC-in-DuckDB (M1/M4) and the CLI-subprocess (M3) are ruled out.

## Reproduce

```powershell
pwsh lake/apply-registry.ps1                                                   # seed 1000-instance fleet
pwsh bench/run-bench.ps1 -Methods M1,M2,M3,M4 -FleetLimit 1000 -Compact        # primary comparison
pwsh bench/run-bench.ps1 -Methods M2 -Inlining 0,10,100,1000 -Compact          # S3-PUT lever
pwsh bench/run-bench.ps1 -Methods M2 -FlushBatch 32,100,500 -Inlining 10       # flush lever
pwsh bench/run-bench.ps1 -Methods M1,M4 -Inlining 1000                         # read-bound isolation
```
Raw per-cell CSVs: `bench/results/{primary,inlining-sweep,flush-sweep,odbc-readbound}.csv`.

## Caveats

- **Fleet is one localhost SQL Server under 1000 instance_ids**, so per-instance read latency variance and
  WAN-to-S3 latency are *understated*; relative method ranking is robust, absolute seconds are optimistic.
- `peak_active` from the PG sampler reads 0 — DuckLake's catalog commits are too brief for a ~200 ms
  docker-exec poll to catch; commit *counts/WAL* (exact, from `pg_stat_database`) are the reliable signal.
- M1/M4 `response_time_ms` is wave-level (the fan-out can't time per-instance); acceptable under the
  agreed timing tolerance, and moot since M1/M4 lost on the read path anyway.
