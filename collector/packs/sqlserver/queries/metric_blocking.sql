-- pack: sqlserver  collector: metric_blocking  ->  common.metric_blocking
-- Count of currently-blocked sessions per database (blocking_session_id <> 0).
-- Returns 0 rows when nothing is blocked (collector logs 'empty', writes no metric rows).
SELECT
    DB_NAME(r.database_id) AS database_name,
    COUNT(*)               AS blocked_session_count
FROM sys.dm_exec_requests r WITH (NOLOCK)
WHERE r.blocking_session_id <> 0
  AND r.database_id > 0
GROUP BY DB_NAME(r.database_id);
