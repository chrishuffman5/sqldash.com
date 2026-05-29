<#
.SYNOPSIS  Run the Phase 0 concurrency/throughput gate against the cloud DuckLake (PG catalog + S3),
           reporting S3 file count/size before and after the run (+ compaction inside the gate).
#>
[CmdletBinding()]
param([int]$Writers = 8, [int]$Rounds = 25, [int]$Batch = 500, [string]$CatalogDb = 'sqldash_catalog')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Postgres catalog DSN (de-escaped password)
$cs = Get-Secret Postgres17_ConnectionString -AsPlainText
$kv = @{}; $cs.Split(';') | Where-Object { $_ } | ForEach-Object { $k,$v = $_.Split('=',2); $kv[$k.Trim()] = $v }
$pw = $kv['Password'].Replace('\!','!')
$env:SQLDASH_PGCONN = "dbname=$CatalogDb host=$($kv['Server']) port=$($kv['Port']) user=$($kv['User Id']) password=$pw"

# S3 auth via the aws extension credential_chain (CHAIN 'process' resolves the ducklake bridge profile)
$env:AWS_PROFILE = 'ducklake'
$env:AWS_REGION  = 'us-east-1'
$acct = (aws sts get-caller-identity --query Account --output text | Out-String).Trim()
$env:SQLDASH_DATA = "s3://sqldash-data-$acct/sqldash/"
$env:GATE_WRITERS = "$Writers"; $env:GATE_ROUNDS = "$Rounds"; $env:GATE_BATCH = "$Batch"

function Show-S3([string]$label) {
    $out = (aws s3 ls $env:SQLDASH_DATA --recursive --summarize 2>$null | Out-String)
    $sum = ($out -split "`n" | Where-Object { $_ -match 'Total Objects|Total Size' }) -join '  '
    Write-Host "S3 $label : $sum" -ForegroundColor DarkGray
}

Show-S3 'BEFORE'
Push-Location (Join-Path $root 'writer')
try { npm run --silent gate } finally { Pop-Location }
Show-S3 'AFTER'

# per-file sizes for the metric_cpu partition (capture fully first to avoid pipe-stop)
$cpu = (aws s3 ls $env:SQLDASH_DATA --recursive 2>$null | Out-String) -split "`n" | Where-Object { $_ -match 'metric_cpu' }
Write-Host "metric_cpu parquet files: $($cpu.Count)"
$cpu | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }
