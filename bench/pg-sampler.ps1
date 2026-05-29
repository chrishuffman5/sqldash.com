#Requires -Version 7.0
<#
  Background Postgres sampler. Polls pg_stat_activity for the catalog db every -IntervalMs and appends
  a CSV row, until -StopFile appears. The orchestrator computes peaks (max active backends, max
  idle-in-transaction, max lock waiters, longest txn) from the CSV — the "is Postgres healthy under
  the write load" signal that before/after counters can't capture.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Container,
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$OutCsv,
    [Parameter(Mandatory)][string]$StopFile,
    [int]$IntervalMs = 200
)
'ts,active,idle_in_txn,lock_waiters,longest_txn_sec' | Set-Content $OutCsv
$q = @"
SELECT
  count(*) FILTER (WHERE state='active'),
  count(*) FILTER (WHERE state='idle in transaction'),
  count(*) FILTER (WHERE wait_event_type='Lock'),
  coalesce(round(max(extract(epoch from now()-xact_start))::numeric,2) FILTER (WHERE xact_start IS NOT NULL),0)
FROM pg_stat_activity WHERE datname='$Database';
"@
while (-not (Test-Path $StopFile)) {
    $r = ($q | docker exec -i $Container psql -U postgres -d $Database -tAq -F',' 2>$null | Out-String).Trim()
    if ($r) { Add-Content $OutCsv ("{0},{1}" -f ([datetime]::UtcNow.ToString('HH:mm:ss.fff')), $r) }
    Start-Sleep -Milliseconds $IntervalMs
}
