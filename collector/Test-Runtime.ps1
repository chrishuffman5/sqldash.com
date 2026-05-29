#Requires -Version 7.0
<#
.SYNOPSIS  Smoke test: the SqlDash PowerShell runtime hosts DuckDB.NET + Microsoft.Data.SqlClient (SSPI).
           Run after `dotnet publish collector/runtime -c Release -o collector/runtime/lib`.
#>
param([string]$Server = 'localhost')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Initialize-SqlDashRuntime.ps1')

# DuckDB.NET in-process
$cn = [DuckDB.NET.Data.DuckDBConnection]::new('DataSource=:memory:'); $cn.Open()
$cmd = $cn.CreateCommand(); $cmd.CommandText = "SELECT 'duckdb ' || version()"; $v = $cmd.ExecuteScalar(); $cn.Close()
Write-Host "DuckDB.NET: $v" -ForegroundColor Green

# Microsoft.Data.SqlClient SSPI (out-of-box Windows-integrated auth)
$sc = [Microsoft.Data.SqlClient.SqlConnection]::new("Server=$Server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=5")
$sc.Open(); $c = $sc.CreateCommand(); $c.CommandText = 'SELECT @@SERVERNAME'; $srv = $c.ExecuteScalar(); $sc.Close()
Write-Host "Microsoft.Data.SqlClient (SSPI): connected to $srv" -ForegroundColor Green
Write-Host "runtime OK" -ForegroundColor Cyan
