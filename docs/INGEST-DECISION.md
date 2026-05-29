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

## Follow-up implementation plan (production collector)

Builds the winning approach into the real, scheduled collector. Not started — this is the next effort.

1. **Registry/eligibility** — read the fleet from `registry.instances`; **ping-first** every cycle (timed
   connect + `SELECT 1`, 5 s timeout, `response_ms`/`is_success` → `common.pings`); only ping-responsive
   instances proceed to DMV collection. (`common.pings` is a first-class alerting dataset: sustained 5000 ms
   ⇒ offline.)
2. **Collector core** — dot-source `collector/Initialize-SqlDashRuntime.ps1` (proven runtime loader), then
   port `bench/dotnet/Program.cs`'s logic to PowerShell-hosting-DuckDB.NET: pooled MDS SSPI reads via a
   runspace pool at 16–32; one persistent in-process DuckLake connection; Appender → staging → batched
   `INSERT…SELECT`; one commit per large batch. Generic over the pack collectors (instance-level +
   database-level), all six metrics, stamping the integer keys; log to `common.collection_log`/`_errors`.
3. **Maintenance scheduler** — periodic `flush_inlined_data` + compaction (separate from collection; keep it
   single-writer/scheduled, per the gate's note on concurrent compaction).
4. **Config** — `data_inlining_row_limit` + flush-batch size as tunables; default to "inline the hot path,
   bulk-flush on a timer."
5. **Scheduling** — run on a cadence (Task Scheduler / service); per-cycle `collected_at`; jitter tolerated.

## Cleanup

**Done (this spike):**
- ✅ Docs rewritten to the direct-write + integer-key architecture: `docs/ARCHITECTURE.md` (rewritten),
  `docs/NEW-SYSTEM.md` (current-state map), `docs/PHASE0-GATE.md` (historical banner), `README.md`.
- ✅ `mcp/src/server.ts` updated to `instance_id`/`database_id`.
- ✅ `writer/` tier deleted (`ingest.ts` + the S3-inbox concept; `lake/run-gate.ps1` too). `bench/`
  supersedes the gate; `mcp/` stays (read-only consumer). Gate code remains in git history.

**Remaining (folds into the production-collector build):**
- **Rewrite `collector/SqlDashCollector.psm1` + `collector/Invoke-Collection.ps1`** to direct-write; delete
  the UUID helpers (`Get-Uuid5`/`Get-InstanceKey`/`Get-DatabaseKey`), the `dbkey` source, and the
  Parquet-to-inbox path. (Left intact for now so the M2 reference code in `bench/dotnet` is the template.)
- Keep `bench/` as the reproducible evaluation harness (or archive once the production collector lands).

## What this spike already delivered (done)

- Integer-key refactor (drop UUIDs/`source_query_id`; `instance_id` from `registry.instances` IDENTITY +
  native `database_id`) applied to DDL, scoring views, query packs, fixture — **scoring parity test passes**,
  cloud lake re-provisioned, registry seeded (1000 instances).
- `bench/` harness: 4 method runners, PG sampler, S3 counter, scorecard orchestrator — all proven E2E.
- The scorecard + this decision.
