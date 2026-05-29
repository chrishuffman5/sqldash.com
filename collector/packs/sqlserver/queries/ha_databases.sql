-- pack: sqlserver  collector: ha_databases  ->  sqlserver.ha_databases
-- Per-database AlwaysOn AG replica health for the LOCAL replica on THIS instance.
-- Returns the native database_id (instance_id + database_id is the key).
-- One row per AG database on the local replica (WHERE drs.is_local = 1).
-- On a non-AlwaysOn instance these HADR DMVs return ZERO rows — valid, expected (status 'empty').
-- DMVs (sys.dm_hadr_database_replica_states, sys.dm_hadr_database_replica_cluster_states,
--   sys.availability_replicas, sys.availability_groups) exist SQL Server 2012+; fine for 2016–2025.
-- is_failover_ready lives on sys.dm_hadr_database_replica_cluster_states (keyed by
--   replica_id + group_database_id), NOT on dm_hadr_database_replica_states — joined via LEFT JOIN.
-- estimated_data_loss_sec is not directly exposed by these DMVs (it derives from perf counters /
--   DB harden LSN), so emit NULL for now rather than guess.
-- Queue sizes (log_send_queue_size, redo_queue_size) are reported in KB by the DMV.
SELECT
    drs.database_id                                 AS database_id,
    ag.name                                         AS availability_group_name,
    ar.replica_server_name                          AS availability_replica_name,
    drs.synchronization_state_desc                  AS synchronization_state,
    drs.synchronization_health_desc                 AS synchronization_health,
    CONVERT(BIT, drs.is_suspended)                  AS is_suspended,
    CONVERT(BIT, drcs.is_failover_ready)            AS is_failover_ready,
    CONVERT(INT, NULL)                              AS estimated_data_loss_sec,
    CONVERT(BIGINT, drs.log_send_queue_size)        AS log_send_queue_kb,
    CONVERT(BIGINT, drs.redo_queue_size)            AS redo_queue_kb
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
    ON ar.replica_id = drs.replica_id
   AND ar.group_id   = drs.group_id
JOIN sys.availability_groups ag
    ON ag.group_id = drs.group_id
LEFT JOIN sys.dm_hadr_database_replica_cluster_states drcs
    ON drcs.replica_id        = drs.replica_id
   AND drcs.group_database_id = drs.group_database_id
WHERE drs.is_local = 1;
