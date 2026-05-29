#Requires -Version 7.0
<#
  M3 — PowerShell + duckdb CLI (subprocess, lightest deps).

  Reads each instance with System.Data.SqlClient (SSPI), ping-first (timed SELECT 1), then the metric
  DMV query. Reads run in parallel via ForEach-Object -Parallel (-ThrottleLimit = BENCH_THREADS).
  The collected rows are then chunked into flush batches; each batch is committed by ONE `duckdb`
  subprocess that ATTACHes the lake and runs a single multi-row VALUES INSERT (file-free). The
  attach-per-batch is M3's defining cost. Emits a JSON result line on stdout (last line).

  Env: SQLDASH_BENCH_PGCONN, SQLDASH_BENCH_DATA, AWS_REGION/AWS_PROFILE (in env), BENCH_FLEET_CSV,
       BENCH_METRIC (metric_cpu), BENCH_FLUSH_BATCH (32), BENCH_THREADS (24), BENCH_PACK_DIR.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/bench-common.psm1') -Force

$pgconn  = $env:SQLDASH_BENCH_PGCONN
$data    = $env:SQLDASH_BENCH_DATA
$region  = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-1' }
$fleetCsv= $env:BENCH_FLEET_CSV
$metric  = if ($env:BENCH_METRIC) { $env:BENCH_METRIC } else { 'metric_cpu' }
$flush   = [int]($env:BENCH_FLUSH_BATCH ?? 32)
$threads = [int]($env:BENCH_THREADS ?? 24)
$packDir = $env:BENCH_PACK_DIR

# --- load fleet + collector definition -------------------------------------------------------------
$fleet = Import-Csv $fleetCsv
$pack  = Get-Content -Raw (Join-Path $packDir 'collections.json') | ConvertFrom-Json
$col   = $pack.collectors | Where-Object { $_.name -eq $metric }
if (-not $col) { throw "collector $metric not found in pack" }
$querySql = (Get-Content -Raw (Join-Path $packDir $col.query)).Trim().TrimEnd(';')
$timeout  = [int]$col.timeout_seconds
$target   = $col.target_table

# cycle stamp (one collected_at per cycle; jitter across instances is acceptable)
$nowUtc = [datetime]::UtcNow
$collectedAt = $nowUtc.ToString('yyyy-MM-dd HH:mm:ss')
$Y = $nowUtc.Year; $M = $nowUtc.Month; $D = $nowUtc.Day

# --- parallel reads: ping (timed SELECT 1) + metric DMV per instance -------------------------------
$readResults = $fleet | ForEach-Object -ThrottleLimit $threads -Parallel {
    $inst = $_
    $cs = "Server=$($inst.connect_target);Database=master;Connect Timeout=5;TrustServerCertificate=True;Integrated Security=SSPI;Application Name=SqlDashBench"
    $r = [ordered]@{ id = [int]$inst.instance_id; ping_ms = 5000; ping_ok = $false; rows = @() }
    try {
        $conn = [System.Data.SqlClient.SqlConnection]::new($cs)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $conn.Open()
        $pcmd = $conn.CreateCommand(); $pcmd.CommandText = 'SELECT 1'; $pcmd.CommandTimeout = 5
        [void]$pcmd.ExecuteScalar()
        $sw.Stop(); $r.ping_ms = [int]$sw.ElapsedMilliseconds; $r.ping_ok = $true
        # metric query
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $using:querySql; $cmd.CommandTimeout = $using:timeout
        $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($cmd)
        $dt = [System.Data.DataTable]::new(); [void]$adapter.Fill($dt)
        $rows = foreach ($dr in $dt.Rows) {
            $h = @{}; foreach ($c in $dt.Columns) { $h[$c.ColumnName] = $dr[$c.ColumnName] }; $h
        }
        $r.rows = @($rows)
    } catch { $r.error = $_.Exception.Message }
    finally { if ($conn) { $conn.Dispose() } }
    [pscustomobject]$r
}

