#Requires -Version 7.0
<#
  SQLDash direct-write ingest module (production collector core).

  Implements the benchmarked winning method (M2 — see docs/INGEST-DECISION.md): PowerShell 7 hosts
  Microsoft.Data.SqlClient (pooled SSPI reads) + DuckDB.NET (one persistent in-process connection that
  writes straight into DuckLake). No S3 inbox, no separate writer tier. The integer key travels with
  every row (instance_id from the Postgres registry, native database_id from sys.databases), so loading
  is a dumb append — exactly the legacy SqlBulkCopy-into-SQL-Server pattern.

  Per cycle:
    1. ONE timed connect per instance (ping-first) reused for ALL the pack's DMV queries  -> runspace pool
    2. write common.pings (success AND failure rows — the offline-detection dataset)
    3. per collector: Appender -> in-memory stg -> ONE INSERT...SELECT per flush batch into the lake
    4. log per-collector summaries to common.collection_log; per-instance failures to common.collection_errors

  The two engine assemblies must already be loaded into the process (dot-source
  collector/Initialize-SqlDashRuntime.ps1 before importing this module). Reads run in runspace-pool
  runspaces that share this process's AppDomain; each read runspace also LoadFrom's MDS by absolute path
  so the type resolves regardless of AppDomain fallback behavior.
#>

# ------------------------------------------------------------------------------------------------
# Per-instance read scriptblock (runs in a pool runspace). Returns ONE pscustomobject per instance:
#   { id; fqn; ping_ms; ping_ok; error; results = @{ <collector> = @{ rows=@(<hashtable>); error } } }
# One connect, ping (timed SELECT 1), then every collector query reusing the connection.
# ------------------------------------------------------------------------------------------------
$script:ReadScriptText = @'
param($Inst, $Collectors, $PingTimeout, $MdsPath)
[void][Reflection.Assembly]::LoadFrom($MdsPath)   # idempotent; guarantees the MDS type resolves in this runspace
# Build via SqlConnectionStringBuilder so connect_target is an OPAQUE DataSource value — a ';' or '=' in it
# cannot inject connection-string keywords (it is operator-supplied via the registry).
$b = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
$b['Data Source'] = [string]$Inst.connect_target
$b['Initial Catalog'] = 'master'
$b['Integrated Security'] = $true
$b['TrustServerCertificate'] = $true
$b['Connect Timeout'] = [int]$PingTimeout
$b['Application Name'] = 'SqlDashCollector'
$cs = $b.ConnectionString
$res = [ordered]@{ id = [int]$Inst.instance_id; fqn = [string]$Inst.connect_target; ping_ms = ([int]$PingTimeout * 1000); ping_ok = $false; error = $null; results = @{} }
$conn = $null
try {
    $conn = [Microsoft.Data.SqlClient.SqlConnection]::new($cs)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $conn.Open()
    $pc = $conn.CreateCommand(); $pc.CommandText = 'SELECT 1'; $pc.CommandTimeout = $PingTimeout; [void]$pc.ExecuteScalar(); $pc.Dispose()
    $sw.Stop(); $res.ping_ms = [int]$sw.ElapsedMilliseconds; $res.ping_ok = $true
    foreach ($c in $Collectors) {
        $cr = @{ rows = @(); error = $null }
        try {
            $cmd = $conn.CreateCommand(); $cmd.CommandText = $c.sql; $cmd.CommandTimeout = [int]$c.timeout
            $rdr = $cmd.ExecuteReader()
            $fc = $rdr.FieldCount
            $names = New-Object string[] $fc
            for ($i = 0; $i -lt $fc; $i++) { $names[$i] = $rdr.GetName($i) }
            $rows = [System.Collections.Generic.List[hashtable]]::new()
            while ($rdr.Read()) {
                $h = @{}
                for ($i = 0; $i -lt $fc; $i++) { $v = $rdr.GetValue($i); if ($v -is [System.DBNull]) { $h[$names[$i]] = $null } else { $h[$names[$i]] = $v } }
                $rows.Add($h)
            }
            $rdr.Close(); $rdr.Dispose(); $cmd.Dispose()
            $cr.rows = $rows.ToArray()
        } catch { $cr.error = $_.Exception.Message }
        $res.results[$c.name] = $cr
    }
} catch { $res.error = $_.Exception.Message }
finally { if ($conn) { $conn.Dispose() } }
[pscustomobject]$res
'@

