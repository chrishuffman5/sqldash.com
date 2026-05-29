#Requires -Version 7.0
<#
  SQLDash ingest-method bench — shared helpers.

  Isolation model: the entire spike lives in a dedicated, disposable Postgres database `sqldash_bench`
  (holds BOTH the registry.instances fleet AND the DuckLake catalog) + a dedicated S3 prefix
  `s3://sqldash-data-<acct>/sqldash-bench/`. Reset PURGES the S3 prefix so each cell starts at zero
  objects -> "S3 objects after a run" == the cell's write-PUT count (clean, deterministic).

  Postgres password: de-escaped from the vault (\!-> !) for TCP/scram; docker-exec psql uses the local
  socket (trust) so it needs no password. S3 auth: the `aws` extension credential_chain (CHAIN 'process')
  resolving the ~/.aws `ducklake` bridge profile — no keys in code.
#>

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # bench/lib -> bench -> repo

function Get-BenchContext {
    [CmdletBinding()]
    param(
        [string]$Container = 'postgres17',
        [string]$CatalogDb = 'sqldash_bench',
        [string]$Region    = 'us-east-1',
        [string]$Profile   = 'ducklake',
        [string]$PgHost    = 'localhost',
        [int]   $PgPort    = 5432
    )
    # de-escaped Postgres password for TCP (DuckDB/DuckLake connect over scram)
    $cs = Get-Secret Postgres17_ConnectionString -AsPlainText
    $kv = @{}; $cs.Split(';') | Where-Object { $_ } | ForEach-Object { $k,$v = $_.Split('=',2); $kv[$k.Trim()] = $v }
    $pw = $kv['Password'].Replace('\!','!')

    $env:AWS_PROFILE = $Profile
    $env:AWS_REGION  = $Region
    $acct = (aws sts get-caller-identity --query Account --output text | Out-String).Trim()
    if (-not $acct) { throw "aws sts get-caller-identity returned nothing — is the aws login session live? (run: aws login)" }

    [pscustomobject]@{
        Container = $Container
        CatalogDb = $CatalogDb
        Region    = $Region
        Profile   = $Profile
        Account   = $acct
        PgConn    = "dbname=$CatalogDb host=$PgHost port=$PgPort user=$($kv['User Id']) password=$pw"
        DataPath  = "s3://sqldash-data-$acct/sqldash-bench/"
        RepoRoot  = $script:RepoRoot
    }
}

function Get-BenchAttachSql {
    <# The canonical lake-attach preamble. -Odbc adds the odbc extension (M1/M4). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [switch]$Odbc)
    $odbcLoad = if ($Odbc) { 'INSTALL odbc; LOAD odbc;' } else { '' }
    @"
INSTALL aws; LOAD aws; INSTALL ducklake; LOAD ducklake; INSTALL postgres; LOAD postgres; INSTALL httpfs; LOAD httpfs; $odbcLoad
CREATE OR REPLACE SECRET s3cred (TYPE s3, PROVIDER credential_chain, CHAIN 'process', REGION '$($Ctx.Region)');
ATTACH 'ducklake:postgres:$($Ctx.PgConn)' AS lake (DATA_PATH '$($Ctx.DataPath)');
USE lake;
"@
}

function Invoke-BenchDuckdb {
    <# Pipe a SQL script to the duckdb CLI; throw on non-zero exit; return stdout as a string. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sql, [switch]$Json)
    $args = @(); if ($Json) { $args += '-json' }
    $out = ($Sql | duckdb @args 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "duckdb failed (exit $LASTEXITCODE):`n$out" }
    return $out
}

function Invoke-BenchPsql {
    <# Run SQL against a Postgres db over the container local socket (trust). Returns stdout string. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [string]$Database, [Parameter(Mandatory)][string]$Sql, [string]$Sep = '|')
    if (-not $Database) { $Database = $Ctx.CatalogDb }
    $out = ($Sql | docker exec -i $Ctx.Container psql -U postgres -d $Database -v ON_ERROR_STOP=1 -tAq -F $Sep 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "psql failed (db=$Database, exit $LASTEXITCODE):`n$out" }
    return $out
}

function Clear-BenchS3Prefix {
    <# Purge the bench S3 prefix so the next cell starts at zero objects. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx)
    $null = (aws s3 rm $Ctx.DataPath --recursive 2>&1 | Out-String)   # ok if already empty
}

function Reset-BenchLake {
    <#
    .SYNOPSIS Fresh, empty bench lake for one matrix cell: DROP+CREATE the schema, set ZSTD +
              data_inlining_row_limit, then PURGE the S3 prefix so file counts start at zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Ctx,
        [int]$InliningRowLimit = 10,
        [switch]$WithViews
    )
    $ddlFiles = '00_schemas.sql','10_common.sql','20_sqlserver.sql','30_partition.sql','40_seed.sql'
    $ddl = ($ddlFiles | ForEach-Object { Get-Content -Raw (Join-Path $Ctx.RepoRoot "lake/ddl/$_") }) -join "`n"
    $views = if ($WithViews) { Get-Content -Raw (Join-Path $Ctx.RepoRoot 'lake/views/scoring.sql') } else { '' }

    $sql = (Get-BenchAttachSql -Ctx $Ctx) + @"
