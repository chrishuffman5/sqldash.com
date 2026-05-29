-- pack: sqlserver  collector: metric_perf_counters  ->  common.metric_perf_counters
-- CUMULATIVE raw per-second (cntr_type 272696576) Perfmon counters in ONE wide instance row.
-- No WAITFOR/sampling: emit the raw cntr_value; rates are computed read-side from deltas in scoring.
-- Counters are matched by RTRIM(object_name) LIKE '%:<object>' so this works on BOTH default
--   (object_name = 'SQLServer:..') AND named (object_name = 'MSSQL$inst:..') instances.
-- Instance-scoped counters (_Total / blank) only; last_restart_at = tempdb create_date.
-- Valid on SQL Server 2016+; the collector stamps instance_id/platform/collected_at after the read.
SELECT
    (SELECT create_date FROM sys.databases WHERE database_id = 2)  AS last_restart_at,  -- tempdb
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:SQL Statistics'
              AND RTRIM(pc.counter_name) = 'Batch Requests/sec'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS batch_requests_per_sec_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:SQL Statistics'
              AND RTRIM(pc.counter_name) = 'SQL Compilations/sec'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS sql_compilations_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:SQL Statistics'
              AND RTRIM(pc.counter_name) = 'SQL Re-Compilations/sec'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS sql_recompilations_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:Buffer Manager'
              AND RTRIM(pc.counter_name) = 'Page reads/sec'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS page_reads_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:Buffer Manager'
              AND RTRIM(pc.counter_name) = 'Page writes/sec'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS page_writes_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:Locks'
              AND RTRIM(pc.counter_name) = 'Lock Waits/sec'
              AND RTRIM(pc.instance_name) = '_Total'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS lock_waits_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:Locks'
              AND RTRIM(pc.counter_name) = 'Number of Deadlocks/sec'
              AND RTRIM(pc.instance_name) = '_Total'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS deadlocks_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:Access Methods'
              AND RTRIM(pc.counter_name) = 'Page Splits/sec'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS page_splits_cumulative,
    MAX(CASE WHEN RTRIM(pc.object_name) LIKE '%:Databases'
              AND RTRIM(pc.counter_name) = 'Transactions/sec'
              AND RTRIM(pc.instance_name) = '_Total'
             THEN CONVERT(BIGINT, pc.cntr_value) END)              AS transactions_cumulative
FROM sys.dm_os_performance_counters AS pc WITH (NOLOCK)
WHERE pc.cntr_type = 272696576;