# ------------------------------------------------------------------------------------------------
# Context / connections
# ------------------------------------------------------------------------------------------------
function Get-CollectorContext {
    <#
    .SYNOPSIS Build the runtime context from config: de-escaped Postgres conn (catalog + registry),
              S3 data path (s3://<bucket_prefix>-<account>/<data_prefix>/), AWS profile/region, MDS path.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'collector.json'),
        [string]$CatalogDb,        # overrides config (e.g. point the smoke test at the bench db)
        [string]$DataPrefix
    )
    $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
    if ($CatalogDb)  { $cfg.catalog.catalog_db = $CatalogDb; $cfg.catalog.registry_db = $CatalogDb }
    if ($DataPrefix) { $cfg.s3.data_prefix = $DataPrefix }

    # Postgres password: the vault stores it escaped (\!). TCP/scram needs it de-escaped. It is passed to
    # libpq via the PGPASSWORD env var (NOT interpolated into the DSN / ATTACH literal) so a space, single
    # quote, or backslash in the password can't break the connection string or escape the SQL literal.
    $cs = Get-Secret $cfg.catalog.secret_name -AsPlainText
    $kv = @{}; $cs.Split(';') | Where-Object { $_ } | ForEach-Object { $k, $v = $_.Split('=', 2); $kv[$k.Trim()] = $v }
    $pw = $kv['Password'].Replace('\!', '!')
    $pgHost = $kv['Server']; $pgPort = $kv['Port']; $pgUser = $kv['User Id']
    $env:PGPASSWORD = $pw

    # S3 auth via the aws extension credential_chain; need the account for the bucket name.
    $env:AWS_PROFILE = $cfg.s3.aws_profile
    $env:AWS_REGION  = $cfg.s3.region
    $acct = (aws sts get-caller-identity --query Account --output text | Out-String).Trim()
    if (-not $acct) { throw "aws sts get-caller-identity returned nothing — is the aws login session live? (run: aws login)" }

    $depsDir = (Resolve-Path (Join-Path $PSScriptRoot '..' 'runtime' 'lib')).Path
    $mds = Join-Path $depsDir 'runtimes/win/lib/net8.0/Microsoft.Data.SqlClient.dll'
    if (-not (Test-Path $mds)) { $mds = Join-Path $depsDir 'Microsoft.Data.SqlClient.dll' }

    [pscustomobject]@{
        Config       = $cfg
        Platform     = $cfg.pack
        Region       = $cfg.s3.region
        Account      = $acct
        CatalogConn  = "dbname=$($cfg.catalog.catalog_db) host=$pgHost port=$pgPort user=$pgUser"   # password via PGPASSWORD
        RegistryConn = "dbname=$($cfg.catalog.registry_db) host=$pgHost port=$pgPort user=$pgUser"
        DataPath     = "s3://$($cfg.s3.bucket_prefix)-$acct/$($cfg.s3.data_prefix)/"
        MdsPath      = $mds
        DepsDir      = $depsDir
    }
}

function Open-Lake {
    <#
    .SYNOPSIS Open the single persistent DuckDB.NET connection: attach the DuckLake (PG catalog + S3),
              attach the registry Postgres db read-only as `reg`, set ZSTD + inlining. Returns the conn.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ctx, [int]$InliningRowLimit = 500)
    $conn = [DuckDB.NET.Data.DuckDBConnection]::new('DataSource=:memory:')
    $conn.Open()
    Invoke-LakeExec $conn 'INSTALL aws; LOAD aws; INSTALL ducklake; LOAD ducklake; INSTALL postgres; LOAD postgres; INSTALL httpfs; LOAD httpfs;'
    Invoke-LakeExec $conn "CREATE OR REPLACE SECRET s3cred (TYPE s3, PROVIDER credential_chain, CHAIN 'process', REGION '$($Ctx.Region)');"
    Invoke-LakeExec $conn "ATTACH 'ducklake:postgres:$($Ctx.CatalogConn)' AS lake (DATA_PATH '$($Ctx.DataPath)');"
    Invoke-LakeExec $conn "ATTACH '$($Ctx.RegistryConn)' AS reg (TYPE postgres, READ_ONLY);"
    Invoke-LakeExec $conn "CALL lake.set_option('parquet_compression', 'zstd');"
    Invoke-LakeExec $conn "CALL lake.set_option('data_inlining_row_limit', '$InliningRowLimit');"
    return $conn
}

function Invoke-LakeExec {
    [CmdletBinding()] param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$Sql)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql
    try { [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() }
}

function Invoke-LakeReader {
    <# Run a SELECT, return rows as pscustomobject[] (DBNull -> $null). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][string]$Sql)
    $cmd = $Conn.CreateCommand(); $cmd.CommandText = $Sql
    $rdr = $cmd.ExecuteReader()
    try {
        $fc = $rdr.FieldCount
        $names = New-Object string[] $fc
        for ($i = 0; $i -lt $fc; $i++) { $names[$i] = $rdr.GetName($i) }
        $out = [System.Collections.Generic.List[object]]::new()
        while ($rdr.Read()) {
            $h = [ordered]@{}
            for ($i = 0; $i -lt $fc; $i++) { $v = $rdr.GetValue($i); $h[$names[$i]] = $(if ($v -is [System.DBNull]) { $null } else { $v }) }
            $out.Add([pscustomobject]$h)
        }
        return $out.ToArray()   # emit rows individually; callers normalize with @()
    } finally { $rdr.Dispose(); $cmd.Dispose() }
}

# ------------------------------------------------------------------------------------------------
# Registry / fleet
# ------------------------------------------------------------------------------------------------
function Sync-InstanceDimension {
    <# Best-effort UPSERT of the lake's common.instances dimension from the registry source of truth:
       delete the registry's instance_ids then re-insert all, so mutable columns (status, environment,
       instance_name, auth_mode, connect-driven fields) stay in sync — not insert-once. engine_version /
       is_clustered / category are left NULL here; the instance_details collector populates the richer
       per-snapshot detail in common.instance_details. The dimension is small (one row per instance), so a
       delete+reinsert each cycle is cheap (inlined in the catalog). #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Conn)
    $sql = @'
DELETE FROM lake.common.instances WHERE instance_id IN (SELECT instance_id FROM reg.registry.instances);
INSERT INTO lake.common.instances
    (instance_id, instance_fqn, instance_name, platform, environment, status, auth_mode, registered_at, updated_at)
SELECT r.instance_id, r.instance_fqn, r.instance_name, r.platform, r.environment, r.status, r.auth_mode,
       r.registered_at::TIMESTAMP, r.updated_at::TIMESTAMP
FROM reg.registry.instances r;
'@
    try { Invoke-LakeExec $Conn $sql } catch { Write-Warning "Sync-InstanceDimension: $($_.Exception.Message)" }
}

function Get-Fleet {
    <# Read active instances from registry.instances (the operational source of truth). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Conn, [string]$Platform = 'sqlserver', [int[]]$InstanceIds, [int]$Limit = 100000)
    $where = "WHERE status = 'a' AND platform = $(ConvertTo-SqlLiteral $Platform)"
    if ($InstanceIds) { $where += ' AND instance_id IN (' + ($InstanceIds -join ',') + ')' }
    Invoke-LakeReader $Conn "SELECT instance_id, connect_target, auth_mode, platform FROM reg.registry.instances $where ORDER BY instance_id LIMIT $Limit;"
}

