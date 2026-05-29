#Requires -Version 7.0
<#
.SYNOPSIS
  DuckLake maintenance for SQLDash: flush inlined data to Parquet, then compact (merge adjacent files ->
  expire snapshots -> cleanup old files). Run on a SEPARATE, single-writer schedule from collection.
.DESCRIPTION
  The collection hot path inlines small commits into the Postgres catalog (data_inlining_row_limit) so it
  never touches S3. This job rolls that inlined data + any small files into compacted ZSTD Parquet
  (proven 201->1 file collapse). Keep it single-writer/scheduled — do not run concurrently with itself.
.EXAMPLE
  ./collector/Invoke-Maintenance.ps1
  ./collector/Invoke-Maintenance.ps1 -ConfigPath ./collector/config/collector.bench.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config/collector.json'),
    [string]$CatalogDb,
    [string]$DataPrefix
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Initialize-SqlDashRuntime.ps1')
Import-Module (Join-Path $PSScriptRoot 'Modules/SqlDashIngest.psm1') -Force

$ctx = Get-CollectorContext -ConfigPath $ConfigPath -CatalogDb $CatalogDb -DataPrefix $DataPrefix
Write-Host "SQLDash maintenance — catalog=$($ctx.Config.catalog.catalog_db)  data=$($ctx.DataPath)" -ForegroundColor Cyan

$conn = Open-Lake -Ctx $ctx
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-LakeMaintenance -Conn $conn
    $sw.Stop()
    Write-Host "maintenance complete ($([math]::Round($sw.Elapsed.TotalSeconds,2))s): flushed inlined data + compacted." -ForegroundColor Green
}
finally { $conn.Close(); $conn.Dispose() }