DROP SCHEMA IF EXISTS common CASCADE;
DROP SCHEMA IF EXISTS sqlserver CASCADE;
$ddl
$views
CALL lake.set_option('parquet_compression', 'zstd');
CALL lake.set_option('data_inlining_row_limit', '$InliningRowLimit');
SELECT 'inlining=' || value AS opt FROM ducklake_options('lake') WHERE option_name = 'data_inlining_row_limit';
"@
    $null = Invoke-BenchDuckdb -Sql $sql
    Clear-BenchS3Prefix -Ctx $Ctx          # remove parquet orphaned by the DROP
}

function Get-BenchFleet {
    <# Read the fleet from registry.instances into a CSV (instance_id,connect_target). Returns the count. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [int]$Limit = 1000, [Parameter(Mandatory)][string]$OutCsv)
    $rows = Invoke-BenchPsql -Ctx $Ctx -Sql @"
SELECT instance_id, connect_target FROM registry.instances
WHERE platform='sqlserver' ORDER BY instance_id LIMIT $Limit;
"@ -Sep ','
    $lines = @('instance_id,connect_target') + ($rows -split "`r?`n" | Where-Object { $_ -ne '' })
    [System.IO.File]::WriteAllLines($OutCsv, $lines)
    return ($lines.Count - 1)
}

function Get-PgSnapshot {
    <# Point-in-time cumulative counters for the catalog db + cluster WAL position (bytes). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx)
    $db = $Ctx.CatalogDb
    $row = (Invoke-BenchPsql -Ctx $Ctx -Sql @"
SELECT
  d.xact_commit, d.xact_rollback, d.tup_inserted, d.tup_updated, d.tup_deleted,
  d.blks_read, d.blks_hit, d.deadlocks, d.temp_files, d.temp_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint AS wal_bytes
FROM pg_stat_database d WHERE d.datname='$db';
"@).Trim()
    $f = $row -split '\|'
    [pscustomobject]@{
        xact_commit=[int64]$f[0]; xact_rollback=[int64]$f[1]; tup_inserted=[int64]$f[2]
        tup_updated=[int64]$f[3]; tup_deleted=[int64]$f[4]; blks_read=[int64]$f[5]
        blks_hit=[int64]$f[6]; deadlocks=[int64]$f[7]; temp_files=[int64]$f[8]
        temp_bytes=[int64]$f[9]; wal_bytes=[int64]$f[10]
    }
}

function Get-PgDelta {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $readsHits = ($After.blks_read - $Before.blks_read) + ($After.blks_hit - $Before.blks_hit)
    $cacheHit = if ($readsHits -gt 0) { [math]::Round((($After.blks_hit - $Before.blks_hit) / $readsHits) * 100, 1) } else { 100.0 }
    [pscustomobject]@{
        commits      = $After.xact_commit  - $Before.xact_commit
        rollbacks    = $After.xact_rollback - $Before.xact_rollback
        tup_inserted = $After.tup_inserted - $Before.tup_inserted
        deadlocks    = $After.deadlocks    - $Before.deadlocks
        temp_bytes   = $After.temp_bytes   - $Before.temp_bytes
        wal_bytes    = $After.wal_bytes    - $Before.wal_bytes
        cache_hit_pct = $cacheHit
    }
}

function Get-S3Stats {
    <# Object count + total bytes under the bench prefix (write-PUT proxy when reset starts at zero). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [string]$SubPath = '')
    $path = $Ctx.DataPath + $SubPath
    $out = (aws s3 ls $path --recursive --summarize 2>&1 | Out-String)
    $objects = 0; $bytes = 0
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match 'Total Objects:\s*(\d+)') { $objects = [int]$Matches[1] }
        if ($line -match 'Total Size:\s*(\d+)')    { $bytes   = [int64]$Matches[1] }
    }
    [pscustomobject]@{ objects = $objects; bytes = $bytes }
}

function Invoke-BenchMaintenance {
    <# Compact: merge adjacent files -> expire snapshots -> cleanup old files. Returns post-S3 stats. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx)
    $sql = (Get-BenchAttachSql -Ctx $Ctx) + @"
CALL ducklake_merge_adjacent_files('lake');
CALL ducklake_expire_snapshots('lake', older_than => now());
CALL ducklake_cleanup_old_files('lake', cleanup_all => true);
"@
    $null = Invoke-BenchDuckdb -Sql $sql
    return (Get-S3Stats -Ctx $Ctx)
}

Export-ModuleMember -Function Get-BenchContext, Get-BenchAttachSql, Invoke-BenchDuckdb, Invoke-BenchPsql,
    Clear-BenchS3Prefix, Reset-BenchLake, Get-BenchFleet, Get-PgSnapshot, Get-PgDelta, Get-S3Stats, Invoke-BenchMaintenance