# ------------------------------------------------------------------------------------------------
# Parallel reads (runspace pool — shared in-process AppDomain)
# ------------------------------------------------------------------------------------------------
function Invoke-FleetRead {
    <#
    .SYNOPSIS Fan the per-instance read (ping + all collector queries) across a runspace pool.
    .PARAMETER Collectors  Array of @{ name; sql; timeout } (NOT the full pack def).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Fleet,
        [Parameter(Mandatory)]$Collectors,
        [int]$Threads = 24,
        [int]$PingTimeout = 5,
        [Parameter(Mandatory)][string]$MdsPath
    )
    $pool = [runspacefactory]::CreateRunspacePool(1, $Threads)
    $pool.Open()
    try {
        $jobs = foreach ($inst in $Fleet) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($script:ReadScriptText).AddArgument($inst).AddArgument($Collectors).AddArgument($PingTimeout).AddArgument($MdsPath)
            [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }
        $out = foreach ($j in $jobs) {
            try { $r = $j.PS.EndInvoke($j.Handle); foreach ($x in $r) { $x } }
            catch { Write-Warning "read runspace failed: $($_.Exception.Message)" }
            finally { $j.PS.Dispose() }
        }
    } finally { $pool.Close(); $pool.Dispose() }
    @($out)   # emit results individually; caller normalizes with @()
}

# ------------------------------------------------------------------------------------------------
# Write helpers
# ------------------------------------------------------------------------------------------------
function ConvertTo-SqlLiteral {
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return 'NULL' }
    if ($Value -is [bool])     { return $(if ($Value) { 'TRUE' } else { 'FALSE' }) }
    if ($Value -is [datetime]) { return "TIMESTAMP '" + ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss.fff') + "'" }
    if ($Value -is [string])   { return "'" + ($Value -replace "'", "''") + "'" }
    return [string]$Value   # numerics
}

function Add-AppendedValue {
    <# Append one value to a DuckDB appender row, coercing to the stg column's DuckDB type. #>
    param($Ar, [string]$Type, $Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { [void]$Ar.AppendNullValue(); return }
    $t = $Type.ToUpperInvariant()
    # Coerce to the column's EXACT native CLR type so a checked .NET conversion THROWS on overflow
    # (caught by the per-chunk catch in Write-Collector) instead of the appender silently wrapping the
    # value. DuckDB TINYINT is signed -> [sbyte] (the appender rejects [byte] for TINYINT).
    if     ($t -like 'TINYINT*')   { [void]$Ar.AppendValue([sbyte][Convert]::ToSByte($Value)) }
    elseif ($t -like 'SMALLINT*')  { [void]$Ar.AppendValue([int16][Convert]::ToInt16($Value)) }
    elseif ($t -like 'INTEGER*')   { [void]$Ar.AppendValue([int][Convert]::ToInt32($Value)) }
    elseif ($t -like 'BIGINT*')    { [void]$Ar.AppendValue([long][Convert]::ToInt64($Value)) }
    elseif ($t -like 'BOOLEAN*')   { [void]$Ar.AppendValue([bool][Convert]::ToBoolean($Value)) }
    elseif ($t -like 'TIMESTAMP*') { [void]$Ar.AppendValue([datetime][Convert]::ToDateTime($Value)) }
    elseif ($t -like 'DECIMAL*' -or $t -like 'DOUBLE*') { [void]$Ar.AppendValue([decimal][Convert]::ToDecimal($Value)) }
    else { [void]$Ar.AppendValue([string][Convert]::ToString($Value)) }
}

function Get-ColExpr {
    <# SELECT expression for one target column when inserting from the stg table. #>
    param($Col, $Stamp)
    switch ($Col.source) {
        'query' { return 'stg."' + $Col.name + '"' }
        'const' {
            if ($Col.PSObject.Properties['const'] -and $null -ne $Col.const) { return (ConvertTo-SqlLiteral $Col.const) }
            return 'NULL'
        }
        'stamp' {
            switch ($Col.name) {
                'instance_id'  { return 'stg.instance_id' }
                'platform'     { return (ConvertTo-SqlLiteral $Stamp.platform) }
                'collected_at' { return "TIMESTAMP '" + $Stamp.collected_at + "'" }
                'year'         { return [string]$Stamp.year }
                'month'        { return [string]$Stamp.month }
                'day'          { return [string]$Stamp.day }
                default        { return 'NULL' }
            }
        }
        default { return 'NULL' }
    }
}

function Write-Pings {
    <# Write ALL instances' ping rows (success and failure) to common.pings, one commit per flush batch.
       Failure rows (is_success FALSE, response_time_ms = timeout*1000) are the offline-detection signal. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)]$Results, [Parameter(Mandatory)]$Stamp, [int]$Flush = 250)
    $cols = 'instance_id, platform, collected_at, year, month, day, response_time_ms, is_success'
    $plat = ConvertTo-SqlLiteral $Stamp.platform
    $tuples = @(foreach ($r in $Results) {
        $succ = $(if ($r.ping_ok) { 'TRUE' } else { 'FALSE' })
        "($($r.id),$plat,TIMESTAMP '$($Stamp.collected_at)',$($Stamp.year),$($Stamp.month),$($Stamp.day),$($r.ping_ms),$succ)"
    })
    $commits = 0; $rows = 0; $errors = 0; $lastErr = $null
    for ($i = 0; $i -lt $tuples.Count; $i += $Flush) {
        $chunk = $tuples[$i..([math]::Min($i + $Flush - 1, $tuples.Count - 1))]
        try { Invoke-LakeExec $Conn "INSERT INTO lake.common.pings ($cols) VALUES $($chunk -join ',');"; $commits++; $rows += $chunk.Count }
        catch { $errors++; $lastErr = $_.Exception.Message }
    }
    [pscustomobject]@{ commits = $commits; rows = $rows; errors = $errors; last_error = $lastErr }
}