# --- helpers: SQL literal formatting + a duckdb-CLI commit of one VALUES batch ----------------------
function ConvertTo-SqlLiteral($v) {
    if ($null -eq $v -or $v -is [System.DBNull]) { return 'NULL' }
    if ($v -is [bool])     { return ([bool]$v) ? 'TRUE' : 'FALSE' }
    if ($v -is [datetime]) { return "TIMESTAMP '" + ([datetime]$v).ToString('yyyy-MM-dd HH:mm:ss.fff') + "'" }
    if ($v -is [string])   { return "'" + ($v -replace "'","''") + "'" }
    return [string]$v   # numerics
}
function Get-StampValue($name) {
    switch ($name) {
        'instance_id'  { return $script:curId }
        'platform'     { return "'sqlserver'" }
        'collected_at' { return "TIMESTAMP '$collectedAt'" }
        'year'         { return "$Y" }; 'month' { return "$M" }; 'day' { return "$D" }
        default        { return 'NULL' }
    }
}
$attach = Get-BenchAttachSql -Ctx ([pscustomobject]@{ Region=$region; PgConn=$pgconn; DataPath=$data })
$colNames = ($col.schema | ForEach-Object { '"' + $_.name + '"' }) -join ', '

function Invoke-ValuesCommit([string]$Table, [string]$Columns, [string[]]$Tuples) {
    if ($Tuples.Count -eq 0) { return $true }
    $sql = $attach + "INSERT INTO $Table ($Columns) VALUES`n" + ($Tuples -join ",`n") + ";"
    $out = ($sql | duckdb 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Write-Error "duckdb commit failed: $out"; return $false }
    return $true
}
$pingCols = 'instance_id, platform, collected_at, year, month, day, response_time_ms, is_success'

# --- build output rows (stamp + query + const) and commit in flush batches -------------------------
$ok = @($readResults | Where-Object { $_.ping_ok })
$pingTuples = foreach ($r in $ok) { "($($r.id), 'sqlserver', TIMESTAMP '$collectedAt', $Y, $M, $D, $($r.ping_ms), TRUE)" }

# metric tuples (schema-ordered); $script:curId set per row so 'instance_id' stamp resolves
$metricTuples = [System.Collections.Generic.List[string]]::new()
foreach ($r in $ok) {
    $script:curId = $r.id
    foreach ($row in $r.rows) {
        $vals = foreach ($cdef in $col.schema) {
            switch ($cdef.source) {
                'stamp' { Get-StampValue $cdef.name }
                'query' { ConvertTo-SqlLiteral $row[$cdef.name] }
                'const' { if ($cdef.PSObject.Properties['const']) { ConvertTo-SqlLiteral $cdef.const } else { 'NULL' } }
            }
        }
        $metricTuples.Add('(' + ($vals -join ', ') + ')')
    }
}

$commits = 0; $errors = 0; $rowsWritten = 0; $pingRows = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# pings: one commit per FLUSH-instance batch
$pingArr = @($pingTuples)
for ($i = 0; $i -lt $pingArr.Count; $i += $flush) {
    $chunk = $pingArr[$i..([math]::Min($i+$flush-1, $pingArr.Count-1))]
    if (Invoke-ValuesCommit -Table 'common.pings' -Columns $pingCols -Tuples $chunk) { $commits++; $pingRows += $chunk.Count } else { $errors++ }
}
# metric: one commit per FLUSH-instance batch (chunk by instance count via row count proxy when 1 row/instance)
$metricArr = @($metricTuples)
$batchRows = [math]::Max(1, $flush)   # ~FLUSH instances per commit (1 row/instance for cpu)
for ($i = 0; $i -lt $metricArr.Count; $i += $batchRows) {
    $chunk = $metricArr[$i..([math]::Min($i+$batchRows-1, $metricArr.Count-1))]
    if (Invoke-ValuesCommit -Table $target -Columns $colNames -Tuples $chunk) { $commits++; $rowsWritten += $chunk.Count } else { $errors++ }
}
$sw.Stop()
$elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 2)
$readErrors = @($readResults | Where-Object { $_.PSObject.Properties['error'] }).Count

[pscustomobject]@{
    method='M3'; metric=$metric; target_table=$target
    instances=$fleet.Count; flush_batch=$flush; threads=$threads
    commits=$commits; rows_written=$rowsWritten; ping_rows=$pingRows
    conflicts=0; errors=$errors; read_errors=$readErrors
    elapsed_sec=$elapsed
    rows_per_sec=[int]($(if ($elapsed -gt 0) { $rowsWritten/$elapsed } else { 0 }))
    commits_per_sec=[math]::Round($(if ($elapsed -gt 0) { $commits/$elapsed } else { 0 }),2)
} | ConvertTo-Json -Compress
