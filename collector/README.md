# SQLDash collector (direct-write)

Production collector for the DuckDB/DuckLake rebuild. PowerShell 7 hosts **DuckDB.NET** (in-process
DuckLake writer) + **Microsoft.Data.SqlClient** (pooled SSPI reads) — the benchmarked winning ingest
method (M2; see [`../docs/INGEST-DECISION.md`](../docs/INGEST-DECISION.md) and
[`../bench/results/SCORECARD.md`](../bench/results/SCORECARD.md)).

Each cycle the collector reads the fleet from the Postgres **registry**, makes **one timed connect per
instance** (ping-first) reused for every DMV query in the pack, writes `common.pings` (success *and*
failure — the offline signal), then for each collector appends rows to an in-memory stage and flushes
them in batches with a single `INSERT…SELECT` straight into DuckLake. The integer key
(`instance_id` + native `database_id`) travels with every row, so loading is a dumb append — no ETL.

## Layout

| Path | What |
|---|---|
| `Initialize-SqlDashRuntime.ps1` | Dot-source to load DuckDB.NET + MDS into the process (idempotent). |
| `Modules/SqlDashIngest.psm1` | Core: context, lake/registry attach, runspace-pool reads, batched writes, logging, maintenance. |
| `Invoke-Collection.ps1` | Run one collection cycle. |
| `Invoke-Maintenance.ps1` | Flush inlined data + compact (separate schedule). |
| `Register-Instance.ps1` | Register an instance in `registry.instances` (mints `instance_id`). |
| `config/collector.json` | Production config (catalog db, S3, flush/inlining/threads). |
| `config/collector.bench.json` | Smoke-test config (points at the disposable `sqldash_bench` lake). |
| `packs/sqlserver/` | The pack: `collections.json` (emit contracts) + `queries/*.sql` (pure platform SQL). |
| `runtime/` | Deps-only .NET project; `dotnet publish` → `runtime/lib` (gitignored). |
| `Test-Runtime.ps1` | Smoke test for the hosted runtime (DuckDB.NET write + MDS SSPI read). |

## Prerequisites

```powershell
# 1. publish the runtime deps once (restores DuckDB.NET + MDS + native libs into runtime/lib)
dotnet publish collector/runtime -c Release -o collector/runtime/lib
# 2. verify the hosted runtime
pwsh collector/Test-Runtime.ps1
```

The catalog Postgres password comes from the PowerShell Secret vault (`Postgres17_ConnectionString`,
de-escaped for TCP). S3 auth uses the `aws` extension credential_chain via the `ducklake` profile — if
S3 calls 403, the `aws login` session has expired (`aws login`).

## Run

```powershell
# register an instance (get-or-create; mints instance_id)
pwsh collector/Register-Instance.ps1 -Fqn localhost

# preview (no writes): lists collectors + active instance count
pwsh collector/Invoke-Collection.ps1 -WhatIf

# one full cycle, all collectors, all active instances
pwsh collector/Invoke-Collection.ps1

# scope to specific collectors / instances; override read parallelism
pwsh collector/Invoke-Collection.ps1 -CollectorNames metric_cpu,metric_sessions -InstanceIds 1000 -MaxThreads 24

# run only one cadence tier (what Task Scheduler does — see below)
pwsh collector/Invoke-Collection.ps1 -Cadence 5m

# maintenance (flush inlined data to Parquet, then compact) — run on its own schedule
pwsh collector/Invoke-Maintenance.ps1
```

Failures are recorded in the lake (no log file): per-instance/-query errors in `common.collection_errors`,
per-collector summaries in `common.collection_log`, reachability in `common.pings`.

```sql
-- recent failures
SELECT * FROM common.collection_errors ORDER BY collected_at DESC LIMIT 100;
-- unresponsive instances this cycle (offline signal)
SELECT instance_id, response_time_ms FROM common.pings WHERE is_success = false ORDER BY collected_at DESC;
```

## Scheduling (Windows Task Scheduler)

Each collector declares a `cadence` (`5m`/`15m`/`hourly`/`daily`); `-Cadence` runs only that tier, so you
schedule one job per tier. Keep maintenance single-writer and on its own schedule.

```powershell
# one collection job per cadence tier
schtasks /Create /TN "SQLDash\Collect-5m"  /SC MINUTE /MO 5  /RU SYSTEM ^
  /TR "pwsh -NoProfile -File C:\Users\chris\Github\sqldash\collector\Invoke-Collection.ps1 -Cadence 5m"
schtasks /Create /TN "SQLDash\Collect-15m" /SC MINUTE /MO 15 /RU SYSTEM ^
  /TR "pwsh -NoProfile -File C:\Users\chris\Github\sqldash\collector\Invoke-Collection.ps1 -Cadence 15m"
schtasks /Create /TN "SQLDash\Collect-1h"  /SC HOURLY        /RU SYSTEM ^
  /TR "pwsh -NoProfile -File C:\Users\chris\Github\sqldash\collector\Invoke-Collection.ps1 -Cadence hourly"

# hourly maintenance (flush inlined data + compact)
schtasks /Create /TN "SQLDash\Maintain" /SC HOURLY /RU SYSTEM ^
  /TR "pwsh -NoProfile -File C:\Users\chris\Github\sqldash\collector\Invoke-Maintenance.ps1"
```

## Tuning (`config/collector.json` → `ingest`)

| Key | Effect |
|---|---|
| `flush_batch` | Instances per commit. Larger ⇒ fewer/larger Parquet files. |
| `data_inlining_row_limit` | Rows kept inline in Postgres before a Parquet PUT. Set ≥ per-commit rows to keep the **hot collection path off S3** (maintenance flushes later). |
| `read_threads` | Runspace-pool parallelism for SSPI reads (16–32 on a decent host). |
| `ping_timeout_seconds` | Connect + `SELECT 1` timeout; a timeout surfaces as `response_time_ms = timeout×1000`. |

## Configuring collections (add / remove / toggle / re-tier)

Collections are pure config — the `sqlserver` pack is the library; the runner just executes what's enabled.

- **Add**: drop a `queries/<name>.sql` (pure platform SQL — no `@InstanceID`, snake_case aliases matching the
  target columns, native `database_id` for database-level) and add a `collections.json` entry whose `schema`
  lists the target columns in order with each column's `source` (`stamp`/`query`/`const`). Add the target
  table to `lake/ddl/` and re-apply. No PowerShell change.
- **Remove**: delete the `collections.json` entry (and optionally the `.sql`).
- **Disable without deleting**: set `"enabled": false` on the entry (omitted = enabled).
- **Re-tier**: change the entry's `"cadence"` (`5m`/`15m`/`hourly`/`daily`) — the matching `-Cadence`
  scheduled job picks it up. `-CollectorNames` overrides the tier for ad-hoc runs.
