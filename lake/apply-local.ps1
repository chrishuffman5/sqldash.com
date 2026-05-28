<#
.SYNOPSIS
  Stand up a LOCAL DuckLake (DuckDB-file catalog + local data dir as an S3 stand-in) and apply DDL.
.DESCRIPTION
  For Phase 0 local development only. Production uses a PostgreSQL catalog + S3 DATA_PATH; the DDL
  files themselves are catalog/storage-agnostic, so the same ddl/*.sql apply unchanged there.
#>
[CmdletBinding()]
param(
    [string]$Catalog  = "$PSScriptRoot/local/catalog.ducklake",
    [string]$DataPath = "$PSScriptRoot/local/data"
)
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path (Split-Path $Catalog) | Out-Null
New-Item -ItemType Directory -Force -Path $DataPath | Out-Null

# DuckDB accepts forward slashes on all platforms; normalize to avoid backslash escaping.
$catalogFwd  = ($Catalog  -replace '\\','/')
$dataPathFwd = ($DataPath -replace '\\','/')

$ddlFiles = '00_schemas.sql','10_common.sql','20_sqlserver.sql','30_partition.sql','40_seed.sql'
$ddl = ($ddlFiles | ForEach-Object { Get-Content -Raw (Join-Path $PSScriptRoot "ddl/$_") }) -join "`n"

$sql = @"
INSTALL ducklake; LOAD ducklake; INSTALL httpfs; LOAD httpfs;
ATTACH IF NOT EXISTS 'ducklake:$catalogFwd' AS lake (DATA_PATH '$dataPathFwd');
USE lake;
$ddl
SELECT table_schema, table_name FROM information_schema.tables
WHERE table_catalog = 'lake' ORDER BY table_schema, table_name;
SELECT 'thresholds seeded: ' || count(*)::VARCHAR AS seed_check FROM common.score_thresholds;
"@

$sql | duckdb
if ($LASTEXITCODE -ne 0) { throw "duckdb apply failed (exit $LASTEXITCODE)" }
Write-Host "`nLocal DuckLake ready: catalog=$catalogFwd data=$dataPathFwd" -ForegroundColor Green
