-- pack: sqlserver  collector: metric_database_io  ->  common.metric_database_io
-- CUMULATIVE per-database IO since last restart. Deltas/latency computed read-side in scoring.
-- Returns the native database_id (instance_id + database_id is the key). last_restart_at = tempdb create_date.
SELECT
    v.database_id                                   AS database_id,
    (SELECT create_date FROM sys.databases WHERE database_id = 2) AS last_restart_at,  -- tempdb
    SUM(CONVERT(BIGINT, v.num_of_reads))            AS num_of_reads,
    SUM(CONVERT(BIGINT, v.num_of_bytes_read))       AS num_of_bytes_read,
    SUM(CONVERT(BIGINT, v.io_stall_read_ms))        AS io_stall_read_ms,
    SUM(CONVERT(BIGINT, v.num_of_writes))           AS num_of_writes,
    SUM(CONVERT(BIGINT, v.num_of_bytes_written))    AS num_of_bytes_written,
    SUM(CONVERT(BIGINT, v.io_stall_write_ms))       AS io_stall_write_ms,
    SUM(CONVERT(BIGINT, v.io_stall))                AS io_stall,
    SUM(CONVERT(BIGINT, v.size_on_disk_bytes))      AS size_on_disk_bytes
FROM sys.master_files f
JOIN sys.dm_io_virtual_file_stats(NULL, NULL) v
    ON f.database_id = v.database_id AND f.file_id = v.file_id
JOIN sys.databases d ON d.database_id = f.database_id
WHERE f.type_desc <> 'FULLTEXT'
  AND d.state_desc = 'ONLINE'
GROUP BY v.database_id;
