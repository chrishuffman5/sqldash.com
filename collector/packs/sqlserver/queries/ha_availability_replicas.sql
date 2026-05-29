-- pack: sqlserver  collector: ha_availability_replicas  ->  sqlserver.ha_availability_replicas
-- Per-replica AlwaysOn AG state & health for every replica known to THIS instance.
-- Instance-level: one row per availability replica (across all AGs); NO native database_id.
-- On a non-AlwaysOn instance these HADR catalog/DMVs return ZERO rows — valid, expected (status 'empty').
-- Catalog views (sys.availability_replicas, sys.availability_groups) and the DMV
--   (sys.dm_hadr_availability_replica_states) exist SQL Server 2012+; fine for 2016–2025.
-- seeding_mode_desc on sys.availability_replicas exists SQL Server 2016 (13.x)+ — safe on the 2016+ floor.
-- The collector stamps instance_id/platform/collected_at after the read; emit data columns only.
SELECT
    ag.name                                         AS availability_group_name,
    ar.replica_server_name                          AS replica_server_name,
    ars.role_desc                                   AS replica_role,   -- NOT current_role: reserved word in Postgres (DuckLake catalog) breaks inlining
    ar.availability_mode_desc                       AS availability_mode,
    ar.failover_mode_desc                           AS failover_mode,
    ar.seeding_mode_desc                            AS seeding_mode,
    ars.operational_state_desc                      AS operational_state,
    ars.connected_state_desc                        AS connected_state,
    ars.recovery_health_desc                        AS recovery_health,
    ars.synchronization_health_desc                 AS sync_health,
    CONVERT(BIT, ars.is_local)                      AS is_local,
    ars.last_connect_error_number                   AS last_connect_error_number,
    ars.last_connect_error_timestamp                AS last_connect_error_at
FROM sys.availability_replicas ar
JOIN sys.dm_hadr_availability_replica_states ars
    ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag
    ON ag.group_id = ar.group_id;
