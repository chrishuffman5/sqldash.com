#Requires -Version 7.0
<#
.SYNOPSIS
  Register a SQL Server instance in the SQLDash registry (registry.instances) so the collector will
  pick it up. Ensures the registry schema exists (idempotent) and calls registry.get_or_create_instance,
  which mints the integer instance_id (IDENTITY start 1000) or returns the existing one.
.DESCRIPTION
  Uses `docker exec <container> psql` over the container's local socket (trust auth) — the proven path
  for the local postgres17 container in this environment (no password needed; avoids the vault \!-escape
  gotcha). For a remote/RDS catalog, register via your normal psql/migration path instead; the schema +
  function are in lake/registry.sql.

  The registry db defaults to the collector config's catalog.registry_db.
.EXAMPLE
  ./collector/Register-Instance.ps1 -Fqn localhost                       # -> instance_id (e.g. 1000)
  ./collector/Register-Instance.ps1 -Fqn sqlprod01 -ConnectTarget 'sqlprod01,1433' -Environment P
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Fqn,                 # unique identity label (get-or-create key)
    [string]$ConnectTarget,                             # host[,port] to dial (default: = Fqn)
    [string]$InstanceName,
    [string]$Platform     = 'sqlserver',
    [ValidateSet('integrated','sql')][string]$AuthMode = 'integrated',
    [string]$Environment  = 'P',
    [string]$Status       = 'a',
    [string]$Container    = 'postgres17',
    [string]$CatalogDb,                                 # default: config catalog.registry_db
    [string]$ConfigPath   = (Join-Path $PSScriptRoot 'config/collector.json')
)
$ErrorActionPreference = 'Stop'
if (-not $ConnectTarget) { $ConnectTarget = $Fqn }
if (-not $InstanceName)  { $InstanceName  = $Fqn }
if (-not $CatalogDb) {
    $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
    $CatalogDb = $cfg.catalog.registry_db
}

function Invoke-Psql {
    param([string]$Db, [string]$Sql)
    $out = ($Sql | docker exec -i $Container psql -U postgres -d $Db -v ON_ERROR_STOP=1 -tAq 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "psql failed (db=$Db, exit $LASTEXITCODE):`n$out" }
    return $out
}

# 1. ensure registry schema + get-or-create function exist (idempotent)
$registrySql = Get-Content -Raw (Join-Path $PSScriptRoot '../lake/registry.sql')
Invoke-Psql -Db $CatalogDb -Sql $registrySql | Out-Null

# 2. get-or-create — parameters quoted as SQL literals
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$call = "SELECT registry.get_or_create_instance(" +
        ((& $q $Fqn), (& $q $ConnectTarget), (& $q $Platform), (& $q $InstanceName), (& $q $AuthMode), (& $q $Environment), (& $q $Status) -join ', ') +
        ");"
$id = (Invoke-Psql -Db $CatalogDb -Sql $call).Trim()

Write-Host "registered '$Fqn' -> instance_id $id  (connect_target='$ConnectTarget', db=$CatalogDb)" -ForegroundColor Green
$id
