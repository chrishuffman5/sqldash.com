-- pack: sqlserver  collector: mirroring_health  ->  sqlserver.mirroring_health
-- Database-mirroring session state, one row per mirrored database. Native database_id
-- (= sys.database_mirroring.database_id) is the key; instance_id/platform/collected_at
-- are stamped by the collector after the read.
-- Returns ZERO rows when nothing is mirrored (non-mirrored instance) — correct.
-- Pure platform SQL: NO identity literal, NO @InstanceID/@UTCOFFSET, NO guards.
-- Database mirroring is deprecated (since 2012); valid on SQL Server 2016+ (engine 13+).
-- Note: sys.database_mirroring.mirroring_redo_queue is INT on-engine; CAST to BIGINT
--   to match the lake column type.
SELECT
    dm.database_id                                  AS database_id,
    DB_NAME(dm.database_id)                         AS database_name,
    dm.mirroring_state_desc                         AS mirroring_state,
    dm.mirroring_role_desc                          AS mirroring_role,
    dm.mirroring_safety_level_desc                  AS safety_level,
    dm.mirroring_partner_instance                   AS partner_instance,
    dm.mirroring_witness_name                       AS witness_name,
    dm.mirroring_witness_state_desc                 AS witness_state,
    CAST(dm.mirroring_redo_queue AS BIGINT)         AS redo_queue_kb
FROM sys.database_mirroring AS dm WITH (NOLOCK)
WHERE dm.mirroring_guid IS NOT NULL;
