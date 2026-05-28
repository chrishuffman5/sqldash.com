#Requires -Version 7.0
<#
.SYNOPSIS
  Phase 0 collection runner. Registers the target instance and runs a pack's instance-level
  collectors against it via Windows-integrated auth, emitting typed Parquet to the inbox.
.EXAMPLE
  ./collector/Invoke-Collection.ps1 -Server localhost
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Pack = 'sqlserver',
    [string[]]$CollectorNames,
    [string]$InboxRoot = "$PSScriptRoot/../lake/local/inbox",
    [string]$NodeId = $env:COMPUTERNAME
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/SqlDashCollector.psm1" -Force

$platform = 'sqlserver'
$fqn = $Server.ToLowerInvariant()
$instanceKey = Get-InstanceKey -Platform $platform -Fqn $fqn
$connStr = New-SqlConnectionString -Server $Server
$now = [datetime]::UtcNow

Write-Host "Instance: $fqn  key=$instanceKey  node=$NodeId" -ForegroundColor Cyan

# --- Register instance (get-or-create is idempotent: deterministic key; writer upserts) ---
$instSchema = @(
    @{ name='instance_key'; type='UUID' },    @{ name='instance_fqn'; type='VARCHAR' }
    @{ name='instance_name'; type='VARCHAR' }, @{ name='platform'; type='VARCHAR' }
    @{ name='environment'; type='VARCHAR' },   @{ name='status'; type='VARCHAR' }
    @{ name='category'; type='VARCHAR' },       @{ name='engine_version'; type='VARCHAR' }
    @{ name='is_clustered'; type='BOOLEAN' },   @{ name='dmz'; type='BOOLEAN' }
    @{ name='domain'; type='VARCHAR' },         @{ name='auth_mode'; type='VARCHAR' }
    @{ name='registered_at'; type='TIMESTAMP' },@{ name='updated_at'; type='TIMESTAMP' }
)
$ver = (Invoke-SqlQuery -ConnectionString $connStr -Query "SELECT CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(32)) AS v").Rows[0].v
$instRow = ,@($instanceKey, $fqn, $Server, $platform, 'P', 'a', $null, $ver, $false, $false, $null, 'integrated', $now, $now)
$instDir = Join-Path (Join-Path $InboxRoot $NodeId) 'common.instances'
New-Item -ItemType Directory -Force -Path $instDir | Out-Null
Write-TypedParquet -Rows $instRow -Schema $instSchema -OutPath (Join-Path $instDir ('{0}-reg.parquet' -f $now.ToString('yyyyMMddTHHmmssfff')))
Write-Host "  registered (v$ver)" -ForegroundColor DarkGray

# --- Run collectors ---
# NB: $Pack is a [string]-constrained param; reusing that name for the parsed object would coerce
# it back to a string. Use a distinct variable for the manifest.
$packDir = Join-Path $PSScriptRoot "packs/$Pack"
$manifest = Get-Content -Raw (Join-Path $packDir 'collections.json') | ConvertFrom-Json
$collectors = $manifest.collectors   # instance- and database-level (schema sources drive behavior)
if ($CollectorNames) { $collectors = $collectors | Where-Object { $_.name -in $CollectorNames } }

$results = foreach ($c in $collectors) {
    Invoke-Collector -Collector $c -PackDir $packDir -Platform $platform -Fqn $fqn `
        -InstanceKey $instanceKey -ConnectionString $connStr -InboxRoot $InboxRoot -NodeId $NodeId
}

Write-Host "`nResults:"
foreach ($r in @($results)) {
    $color = switch ($r.status) { 'ok' {'Green'} 'empty' {'Yellow'} default {'Red'} }
    Write-Host ("  {0,-20} {1,-6} rows={2} {3}" -f $r.collector, $r.status, $r.rows, $r.error) -ForegroundColor $color
}

if (@($results).status -contains 'error') { exit 1 }
