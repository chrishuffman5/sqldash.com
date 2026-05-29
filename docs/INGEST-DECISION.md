# Ingest-method decision & follow-up plan

> Outcome of the ingest-method evaluation spike (`bench/`). Full data: [`bench/results/SCORECARD.md`](../bench/results/SCORECARD.md).

## Decision

Collectors write the result set **directly into DuckLake** (no S3 inbox, no separate writer tier), carrying
the integer `instance_id` (+ native `database_id`) key so loading is a dumb append. Of the four write
methods benchmarked head-to-head at 1000 instances against the real Postgres-catalog + S3 stack:

**✅ Adopt M2 — in-process DuckDB.NET writer + pooled Microsoft.Data.SqlClient (SSPI) reader.**

| Method | 1000-instance cycle | Why ruled out |
|---|--:|---|
| **M2 (DuckDB.NET in-process)** | **17.0 s** (1.4 s fully-inlined) | — *winner* |
| M1 (DuckDB `odbc` fan-out → INSERT) | 63 s | read-bound: per-instance `odbc_connect`, no pooling, doesn't parallelize |
| M4 (DuckDB `odbc` fan-out → MERGE) | 66 s | same ODBC read bottleneck; MERGE adds no benefit on append-only data |
| M3 (PowerShell + `duckdb` CLI subprocess) | 104 s | `ATTACH`-per-batch subprocess overhead |

All methods hit **0 commit conflicts / 0 errors** — concurrency is a non-issue for the append path (matches
the Phase-0 gate). The differentiator is pure throughput, and M2 wins by 3.7–6×. M2 also keeps the
out-of-the-box Windows-integrated auth (MDS SSPI) the project requires, and consolidates on DuckDB.NET
(needed elsewhere anyway).

### Recommended settings (minimize commit count + keep the hot path off S3)
- **Large flush batches** (~250–500 instances/commit) — fewer, larger parquet files; *and/or*
- **`data_inlining_row_limit` ≥ per-commit rows** so hot-cycle commits inline into Postgres → **zero S3
  PUTs** on the collection path (measured ~14× faster: 1.36 s vs 18.5 s for 1000 instances).
- **Scheduled maintenance** rolls inlined/small files into compacted ZSTD parquet:
  `ducklake_flush_inlined_data` → `merge_adjacent_files` → `expire_snapshots` → `cleanup_old_files`
  (proven 62→1 and 201→1 file collapse).

## Packaging decision (made)

M2's *technique* is engine-bound (DuckDB.NET + MDS), not language-bound. **Chosen: PowerShell 7 hosts the
DuckDB.NET + Microsoft.Data.SqlClient assemblies** — preserves the project's "PowerShell collectors"
preference and out-of-box SSPI, with the same in-process performance as the .NET bench (same libraries).
The production collector loads the two assemblies (+ their native libs: `duckdb.dll`, MDS SNI) from a
restored/published deps folder, uses a runspace pool for the parallel SSPI reads, and a single persistent
DuckDB.NET connection for the batched writes. (The `bench/dotnet` M2 runner is the reference implementation.)

**De-risked + foundation built.** PowerShell 7 hosting is proven: `collector/Initialize-SqlDashRuntime.ps1`
(dot-source to load the assemblies) + `collector/runtime/` (deps-only project; `dotnet publish` →
`collector/runtime/lib`) + `collector/Test-Runtime.ps1` (smoke test). Verified: DuckDB.NET writes to the
cloud lake and MDS reads localhost via SSPI, both in one pwsh process. Gotchas baked into the loader:
prepend `runtimes/win-x64/native` to PATH; load MDS from `runtimes/win/lib/net8.0` (the root DLL is a
platform-agnostic facade that throws "not supported on this platform").

## Follow-up implementation plan (production collector) — ✅ BUILT

The winning approach is now implemented as the real collector in [`collector/`](../collector/README.md)
and verified end-to-end (one cycle, all 8 collectors, 3 localhost instances → lake; flush+compact →
ZSTD Parquet on S3 → read back). What landed:

1. ✅ **Registry/eligibility** — fleet read from `registry.instances` (via the DuckDB postgres ATTACH, no
   psql dependency); **ping-first** each cycle (timed connect + `SELECT 1`, configurable timeout) writes
   `common.pings` for **every** instance — success AND failure rows (the offline signal). One connect per
   instance is reused for all DMV queries in the pack.
2. ✅ **Collector core** (`Modules/SqlDashIngest.psm1`) — dot-sources `Initialize-SqlDashRuntime.ps1`, then
   does pooled MDS SSPI reads via a **runspace pool** (each runspace LoadFrom's MDS so the type resolves)
   and a **single persistent in-process DuckLake connection**; per collector: Appender → in-memory `stg`
   → one `INSERT…SELECT` per flush batch. Generic over the pack (instance- and database-level), stamps the
   integer keys, syncs `common.instances` from the registry, logs to `common.collection_log`/`_errors`.
   Now **8 collectors**: the 6 metrics + `instance_details` + AlwaysOn `ha_databases`.
3. ✅ **Maintenance** (`Invoke-Maintenance.ps1`) — `flush_inlined_data` → `merge_adjacent_files` →
   `expire_snapshots` → `cleanup_old_files`; run on its own single-writer schedule.
4. ✅ **Config** (`config/collector.json`) — `flush_batch`, `data_inlining_row_limit`, `read_threads`,
   `ping_timeout_seconds` as tunables; default = inline the hot path, bulk-flush on the maintenance timer.
5. ✅ **Scheduling** — `schtasks` recipes for collect (5 min) + maintain (hourly) documented in the
   collector README (not auto-created).

**Remaining (future):** volume capacity (WinRM/WMI — different collection mechanism, not a SQL query);
SQL-auth instances (vault-backed UID/PWD; only integrated/SSPI wired today); alerting/email rollups; and
combining the per-collector read fan-out further if connect cost ever dominates.

## Cleanup

**Done (this spike):**
- ✅ Docs rewritten to the direct-write + integer-key architecture: `docs/ARCHITECTURE.md` (rewritten),
  `docs/NEW-SYSTEM.md` (current-state map), `docs/PHASE0-GATE.md` (historical banner), `README.md`.
- ✅ `mcp/src/server.ts` updated to `instance_id`/`database_id`.
- ✅ `writer/` tier deleted (`ingest.ts` + the S3-inbox concept; `lake/run-gate.ps1` too). `bench/`
  supersedes the gate; `mcp/` stays (read-only consumer). Gate code remains in git history.

**Done (production-collector build):**
- ✅ **Deleted `collector/SqlDashCollector.psm1`** (UUID helpers `Get-Uuid5`/`Get-InstanceKey`/
  `Get-DatabaseKey`, the `dbkey` source, and the Parquet-to-inbox path) and **rewrote
  `collector/Invoke-Collection.ps1`** to direct-write via the new `Modules/SqlDashIngest.psm1`.

**Remaining:**
- Keep `bench/` as the reproducible evaluation harness (or archive now that the production collector lands).

## What this spike already delivered (done)

- Integer-key refactor (drop UUIDs/`source_query_id`; `instance_id` from `registry.instances` IDENTITY +
  native `database_id`) applied to DDL, scoring views, query packs, fixture — **scoring parity test passes**,
  cloud lake re-provisioned, registry seeded (1000 instances).
- `bench/` harness: 4 method runners, PG sampler, S3 counter, scorecard orchestrator — all proven E2E.
- The scorecard + this decision.
