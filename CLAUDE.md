# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

SQLDash is an agentless SQL Server fleet monitor originally built ~10 years ago to watch thousands of
instances in an enterprise. A central Windows box runs PowerShell collectors that query each remote
instance's DMVs, bulk-load the results into a partitioned central SQL Server repository
(`SQLDashRepository`), and a 2-page ASP.NET site surfaces the data: a home dashboard of "problematic
instances" (high CPU, low Page Life Expectancy, or unresponsive) and an InstanceDetails drill-down page.

**Current goal:** revive this concept at much larger scale by replacing the central SQL Server repository
with **DuckDB + DuckLake storing data in S3**. The existing SQL Server collection pipeline is the working
reference design being ported. `PerformanceMonitor/` (see below) is a cloned reference, not part of this build.

## The one architectural idea that makes everything work

**`InstanceID` (called `Instance_ID`, an int identity starting at 1000 in `dbo.Instance`) is embedded into
the remote query text before it runs on the target instance.** The collector reads a `.sql` file, string-
replaces `@InstanceID` with the actual id, runs it on the *remote* instance, and the returned DataTable
already carries `Instance_ID` as its first column. That table is then `SqlBulkCopy`'d straight into the
central repository's matching table. Because the foreign-key value is baked into the result set at the
source, **no separate ETL/transform step is needed** — the relational integrity is correct on arrival.
The same pattern extends to WinRM/WMI collections (e.g. `VolumeCapacity`): the WMI results are turned into
a .NET DataTable with `InstanceID` injected before bulk-load.

Any new collection, new storage backend, or DuckDB/DuckLake port must preserve this invariant: the source
query/result must carry the partitioning/relationship key, so loading is a dumb append with no joins.

## Collection framework: `DashAgent/`

⚠️ **The proven, battle-tested core functionality lives in `DashAgent/archive/`, NOT in
`Start-Collection.ps1`.** The archive README claims these scripts were "replaced by" the v2.0 framework —
that framing is aspirational. In reality:

- **`DashAgent/archive/*.ps1` (~3,300 lines, 9 scripts) are the original production collectors** that ran
  against thousands of instances in the enterprise. This is the working reference implementation. When you
  need to know how collection *actually* works (multithreading, DMV queries, WMI/WinRM volume collection,
  bulk-load, error handling), **read these, not the prototype.**
- **`Start-Collection.ps1` + `Modules/SQLDashCollector.psm1` + `config/*.json` is an untested v2.0
  refactor prototype that has never been run.** It's a cleaner config-driven re-expression of the archived
  logic, but treat it as unproven scaffolding — do not assume it works or matches production behavior.

For the DuckDB/DuckLake port, the archived scripts are the source of truth for *what* and *how* to collect;
the prototype shows the intended *shape* (config-driven, one query per file) but has not been validated.

### Archived production scripts (the real implementation)
- `Run-CommandMultiThreaded.ps1` — the original multithreading framework (runspace orchestration) the
  other collectors build on.
- `InstanceCollectionProd.ps1` (749 lines) — main instance + database collection; the inline DMV queries
  here were the source extracted into `SQL/CollectionQueries/*.sql`.
- `InstanceCollectionDaily.ps1` (1028 lines) / `InstanceCollection_MultiThreadProd.ps1` — daily and
  multithreaded instance-collection orchestrators.
- `PerfMonitoringCollection.ps1` / `PerfMonitoringCollectionSingle.ps1` — performance-metric collectors
  (CPU, PLE, sessions, memory grants, IO).
- `InstanceVolumeCollection.ps1` / `InstanceVolumeCollection_MultiThread.ps1` — disk volume capacity via
  WinRM/WMI, returning a DataTable with `InstanceID` injected.
- `collection_adcomputers.ps1` — AD computer/SPN discovery feeding the `stg.*` staging tables.
- Note: these have hardcoded connection strings that are likely stale — verify before running.

