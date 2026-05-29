#Requires -Version 7.0
<#
.SYNOPSIS
  Run one SQLDash collection cycle: ping-first the fleet, then write every pack collector's rows
  DIRECTLY into DuckLake (DuckDB.NET in-process writer + pooled Microsoft.Data.SqlClient SSPI reads).
  This is the production direct-write collector (benchmarked method M2 — see docs/INGEST-DECISION.md).
.DESCRIPTION
  Per cycle: read the fleet from registry.instances -> one timed connect per instance (reused for all
  DMV queries) via a runspace pool -> write common.pings (success + failure) -> per collector, append
  rows to an in-memory stage and flush in batches with one INSERT...SELECT into the lake -> log
  summaries to common.collection_log and per-instance failures to common.collection_errors.
.EXAMPLE
  ./collector/Invoke-Collection.ps1 -WhatIf
  ./collector/Invoke-Collection.ps1 -InstanceIds 1000 -CollectorNames metric_cpu
  ./collector/Invoke-Collection.ps1 -ConfigPath ./collector/config/collector.bench.json   # smoke test
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config/collector.json'),
    [string]$Pack       = 'sqlserver',
    [string[]]$CollectorNames,        # explicit subset of collectors to run (overrides -Cadence)
    [string[]]$Cadence,               # run only collectors with these cadences (e.g. 5m,15m); default: all enabled. One Task Scheduler job per tier.
    [int[]]$InstanceIds,              # subset of registry instance_ids (default: all active)
    [int]$MaxThreads,                 # override read parallelism (default: config ingest.read_threads)
    [string]$CatalogDb,               # override catalog/registry db (e.g. point at the bench db)
    [string]$DataPrefix,              # override S3 data prefix
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Initialize-SqlDashRuntime.ps1')          # load DuckDB.NET + MDS into this process
Import-Module (Join-Path $PSScriptRoot 'Modules/SqlDashIngest.psm1') -Force

$ctx   = Get-CollectorContext -ConfigPath $ConfigPath -CatalogDb $CatalogDb -DataPrefix $DataPrefix
$cfg   = $ctx.Config
$flush = [int]$cfg.ingest.flush_batch
$inline= [int]$cfg.ingest.data_inlining_row_limit
$threads = if ($MaxThreads) { $MaxThreads } else { [int]$cfg.ingest.read_threads }
$pingTimeout = [int]$cfg.ingest.ping_timeout_seconds

# --- load the pack + the collectors to run -----------------------------------------------------
$packDir  = Join-Path $PSScriptRoot "packs/$Pack"
$manifest = Get-Content -Raw (Join-Path $packDir 'collections.json') | ConvertFrom-Json
$collectors = @($manifest.collectors)
# enabled flag (default true when omitted) — disable a collection without deleting its file/entry
$collectors = @($collectors | Where-Object { $null -eq $_.enabled -or $_.enabled })
# selection: explicit -CollectorNames wins; else optional -Cadence tier (one Task Scheduler job per tier)
if     ($CollectorNames) { $collectors = @($collectors | Where-Object { $_.name -in $CollectorNames }) }
elseif ($Cadence)        { $collectors = @($collectors | Where-Object { $_.cadence -in $Cadence }) }
if ($collectors.Count -eq 0) { throw "no collectors selected (pack=$Pack; check enabled / -CollectorNames / -Cadence)" }

# read defs passed into the runspace pool (name + SQL text + timeout only — not the full schema)
$readDefs = @(foreach ($c in $collectors) {
    [pscustomobject]@{ name = $c.name; sql = (Get-Content -Raw (Join-Path $packDir $c.query)).Trim().TrimEnd(';'); timeout = [int]$c.timeout_seconds }
})

Write-Host "SQLDash collection — pack=$Pack  catalog=$($cfg.catalog.catalog_db)  data=$($ctx.DataPath)" -ForegroundColor Cyan
Write-Host "  collectors: $($collectors.name -join ', ')" -ForegroundColor DarkGray
Write-Host "  flush=$flush  inlining=$inline  threads=$threads  ping_timeout=${pingTimeout}s" -ForegroundColor DarkGray