function Write-Collector {
    <#
    .SYNOPSIS Write one collector's rows for all eligible instances: Appender -> stg -> ONE
              INSERT...SELECT per flush batch into lake.<target_table>.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)]$Collector, [Parameter(Mandatory)]$Results, [Parameter(Mandatory)]$Stamp, [int]$Flush = 250)
    $schema    = $Collector.schema
    $queryCols = @($schema | Where-Object { $_.source -eq 'query' })
    $target    = $Collector.target_table

    $stgDefs = @('instance_id INTEGER') + @($queryCols | ForEach-Object { '"' + $_.name + '" ' + $_.type })
    Invoke-LakeExec $Conn "CREATE OR REPLACE TABLE stg ($($stgDefs -join ', '));"
    $colNames    = ($schema | ForEach-Object { '"' + $_.name + '"' }) -join ', '
    $selectExprs = ($schema | ForEach-Object { Get-ColExpr $_ $Stamp }) -join ', '

    # eligible instances that produced rows for THIS collector
    $units = @(foreach ($r in $Results) {
        if (-not $r.ping_ok) { continue }
        $cr = $r.results[$Collector.name]
        if ($cr -and $cr.rows -and @($cr.rows).Count -gt 0) { [pscustomobject]@{ Id = $r.id; Rows = @($cr.rows) } }
    })

    $commits = 0; $rows = 0; $errors = 0; $lastErr = $null
    for ($i = 0; $i -lt $units.Count; $i += $Flush) {
        $chunk = $units[$i..([math]::Min($i + $Flush - 1, $units.Count - 1))]
        try {
            Invoke-LakeExec $Conn 'DELETE FROM stg;'
            $appender = $Conn.CreateAppender('stg')
            try {
                foreach ($u in $chunk) {
                    foreach ($row in $u.Rows) {
                        $ar = $appender.CreateRow()
                        [void]$ar.AppendValue([int]$u.Id)
                        foreach ($qc in $queryCols) { Add-AppendedValue $ar $qc.type $row[$qc.name] }
                        [void]$ar.EndRow()
                    }
                }
            } finally { $appender.Dispose() }   # flush the appender before reading stg
            Invoke-LakeExec $Conn "INSERT INTO lake.$target ($colNames) SELECT $selectExprs FROM stg;"
            $commits++; $rows += ($chunk | ForEach-Object { @($_.Rows).Count } | Measure-Object -Sum).Sum
        } catch { $errors++; $lastErr = $_.Exception.Message }
    }
    [pscustomobject]@{ collector = $Collector.name; instances = $units.Count; commits = $commits; rows = $rows; errors = $errors; last_error = $lastErr }
}

