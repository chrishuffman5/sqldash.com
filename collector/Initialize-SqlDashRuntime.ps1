#Requires -Version 7.0
<#
.SYNOPSIS
  Load DuckDB.NET + Microsoft.Data.SqlClient into the current PowerShell 7 process so the collector can
  write to DuckLake and read SQL Server (SSPI) IN-PROCESS — the benchmarked winning ingest method (M2),
  packaged as PowerShell-hosts-the-assemblies. Dot-source this file; it is idempotent.
.DESCRIPTION
  Deps come from collector/runtime/lib (publish once):
      dotnet publish collector/runtime -c Release -o collector/runtime/lib
  Proven gotchas baked in:
   • the native dir (runtimes/win-x64/native) is prepended to PATH so P/Invoke of duckdb.dll / MDS SNI resolves;
   • Microsoft.Data.SqlClient is loaded from runtimes/win/lib/net8.0 — the root DLL is a platform-agnostic
     facade that throws "Microsoft.Data.SqlClient is not supported on this platform".
.PARAMETER DepsDir
  Override the published deps directory (default: collector/runtime/lib).
.EXAMPLE
  . ./collector/Initialize-SqlDashRuntime.ps1
  $cn = [DuckDB.NET.Data.DuckDBConnection]::new('DataSource=:memory:'); $cn.Open()
#>
[CmdletBinding()]
param([string]$DepsDir = (Join-Path $PSScriptRoot 'runtime/lib'))

$loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'DuckDB.NET.Data' }
if ($loaded) { Write-Verbose 'SqlDash runtime already loaded'; return }

if (-not (Test-Path (Join-Path $DepsDir 'DuckDB.NET.Data.dll'))) {
    throw "runtime deps not found in '$DepsDir'. Build them once: dotnet publish collector/runtime -c Release -o collector/runtime/lib"
}

$nat = Join-Path $DepsDir 'runtimes/win-x64/native'
if (Test-Path $nat) { $env:PATH = "$nat;$DepsDir;$env:PATH" }

foreach ($dll in 'DuckDB.NET.Bindings.dll', 'DuckDB.NET.Data.dll') {
    [Reflection.Assembly]::LoadFrom((Join-Path $DepsDir $dll)) | Out-Null
}
$mds = Join-Path $DepsDir 'runtimes/win/lib/net8.0/Microsoft.Data.SqlClient.dll'   # Windows impl, not the facade
if (-not (Test-Path $mds)) { $mds = Join-Path $DepsDir 'Microsoft.Data.SqlClient.dll' }
[Reflection.Assembly]::LoadFrom($mds) | Out-Null

Write-Verbose "SqlDash runtime loaded from $DepsDir"
