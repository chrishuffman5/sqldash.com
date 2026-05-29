-- pack: sqlserver  collector: backup_status  ->  sqlserver.backup_status
-- One row per database: last full/diff/log backup timestamps + last full backup size.
-- Pure platform SQL: NO identity literal, NO @InstanceID/@UTCOFFSET. The collector
-- stamps instance_id/platform/collected_at after the read.
-- Emits the native database_id from sys.databases as the per-database key.
-- backupset has no database_id, so the backup aggregate joins by database_name.
-- Snapshots excluded via source_database_id IS NULL. Target SQL Server 2016+.
-- On Azure SQL Database (engine 5) msdb backup history is absent; backup columns are
--   simply NULL there rather than guarded with IF/RETURN, so the SELECT still parses.
SELECT
    d.database_id                                       AS database_id,
    d.name                                              AS database_name,
    d.recovery_model_desc                               AS recovery_model,
    d.log_reuse_wait_desc                               AS log_reuse_wait_desc,
    b.last_full_backup                                  AS last_full_backup,
    b.last_diff_backup                                  AS last_diff_backup,
    b.last_log_backup                                   AS last_log_backup,
    fs.backup_size                                      AS last_full_size_bytes,
    fs.compressed_backup_size                           AS last_full_compressed_bytes
FROM sys.databases AS d WITH (NOLOCK)
LEFT JOIN (
    SELECT
        bs.database_name,
        MAX(CASE WHEN bs.type = 'D' THEN bs.backup_finish_date END) AS last_full_backup,
        MAX(CASE WHEN bs.type = 'I' THEN bs.backup_finish_date END) AS last_diff_backup,
        MAX(CASE WHEN bs.type = 'L' THEN bs.backup_finish_date END) AS last_log_backup
    FROM msdb.dbo.backupset AS bs WITH (NOLOCK)
    GROUP BY bs.database_name
) AS b ON b.database_name = d.name
OUTER APPLY (
    SELECT TOP (1) bs2.backup_size, bs2.compressed_backup_size
    FROM msdb.dbo.backupset AS bs2 WITH (NOLOCK)
    WHERE bs2.database_name = d.name
      AND bs2.type = 'D'
    ORDER BY bs2.backup_finish_date DESC
) AS fs
WHERE d.source_database_id IS NULL;
