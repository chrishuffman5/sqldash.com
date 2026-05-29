<#
.SYNOPSIS
  Attach the PRODUCTION DuckLake (PostgreSQL catalog in the local postgres17 container + S3 data path)
  and apply the schema DDL + scoring views. Uses ducklake v1.0+ via DuckDB 1.5.x.
.DESCRIPTION
  Catalog connection comes from the PowerShell Secret vault (Postgres17_ConnectionString); the password
  is passed via PGPASSWORD so it never enters the libpq DSN (avoids backslash/escape issues). S3 access
  uses the AWS credential_chain (~/.aws) — no keys in code.
#>
[CmdletBinding()]
param(
    [string]$CatalogDb  = 'sqldash_catalog',
    [string]$Prefix     = 'sqldash',
    [string]$Region     = 'us-east-1',
    [string]$AwsProfile = 'ducklake',  # bridge profile whose credential_process feeds the SDK chain
    [switch]$Rebuild                   # drop common/sqlserver schemas first (needed when column TYPES change)
)
$ErrorActionPreference = 'Stop'

$cs = Get-Secret Postgres17_ConnectionString -AsPlainText
$kv = @{}; $cs.Split(';') | Where-Object { $_ } | ForEach-Object { $k,$v = $_.Split('=',2); $kv[$k.Trim()] = $v }
$pw = $kv['Password'].Replace('\!','!')   # vault stores it escaped (\!); real TCP/scram password de-escapes the !
$pgconn = "dbname=$CatalogDb host=$($kv['Server']) port=$($kv['Port']) user=$($kv['User Id']) password=$pw"

# S3 auth via the DuckDB `aws` extension credential_chain (CHAIN 'process') — no keys in SQL.
$env:AWS_PROFILE = $AwsProfile
$acct = (aws sts get-caller-identity --query Account --output text | Out-String).Trim()
$dataPath = "s3://sqldash-data-$acct/$Prefix/"
Write-Host "catalog = ducklake:postgres (db=$CatalogDb host=$($kv['Server']))" -ForegroundColor Cyan
Write-Host "data    = $dataPath  (S3 via aws ext credential_chain, profile=$AwsProfile)" -ForegroundColor Cyan

$ddl   = @('00_schemas.sql','10_common.sql','20_sqlserver.sql','30_partition.sql','40_seed.sql' |
    ForEach-Object { Get-Content -Raw (Join-Path $PSScriptRoot "ddl/$_") }) -join "`n"
$views = Get-Content -Raw (Join-Path $PSScriptRoot 'views/scoring.sql')

# Clean rebuild: DROP the schemas so column-type changes (UUID -> INTEGER) take effect, since
# CREATE TABLE IF NOT EXISTS will not alter an existing table. Safe only when the lake is disposable.
$dropSql = ''
if ($Rebuild) {
    Write-Host "rebuild: dropping common + sqlserver schemas first" -ForegroundColor Yellow
    $dropSql = "DROP SCHEMA IF EXISTS common CASCADE; DROP SCHEMA IF EXISTS sqlserver CASCADE;"
}

$sql = @"
INSTALL aws; LOAD aws; INSTALL ducklake; LOAD ducklake; INSTALL postgres; LOAD postgres; INSTALL httpfs; LOAD httpfs;
CREATE OR REPLACE SECRET s3cred (TYPE s3, PROVIDER credential_chain, CHAIN 'process', REGION '$Region');
ATTACH 'ducklake:postgres:$pgconn' AS lake (DATA_PATH '$dataPath');
CALL lake.set_option('parquet_compression', 'zstd');   -- persisted in catalog; all writes ZSTD
USE lake;
$dropSql
$ddl
$views
SELECT table_schema, count(*) AS objects FROM information_schema.tables WHERE table_catalog='lake' GROUP BY table_schema ORDER BY table_schema;
"@
$sql | duckdb
if ($LASTEXITCODE -ne 0) { throw "apply-cloud failed (exit $LASTEXITCODE)" }
Write-Host "Cloud DuckLake ready (Postgres catalog + S3 data)." -ForegroundColor Green
