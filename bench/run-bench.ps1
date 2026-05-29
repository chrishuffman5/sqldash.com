#Requires -Version 7.0
<#
.SYNOPSIS  Ingest-method bench orchestrator. Runs a matrix of (method x flush-batch x threads x inlining)
           cells against the isolated sqldash_bench DuckLake, capturing Postgres transactional load,
           peak concurrency, and S3 write-PUT counts per cell, and emits a comparable scorecard.
.EXAMPLE
  # full 4-method comparison at the primary settings, with compaction sizing:
  pwsh bench/run-bench.ps1 -Methods M1,M2,M3,M4 -FleetLimit 1000 -FlushBatch 32 -Threads 24 -Inlining 10 -Compact
  # sweep the S3-PUT lever for the leading method:
  pwsh bench/run-bench.ps1 -Methods M1 -Inlining 0,10,100,1000
#>
[CmdletBinding()]
param(
    [string[]]$Methods    = @('M1','M2','M3','M4'),
    [int]     $FleetLimit = 1000,
    [string[]]$FlushBatch = @('32'),
    [string[]]$Threads    = @('24'),
    [string[]]$Inlining   = @('10'),
    [string]  $Metric     = 'metric_cpu',
    [switch]  $Compact,
    [string]  $OutCsv     = "$PSScriptRoot/results/scorecard.csv"
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/bench-common.psm1') -Force

# Normalize array params so they work whether passed in-session (-Inlining 0,10) or via -File (-Inlining "0,10").
function Expand-IntList($a) { ,@($a | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }) }
$Methods    = @($Methods | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$FlushBatch = Expand-IntList $FlushBatch
$Threads    = Expand-IntList $Threads
$Inlining   = Expand-IntList $Inlining

$ctx = Get-BenchContext
$env:SQLDASH_BENCH_PGCONN = $ctx.PgConn
$env:SQLDASH_BENCH_DATA   = $ctx.DataPath
$env:BENCH_METRIC         = $Metric
$env:BENCH_PACK_DIR       = Join-Path $ctx.RepoRoot 'collector/packs/sqlserver'

$fleetCsv = Join-Path $env:TEMP 'bench-fleet.csv'
$n = Get-BenchFleet -Ctx $ctx -Limit $FleetLimit -OutCsv $fleetCsv
$env:BENCH_FLEET_CSV = $fleetCsv
Write-Host "fleet: $n instances (metric=$Metric); lake=$($ctx.DataPath)" -ForegroundColor Cyan

$m2exe = Join-Path $PSScriptRoot 'dotnet/bin/Release/net8.0/m2.exe'

function Invoke-Method([string]$M) {
    switch ($M) {
        'M1' { Push-Location $PSScriptRoot; try { $o = (npm run --silent m1 2>&1 | Out-String) } finally { Pop-Location } }
        'M4' { Push-Location $PSScriptRoot; try { $o = (npm run --silent m4 2>&1 | Out-String) } finally { Pop-Location } }
        'M2' { $o = (& $m2exe 2>&1 | Out-String) }
        'M3' { $o = (pwsh -NoProfile -File (Join-Path $PSScriptRoot 'm3-cli.ps1') 2>&1 | Out-String) }
        default { throw "unknown method $M" }
    }
    $line = ($o -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { throw "method $M produced no JSON line. Raw output:`n$o" }
    return ($line | ConvertFrom-Json)
}

function Get-DockerStat {
    $s = (docker stats --no-stream --format '{{.CPUPerc}};{{.MemUsage}}' $ctx.Container 2>$null | Out-String).Trim()
    $p = $s -split ';'
    [pscustomobject]@{ cpu = ($p[0] -replace '%',''); mem = (($p[1] -split '/')[0]).Trim() }
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($method in $Methods) {
  foreach ($inl in $Inlining) {
    foreach ($fl in $FlushBatch) {
      foreach ($th in $Threads) {
        Write-Host ("`n=== {0}  flush={1} threads={2} inlining={3} ===" -f $method,$fl,$th,$inl) -ForegroundColor Yellow
        Reset-BenchLake -Ctx $ctx -InliningRowLimit $inl
        $env:BENCH_FLUSH_BATCH = "$fl"; $env:BENCH_THREADS = "$th"

        $pgBefore = Get-PgSnapshot -Ctx $ctx
        $s3Before = Get-S3Stats -Ctx $ctx

        # background Postgres sampler (stop-file controlled)
        $stop = Join-Path $env:TEMP ("bench-stop-{0}-{1}-{2}-{3}.flag" -f $method,$fl,$th,$inl)
        Remove-Item $stop -ErrorAction SilentlyContinue
        $samp = Join-Path $env:TEMP ("bench-samp-{0}-{1}-{2}-{3}.csv" -f $method,$fl,$th,$inl)
        $proc = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile','-File',(Join-Path $PSScriptRoot 'pg-sampler.ps1'),
            '-Container',$ctx.Container,'-Database',$ctx.CatalogDb,'-OutCsv',$samp,'-StopFile',$stop)

        $r = Invoke-Method $method

        $dock = Get-DockerStat                       # near-peak point sample
        'stop' | Set-Content $stop
        $proc.WaitForExit(8000) | Out-Null
        Remove-Item $stop -ErrorAction SilentlyContinue

        $pgAfter = Get-PgSnapshot -Ctx $ctx
        $delta   = Get-PgDelta -Before $pgBefore -After $pgAfter
        $s3After = Get-S3Stats -Ctx $ctx

        # peaks from the sampler csv
        $peakA=0; $peakI=0; $peakL=0; $peakT=0.0
        if (Test-Path $samp) {
            Import-Csv $samp | ForEach-Object {
                $peakA=[math]::Max($peakA,[int]$_.active); $peakI=[math]::Max($peakI,[int]$_.idle_in_txn)
                $peakL=[math]::Max($peakL,[int]$_.lock_waiters); $peakT=[math]::Max($peakT,[double]$_.longest_txn_sec)
            }
        }

        $s3Comp = $null
        if ($Compact) { $s3Comp = Invoke-BenchMaintenance -Ctx $ctx }

        $row = [pscustomobject]@{
            method=$method; metric=$Metric; instances=$r.instances
            flush=$fl; threads=$th; inlining=$inl
            elapsed_sec=$r.elapsed_sec; commits=$r.commits; commits_per_sec=$r.commits_per_sec
            rows=$r.rows_written; rows_per_sec=$r.rows_per_sec; ping_rows=$r.ping_rows
            conflicts=$r.conflicts; errors=$r.errors
            pg_commits=$delta.commits; pg_tup_ins=$delta.tup_inserted
            wal_mb=[math]::Round($delta.wal_bytes/1MB,2); cache_hit_pct=$delta.cache_hit_pct; deadlocks=$delta.deadlocks
            peak_active=$peakA; peak_idle_txn=$peakI; peak_lock_waits=$peakL; longest_txn_sec=$peakT
            s3_objects=$s3After.objects; s3_mb=[math]::Round($s3After.bytes/1MB,3)
            s3_obj_compacted=($s3Comp.objects); s3_mb_compacted=$(if($s3Comp){[math]::Round($s3Comp.bytes/1MB,3)}else{$null})
            pg_cpu_pct=$dock.cpu; pg_mem=$dock.mem
        }
        $rows.Add($row)
        Write-Host ("  -> {0}s  commits={1} ({2}/s)  rows={3}  conflicts={4} errors={5}  s3_obj={6}  peak_active={7}  wal={8}MB" -f `
            $r.elapsed_sec,$r.commits,$r.commits_per_sec,$r.rows_written,$r.conflicts,$r.errors,$s3After.objects,$peakA,$row.wal_mb) -ForegroundColor Green
      }
    }
  }
}

New-Item -ItemType Directory -Force -Path (Split-Path $OutCsv) | Out-Null
$rows | Export-Csv -NoTypeInformation -Path $OutCsv
Write-Host "`nscorecard -> $OutCsv" -ForegroundColor Cyan
$rows | Format-Table method,flush,threads,inlining,elapsed_sec,commits_per_sec,rows_per_sec,conflicts,errors,s3_objects,peak_active,wal_mb,cache_hit_pct -AutoSize