$conn = Open-Lake -Ctx $ctx -InliningRowLimit $inline
try {
    Sync-InstanceDimension -Conn $conn
    $fleet = @(Get-Fleet -Conn $conn -Platform $Pack -InstanceIds $InstanceIds)
    Write-Host "  fleet: $($fleet.Count) active instance(s)" -ForegroundColor DarkGray

    if ($WhatIf) {
        Write-Host "`n[WhatIf] would ping $($fleet.Count) instance(s) and run $($collectors.Count) collector(s); no writes." -ForegroundColor Yellow
        return
    }
    if ($fleet.Count -eq 0) { Write-Warning 'no active instances in the registry — nothing to collect.'; return }

    # one collected_at per cycle (jitter across instances is acceptable)
    $nowUtc = [datetime]::UtcNow
    $stamp  = [pscustomobject]@{
        platform = $Pack; collected_at = $nowUtc.ToString('yyyy-MM-dd HH:mm:ss')
        year = [int]$nowUtc.Year; month = [int]$nowUtc.Month; day = [int]$nowUtc.Day
    }

    $cycleSw = [System.Diagnostics.Stopwatch]::StartNew()

    # --- 1. parallel reads (ping + all DMV queries, one connect each) --------------------------
    $results = @(Invoke-FleetRead -Fleet $fleet -Collectors $readDefs -Threads $threads -PingTimeout $pingTimeout -MdsPath $ctx.MdsPath)
    $responsive = @($results | Where-Object { $_.ping_ok }).Count
    Write-Host "  read: $responsive/$($results.Count) responsive" -ForegroundColor DarkGray

    # --- 2. pings (success + failure) ----------------------------------------------------------
    $ping = Write-Pings -Conn $conn -Results $results -Stamp $stamp -Flush $flush

    # --- 3. per-collector batched writes -------------------------------------------------------
    $logRows = [System.Collections.Generic.List[object]]::new()
    $writeStats = foreach ($c in $collectors) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $w  = Write-Collector -Conn $conn -Collector $c -Results $results -Stamp $stamp -Flush $flush
        $sw.Stop()
        $status = if ($w.errors -gt 0) { 'error' } elseif ($w.rows -eq 0) { 'empty' } else { 'ok' }
        $logRows.Add(@{ collector = $c.name; rows = $w.rows; duration_ms = [int]$sw.Elapsed.TotalMilliseconds; status = $status })
        $w
    }

    # --- 4. logging: per-collector summaries + per-instance failures ---------------------------
    $errRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $results) {
        if ($r.error) {
            $errRows.Add(@{ instance_id = $r.id; instance_fqn = $r.fqn; collector = $null; error_type = 'connect'; error_message = $r.error })
        } else {
            foreach ($c in $collectors) {
                $cr = $r.results[$c.name]
                if ($cr -and $cr.error) { $errRows.Add(@{ instance_id = $r.id; instance_fqn = $r.fqn; collector = $c.name; error_type = 'query'; error_message = $cr.error }) }
            }
        }
    }
    Write-CollectionLog    -Conn $conn -LogRows $logRows -Stamp $stamp
    Write-CollectionErrors -Conn $conn -ErrorRows $errRows -Stamp $stamp

    $cycleSw.Stop()

    # --- summary -------------------------------------------------------------------------------
    Write-Host "`nResults  (cycle $([math]::Round($cycleSw.Elapsed.TotalSeconds,2))s, collected_at $($stamp.collected_at) UTC):" -ForegroundColor Cyan
    Write-Host ("  {0,-22} {1,-6} rows={2,-6} commits={3}" -f 'pings', $(if ($ping.errors) {'error'} else {'ok'}), $ping.rows, $ping.commits) -ForegroundColor $(if ($ping.errors){'Red'}else{'Green'})
    foreach ($w in $writeStats) {
        $status = if ($w.errors -gt 0) { 'error' } elseif ($w.rows -eq 0) { 'empty' } else { 'ok' }
        $color  = switch ($status) { 'ok' {'Green'} 'empty' {'Yellow'} default {'Red'} }
        Write-Host ("  {0,-22} {1,-6} rows={2,-6} commits={3} inst={4} {5}" -f $w.collector, $status, $w.rows, $w.commits, $w.instances, $w.last_error) -ForegroundColor $color
    }
    if ($errRows.Count) { Write-Host "  $($errRows.Count) instance/query error(s) -> common.collection_errors" -ForegroundColor Yellow }

    if (($writeStats | Where-Object { $_.errors -gt 0 }) -or $ping.errors) { exit 1 }
}
finally { $conn.Close(); $conn.Dispose() }