function Write-CollectionLog {
    <# One summary row per collector per cycle (instance_id NULL). status: ok|empty|error. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)]$LogRows, [Parameter(Mandatory)]$Stamp)
    $rows = @($LogRows); if ($rows.Count -eq 0) { return }
    $cols = 'instance_id, platform, collector_name, collected_at, year, month, day, rows_collected, duration_ms, status'
    $plat = ConvertTo-SqlLiteral $Stamp.platform
    $tuples = foreach ($l in $rows) {
        "(NULL,$plat,$(ConvertTo-SqlLiteral $l.collector),TIMESTAMP '$($Stamp.collected_at)',$($Stamp.year),$($Stamp.month),$($Stamp.day),$($l.rows),$($l.duration_ms),'$($l.status)')"
    }
    Invoke-LakeExec $Conn "INSERT INTO lake.common.collection_log ($cols) VALUES $((@($tuples)) -join ',');"
}

function Write-CollectionErrors {
    <# Per-instance failures (connect timeouts, per-query errors) to common.collection_errors. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)]$ErrorRows, [Parameter(Mandatory)]$Stamp)
    $rows = @($ErrorRows); if ($rows.Count -eq 0) { return }
    $cols = 'instance_id, instance_fqn, platform, collector_name, collected_at, year, month, day, error_type, error_message'
    $plat = ConvertTo-SqlLiteral $Stamp.platform
    $tuples = @(foreach ($e in $rows) {
        $fqn = ConvertTo-SqlLiteral $e.instance_fqn
        $msg = ConvertTo-SqlLiteral $e.error_message
        $cn  = $(if ($e.collector) { ConvertTo-SqlLiteral $e.collector } else { 'NULL' })
        $et  = ConvertTo-SqlLiteral $e.error_type
        "($($e.instance_id),$fqn,$plat,$cn,TIMESTAMP '$($Stamp.collected_at)',$($Stamp.year),$($Stamp.month),$($Stamp.day),$et,$msg)"
    })
    for ($i = 0; $i -lt $tuples.Count; $i += 200) {
        $chunk = $tuples[$i..([math]::Min($i + 199, $tuples.Count - 1))]
        Invoke-LakeExec $Conn "INSERT INTO lake.common.collection_errors ($cols) VALUES $($chunk -join ',');"
    }
}

# ------------------------------------------------------------------------------------------------
# Maintenance (run on a separate, single-writer schedule — NOT during collection)
# ------------------------------------------------------------------------------------------------
function Invoke-LakeMaintenance {
    <# Flush inlined data to Parquet, then compact: merge adjacent files -> expire snapshots ->
       cleanup old files. Returns nothing; throws on failure. #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Conn)
    Invoke-LakeExec $Conn "CALL ducklake_flush_inlined_data('lake');"
    Invoke-LakeExec $Conn "CALL ducklake_merge_adjacent_files('lake');"
    Invoke-LakeExec $Conn "CALL ducklake_expire_snapshots('lake', older_than => now());"
    Invoke-LakeExec $Conn "CALL ducklake_cleanup_old_files('lake', cleanup_all => true);"
}

Export-ModuleMember -Function Get-CollectorContext, Open-Lake, Invoke-LakeExec, Invoke-LakeReader,
    Sync-InstanceDimension, Get-Fleet, Invoke-FleetRead, Write-Pings, Write-Collector,
    Write-CollectionLog, Write-CollectionErrors, Invoke-LakeMaintenance, ConvertTo-SqlLiteral
