<#
.SYNOPSIS
  Create the bench catalog Postgres database (if missing), apply lake/registry.sql, and seed N
  registry.instances rows that ALL point at the same connect_target (default 'localhost').
.DESCRIPTION
  Uses `docker exec ... psql` over the container's local socket (trust auth) so no password is
  needed and the vault \!-escape gotcha is avoided. The bench fleet is read from this table.
.EXAMPLE
  pwsh lake/apply-registry.ps1                       # 1000 rows -> localhost, db sqldash_bench
  pwsh lake/apply-registry.ps1 -Count 2000 -ConnectTarget 'localhost,14001'
#>
[CmdletBinding()]
param(
    [string]$Container     = 'postgres17',
    [string]$CatalogDb     = 'sqldash_bench',
    [int]   $Count         = 1000,
    [string]$ConnectTarget = 'localhost',
    [string]$Platform      = 'sqlserver'
)
$ErrorActionPreference = 'Stop'

function Invoke-Psql {
    param([string]$Db, [string]$Sql)
    $out = ($Sql | docker exec -i $Container psql -U postgres -d $Db -v ON_ERROR_STOP=1 -tAq 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "psql failed (db=$Db, exit $LASTEXITCODE):`n$out" }
    return $out   # always a string (possibly empty) so callers can .Trim() safely
}

# 1. Create the catalog db if it doesn't exist (CREATE DATABASE can't run inside a txn / IF NOT EXISTS).
$exists = (Invoke-Psql -Db 'postgres' -Sql "SELECT 1 FROM pg_database WHERE datname='$CatalogDb';").Trim()
if ($exists -ne '1') {
    Invoke-Psql -Db 'postgres' -Sql "CREATE DATABASE $CatalogDb;" | Out-Null
    Write-Host "created database $CatalogDb" -ForegroundColor Green
} else {
    Write-Host "database $CatalogDb already exists" -ForegroundColor DarkGray
}

# 2. Apply the registry schema + get-or-create function (idempotent).
$registrySql = Get-Content -Raw (Join-Path $PSScriptRoot 'registry.sql')
Invoke-Psql -Db $CatalogDb -Sql $registrySql | Out-Null
Write-Host "applied registry.sql to $CatalogDb" -ForegroundColor Green

# 3. Seed N rows, all targeting the same connect_target. Distinct instance_fqn keeps the identity
#    space sane; ON CONFLICT DO NOTHING makes re-seeding idempotent.
$seed = @"
INSERT INTO registry.instances (instance_fqn, instance_name, platform, connect_target, auth_mode, environment, status)
SELECT 'bench-' || g, 'bench-' || g, '$Platform', '$ConnectTarget', 'integrated', 'P', 'a'
FROM generate_series(1000, 1000 + $Count - 1) AS g
ON CONFLICT (instance_fqn) DO NOTHING;
"@
Invoke-Psql -Db $CatalogDb -Sql $seed | Out-Null

$total = (Invoke-Psql -Db $CatalogDb -Sql "SELECT count(*) FROM registry.instances WHERE platform='$Platform';").Trim()
$range = (Invoke-Psql -Db $CatalogDb -Sql "SELECT min(instance_id) || '..' || max(instance_id) FROM registry.instances WHERE platform='$Platform';").Trim()
Write-Host "registry.instances ($Platform): $total rows, instance_id $range, connect_target='$ConnectTarget'" -ForegroundColor Cyan
