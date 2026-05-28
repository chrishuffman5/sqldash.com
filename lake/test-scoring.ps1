<#
.SYNOPSIS  Repeatable scoring parity test: builds a throwaway DuckLake, applies DDL + scoring views,
           loads the synthetic fixture, and asserts the computed indices match hand-computed expectations.
#>
[CmdletBinding()]
param([string]$TestRoot = "$PSScriptRoot/local/test")
$ErrorActionPreference = 'Stop'

Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
$catalog = ("$TestRoot/catalog.ducklake" -replace '\\','/')
$data    = ("$TestRoot/data" -replace '\\','/')
New-Item -ItemType Directory -Force -Path $data | Out-Null

$ddl = @('00_schemas.sql','10_common.sql','20_sqlserver.sql','30_partition.sql','40_seed.sql' |
    ForEach-Object { Get-Content -Raw (Join-Path $PSScriptRoot "ddl/$_") }) -join "`n"
$views = Get-Content -Raw (Join-Path $PSScriptRoot 'views/scoring.sql')
$fixture = Get-Content -Raw (Join-Path $PSScriptRoot 'views/_test_scoring_data.sql')

$assert = @"
SELECT '--- v_health_scores (expect H2 irc=2, H3 irc=8) ---' AS section;
SELECT strftime(coll_hr,'%H:%M') AS hr, cpu_index cpu, memory_index mem,
       read_latency_index rl, write_latency_index wl, blocking_index blk, irc_index irc,
       read_latency_ms rl_ms, write_latency_ms wl_ms, round(blocker_ratio,3) ratio
FROM common.v_health_scores ORDER BY coll_hr;
SELECT '--- PARITY ASSERTIONS ---' AS section;
WITH e(coll_hr,cpu,mem,rl,wl,blk,irc) AS (
    VALUES (TIMESTAMP '2026-05-27 11:00:00',1,1,0,0,0,2),
           (TIMESTAMP '2026-05-27 12:00:00',2,2,1,1,2,8)
)
SELECT e.coll_hr,
  CASE WHEN s.cpu_index=e.cpu AND s.memory_index=e.mem AND s.read_latency_index=e.rl
        AND s.write_latency_index=e.wl AND s.blocking_index=e.blk AND s.irc_index=e.irc
       THEN 'PASS' ELSE 'FAIL' END AS result
FROM e LEFT JOIN common.v_health_scores s ON s.coll_hr=e.coll_hr ORDER BY e.coll_hr;
SELECT '--- v_problematic_instances (expect testsrv, is_high_irc, irc=8) ---' AS section;
SELECT instance_fqn, is_unresponsive, is_high_irc, irc_index FROM common.v_problematic_instances;
"@

$sql = @"
INSTALL ducklake; LOAD ducklake;
ATTACH 'ducklake:$catalog' AS lake (DATA_PATH '$data');
USE lake;
$ddl
$views
$fixture
$assert
"@
$sql | duckdb
if ($LASTEXITCODE -ne 0) { throw "scoring test failed (exit $LASTEXITCODE)" }
