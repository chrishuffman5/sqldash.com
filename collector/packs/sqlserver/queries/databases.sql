-- pack: sqlserver  collector: databases  ->  common.databases
-- Database registry/current state. Returns the native database_id (key) + database_name (attribute).
WITH file_stats AS (
    SELECT database_id, type, SUM(size * 8.0 / 1024) AS size_mb
    FROM sys.master_files
    GROUP BY database_id, type
)
SELECT
    db.database_id                                  AS database_id,
    db.name                                         AS database_name,
    db.create_date                                  AS create_date,
    CAST(db.compatibility_level AS SMALLINT)        AS compatibility_level,
    db.collation_name                               AS collation_name,
    db.recovery_model_desc                          AS recovery_model,
    db.state_desc                                   AS state,
    db.user_access_desc                             AS user_access,
    db.is_read_only                                 AS is_read_only,
    CAST(CASE WHEN dm.mirroring_guid IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS is_mirrored,
    CAST(CASE WHEN db.group_database_id IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS is_alwayson,
    SUSER_SNAME(db.owner_sid)                       AS owner_name,
    CONVERT(INT, ISNULL(fs_data.size_mb, 0))        AS data_file_size_mb,
    CONVERT(INT, ISNULL(fs_log.size_mb, 0))         AS log_file_size_mb
FROM sys.databases db
LEFT JOIN file_stats fs_data ON fs_data.database_id = db.database_id AND fs_data.type = 0
LEFT JOIN file_stats fs_log  ON fs_log.database_id  = db.database_id AND fs_log.type = 1
LEFT JOIN sys.database_mirroring dm ON dm.database_id = db.database_id
WHERE db.source_database_id IS NULL;
