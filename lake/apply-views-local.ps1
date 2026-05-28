<#
.SYNOPSIS  Apply the scoring view chain (lake/views/scoring.sql) to the local DuckLake.
#>
[CmdletBinding()]
param(
    [string]$Catalog  = "$PSScriptRoot/local/catalog.ducklake",
    [string]$DataPath = "$PSScriptRoot/local/data"
)
$ErrorActionPreference = 'Stop'
$catalogFwd  = ((Resolve-Path $Catalog).Path  -replace '\\','/')
$dataPathFwd = ((Resolve-Path $DataPath).Path -replace '\\','/')
$views = Get-Content -Raw (Join-Path $PSScriptRoot 'views/scoring.sql')

$sql = @"
INSTALL ducklake; LOAD ducklake; INSTALL httpfs; LOAD httpfs;
ATTACH 'ducklake:$catalogFwd' AS lake (DATA_PATH '$dataPathFwd');
USE lake;
$views
SELECT 'views applied: ' || count(*)::VARCHAR FROM information_schema.tables
WHERE table_catalog='lake' AND table_name LIKE 'v_%';
"@
$sql | duckdb
if ($LASTEXITCODE -ne 0) { throw "apply views failed (exit $LASTEXITCODE)" }
Write-Host "Scoring views applied." -ForegroundColor Green