### The v2.0 prototype (untested)
- `Start-Collection.ps1` — entry point; imports the module and calls `Start-SQLDashCollection`.
- `Modules/SQLDashCollector.psm1` — config loading, connection-string building, instance discovery, a
  **runspace pool** (manual multithreading, not `ForEach-Object -Parallel`), bulk-copy, error/ping logging.
- `config/connections.json` — named connections (`CentralRepository`, `CentralRepositoryReadOnly`,
  `TempDB`); connection strings are *built* from these, never hardcoded.
- `config/collections.json` — declarative collections + a `MultiThreading` block. Intent: add a metric by
  adding a `.sql` file + a JSON entry, no new PowerShell.
- `SQL/CollectionQueries/*.sql` — one query per collection, extracted from `InstanceCollectionProd.ps1`.

### How the prototype intends a collection to run (read `Invoke-CollectionItem`)
1. Build target conn string to the remote instance (`server=<FQN>;database=master;Integrated Security=sspi`).
2. If `Condition` is set, check it against `dbo.InstanceDetails` (e.g. only run AlwaysOn collections when
   `IsHadrEnabled = 1`).
3. SQL collection: read the `.sql`, replace `@InstanceID` and `@UTCOFFSET`, run on the remote instance.
   WMI collection (`CollectionType: "WMI"`): open a CIM session to the host, run `WMIQuery`, build a DataTable.
4. If `DeleteBeforeInsert`, run `DeleteQuery` (with `@InstanceID` substituted) on the central repo first.
5. `Invoke-BulkCopy` the DataTable into `TargetTable`; if `HistoryTable` is set, bulk-copy there too.
6. Record an `InstancePing` row (success or failure) and log failures to `dbo.ErrorLogging`.

### Query authoring conventions (enforced by the loader, not validated)
- First column must be `Instance_ID`; include a `collect_dt`/`Date_Entered` timestamp.
- Placeholders `@InstanceID` and `@UTCOFFSET` are string-replaced (not SQL parameters) before execution.
- Branch on `SERVERPROPERTY('productversion')` for cross-version DMV differences (see `InstanceDetails.sql`).

### ⚠️ Known data-quality debt
`DashAgent/DATATYPE-VALIDATION.md` documents real, unfixed mismatches between several `Metrics*.sql`
outputs and their target tables (column-name casing `InstanceID` vs `instance_id`, `SQLCPU` vs
`SQLServerProcessCPUUtilization`, and INT→tinyint / SERVERPROPERTY type issues). `SqlBulkCopy` maps by
column name, so these will silently fail or misload. Verify query output names/types against the table
DDL in `SQL/SQLDashRepository.sql` before trusting any `Metrics*` collection.

## Central repository: `SQL/`

- `SQLDashRepository.sql` / `DBandTables.sql` — full DDL (~3000 lines). Key tables: `Instance` (fleet
  registry), `InstancePing` (heartbeat used for instance discovery), `InstanceDetails`, `Databases`,
  `VolumeCapacity`, the `Metrics*` tables, and `ReportInstanceAllMetrics` (precomputed scoring).
- **Partitioning is central to scale:** time-series tables (`InstancePing`, `VolumeCapacity`,
  `DatabaseLeadBlockers`, `*History`) live on partition schemes `sch_datetime22_daily` /
  `sch_datetime22_12Weeks` keyed on their datetime2(2) collect column. `PartitionMgmt_*` procedures roll
  partitions; `ArchiveMonthOldHistory` ages data out. When porting to DuckLake, this maps to time-based
  Parquet partitioning in S3.
- `views.sql` / `procedures.sql` — the dashboard's logic lives here, not in the web tier. The
  "problematic instances" home page is driven by views like `UnavailableInstances`,
  `vwGetUnavailableInstancesLive`, `vwSQLServerInstanceAllMetrics`, and the `*_Index` scoring columns
  (CPU_Index, PLE_Index, Blocker_Index, …) in `ReportInstanceAllMetrics`, populated by
  `LoadMetricsIntoReportingTAble`. AlwaysOn/mirroring alerting and email rollups are also procedures here.

