#Requires -Version 7.0
<#
  SQLDash collector (Phase 0).
  Connects to a target instance with Windows-integrated auth (SSPI), runs a pack query as PURE
  platform SQL, stamps the self-describing identity tuple onto the rows COLLECTOR-SIDE (never
  injected into the remote query), and emits typed Parquet to a node-sharded inbox. Collectors
  never touch the lake — the TypeScript writer is the sole DuckLake committer.

  Uses System.Data.SqlClient (present in PS7). Production should move to Microsoft.Data.SqlClient.
#>

# Fixed namespace for deterministic UUIDv5 keys (RFC 4122 DNS namespace; any constant works).
$script:SqlDashNamespace = '6ba7b810-9dad-11d1-80b4-00c04fd430c8'

function Get-Uuid5 {
    <#
    .SYNOPSIS Deterministic RFC-4122 v5 UUID (SHA-1) for a name within $SqlDashNamespace.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $ns = [guid]$script:SqlDashNamespace
    $nsBytes = $ns.ToByteArray()
    # .NET Guid.ToByteArray() is little-endian for the first 3 fields; RFC layout is big-endian.
    [Array]::Reverse($nsBytes, 0, 4)
    [Array]::Reverse($nsBytes, 4, 2)
    [Array]::Reverse($nsBytes, 6, 2)

    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($nsBytes + $nameBytes) } finally { $sha1.Dispose() }

    $b = $hash[0..15]
    $b[6] = ($b[6] -band 0x0F) -bor 0x50   # version 5
    $b[8] = ($b[8] -band 0x3F) -bor 0x80   # variant RFC 4122
    $hex = -join ($b | ForEach-Object { $_.ToString('x2') })
    '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0,8), $hex.Substring(8,4), $hex.Substring(12,4), $hex.Substring(16,4), $hex.Substring(20,12)
}

function Get-InstanceKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Platform, [Parameter(Mandatory)][string]$Fqn)
    Get-Uuid5 -Name ("{0}|{1}" -f $Platform.ToLowerInvariant(), $Fqn.ToLowerInvariant())
}

function Get-DatabaseKey {
    <#
    .SYNOPSIS Deterministic database_key — get-or-create on (instance_key, database_name).
              Survives native database_id reuse after DROP and AG failover.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstanceKey, [Parameter(Mandatory)][string]$DatabaseName)
    Get-Uuid5 -Name ("{0}|{1}" -f $InstanceKey, $DatabaseName.ToLowerInvariant())
}

function New-SqlConnectionString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$Database = 'master',
        [ValidateSet('integrated','sql')][string]$AuthMode = 'integrated',
        [string]$Username, [string]$Password,
        [int]$ConnectTimeout = 5
    )
    $parts = @("Server=$Server", "Database=$Database", "Connect Timeout=$ConnectTimeout",
               "TrustServerCertificate=True", "Application Name=SqlDashCollector")
    if ($AuthMode -eq 'integrated') { $parts += 'Integrated Security=SSPI' }
    else { $parts += "User ID=$Username"; $parts += "Password=$Password" }
    $parts -join ';'
}

function Invoke-SqlQuery {
    <#
    .SYNOPSIS Run a query and return a DataTable (System.Data.SqlClient).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][string]$Query,
        [int]$TimeoutSeconds = 5
    )
    $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        [void]$adapter.Fill($dt)
        ,$dt
    }
    finally { $conn.Dispose() }
}

function ConvertTo-CsvField {
    param($Value)
    if ($null -eq $Value -or $Value -is [DBNull]) { return '' }          # empty -> NULL on read
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss.fff') }
    if ($Value -is [bool])     { return ([bool]$Value) ? 'true' : 'false' }
    # values in scope (ints, uuid strings, timestamps) contain no commas/quotes/newlines
    [string]$Value
}