Discovery query lives in `Get-SQLDashInstances`: it joins `InstancePing` to `Instance`, filters to
active instances pinged within the last N minutes with avg response time under a threshold.

## Web tier: `Web/` (legacy) and `WebModern/` (current)

ASP.NET Web Forms (VB.NET), Windows-auth + LDAP. Two pages: `Default.aspx` (dashboard) and
`InstanceDetails.aspx`, plus `ajax.aspx`/`ajax_reader.aspx` endpoints and a `SideMenuControl` user control.
- `Web/` is the original SmartAdmin-template site.
- `WebModern/` is the in-progress rewrite: same VB code-behind and DB access, but SmartAdmin removed in
  favor of Bootstrap 5 / Chart.js / DataTables (CDN). Prefer `WebModern/` for frontend work.
- `App_Code/DataAccessObject.vb` is the data layer; queries/procs in `SQL/` back the pages.
- DB connection is in `WebModern/web.config` (currently `DESKTOP-NJQ8413` / `SQLDashRepository`, Windows auth).

## Other top-level pieces
- `AWS/`, `Azure/`, `AzureBlob/` — cloud deployment scaffolding (ARM templates, deploy scripts). `awscollection.ps1` / `awsclitohtml.ps1` are AWS inventory collectors that follow the same collect→HTML pattern.
- `SQLBuild/` — scripted SQL Server install/config for standing up a collection/repository host.
- `LoadTable.ps1`, `CreateHtmlFromPSObject.ps1` — standalone bulk-copy and PSObject→HTML helpers (templates, not wired into DashAgent).
- `.github/workflows/terraform.yml` — boilerplate Terraform Cloud workflow; expects a `main.tf` that does not exist yet.

## `PerformanceMonitor/` — reference clone only (gitignored intent)

A cloned copy of a separate project for design reference toward the DuckDB rewrite; **it is untracked and
not part of SQLDash's build — do not modify it.** The relevant part is `PerformanceMonitor/Lite/`, a
.NET 10 WPF desktop app (DuckDB.NET + Microsoft.Data.SqlClient) that does agentless SQL Server monitoring,
stores locally in **DuckDB with Parquet archival**, and exposes an MCP server. Study its
`Lite/Database/DuckDbInitializer.cs`, `Lite/Services/RemoteCollectorService.*` (DMV collectors, one partial
class per metric), `Lite/Services/ArchiveService.cs` and `LocalDataService.*` for patterns to adapt —
especially how it structures DuckDB schema and remote DMV collection.

## Running collections

PowerShell 5.1+ on a Windows host with line-of-sight + auth to the targets and the central repo.

**Proven path:** the archived scripts (`DashAgent/archive/`) are what actually ran in production — e.g.
`.\InstanceCollection_MultiThreadProd.ps1`, `.\PerfMonitoringCollection.ps1`,
`.\InstanceVolumeCollection_MultiThread.ps1`. They have hardcoded (likely stale) connection strings to
fix before use.

**Prototype path (untested — has never been run):** the v2.0 framework from `DashAgent/`:

```powershell
.\Start-Collection.ps1 -WhatIf                                  # preview: lists collections + target instance count
.\Start-Collection.ps1                                          # all enabled collections vs all discovered instances
.\Start-Collection.ps1 -CollectionNames "InstanceDetails"       # one collection
.\Start-Collection.ps1 -InstanceIDs 1001 -Verbose              # single instance, verbose (best for debugging)
.\Start-Collection.ps1 -MaxThreads 20                           # override runspace-pool size (default from config)
```

Test connection-string building without running a collection:
```powershell
Import-Module .\Modules\SQLDashCollector.psm1 -Force
Get-ConnectionString -ConnectionName 'CentralRepository'
```

Check failures (there is no log file — errors go to the repo):
```sql
SELECT TOP 100 * FROM dbo.ErrorLogging ORDER BY DateCreated DESC;
```

There is no build step, test suite, or linter in this repo. The web tier is ASP.NET Web Forms hosted in IIS
(point a site at `WebModern/`); there is no compile/test pipeline checked in for it.