function Write-TypedParquet {
    <#
    .SYNOPSIS Write rows to a typed Parquet file via the duckdb CLI, enforcing the column types
              from the collector schema (this is the emit-side contract).
    .PARAMETER Rows  Array of ordered object[] arrays, one per output row (schema column order).
    .PARAMETER Schema  Array of @{name;type;source} from collections.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][object[]]$Schema,
        [Parameter(Mandatory)][string]$OutPath
    )
    $tmpCsv = [System.IO.Path]::GetTempFileName() + '.csv'
    try {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine( ($Schema.name -join ',') )                # header
        foreach ($row in $Rows) {
            [void]$sb.AppendLine( (($row | ForEach-Object { ConvertTo-CsvField $_ }) -join ',') )
        }
        [System.IO.File]::WriteAllText($tmpCsv, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

        $colsMap = ($Schema | ForEach-Object { "'$($_.name)': '$($_.type)'" }) -join ', '
        $csvFwd = ($tmpCsv  -replace '\\','/')
        $outFwd = ($OutPath -replace '\\','/')
        $sql = "COPY (SELECT * FROM read_csv('$csvFwd', header=true, columns={ $colsMap })) TO '$outFwd' (FORMAT PARQUET);"

        $out = $sql | duckdb 2>&1
        if ($LASTEXITCODE -ne 0) { throw "duckdb parquet emit failed: $out" }
    }
    finally { Remove-Item $tmpCsv -ErrorAction SilentlyContinue }
}

function Invoke-Collector {
    <#
    .SYNOPSIS Run one instance-level collector against one target and emit a Parquet to the inbox.
    .OUTPUTS A summary hashtable (status: ok|empty|error, rows, path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Collector,        # pack collector def (with .schema)
        [Parameter(Mandatory)][string]$PackDir,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$Fqn,
        [Parameter(Mandatory)][string]$InstanceKey,
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][string]$InboxRoot,
        [Parameter(Mandatory)][string]$NodeId
    )
    $name = $Collector.name
    $collectedAt = [datetime]::UtcNow
    $sourceQueryId = "$name|$([guid]::NewGuid().ToString('n'))"
    $stamp = @{
        instance_key    = $InstanceKey
        platform        = $Platform
        collected_at    = $collectedAt
        year            = [int16]$collectedAt.Year
        month           = [byte]$collectedAt.Month
        day             = [byte]$collectedAt.Day
        source_query_id = $sourceQueryId
    }

    try {
        $queryPath = Join-Path $PackDir $Collector.query
        $query = Get-Content -Raw $queryPath
        $dt = Invoke-SqlQuery -ConnectionString $ConnectionString -Query $query -TimeoutSeconds $Collector.timeout_seconds

        if ($dt.Rows.Count -eq 0) {
            return @{ collector = $name; status = 'empty'; rows = 0; path = $null }
        }

        $rows = New-Object System.Collections.Generic.List[object[]]
        foreach ($r in $dt.Rows) {
            $rec = foreach ($col in $Collector.schema) {
                switch ($col.source) {
                    'stamp' { $stamp[$col.name] }
                    'query' { $r[$col.name] }
                    'dbkey' { Get-DatabaseKey -InstanceKey $InstanceKey -DatabaseName ([string]$r['database_name']) }
                    'const' { if ($col.PSObject.Properties['const']) { $col.const } else { $null } }
                    default { throw "unknown source '$($col.source)' for column $($col.name)" }
                }
            }
            $rows.Add([object[]]$rec)
        }

        $tableDir = Join-Path (Join-Path $InboxRoot $NodeId) $Collector.target_table
        New-Item -ItemType Directory -Force -Path $tableDir | Out-Null
        $fileName = '{0}-{1}.parquet' -f $collectedAt.ToString('yyyyMMddTHHmmssfff'), [guid]::NewGuid().ToString('n').Substring(0,8)
        $outPath = Join-Path $tableDir $fileName

        Write-TypedParquet -Rows $rows.ToArray() -Schema $Collector.schema -OutPath $outPath
        return @{ collector = $name; status = 'ok'; rows = $rows.Count; path = $outPath }
    }
    catch {
        return @{ collector = $name; status = 'error'; rows = 0; path = $null; error = $_.Exception.Message }
    }
}

Export-ModuleMember -Function Get-Uuid5, Get-InstanceKey, Get-DatabaseKey, New-SqlConnectionString, Invoke-SqlQuery, Write-TypedParquet, Invoke-Collector
