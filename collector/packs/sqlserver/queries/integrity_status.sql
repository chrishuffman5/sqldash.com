-- pack: sqlserver  collector: integrity_status  ->  sqlserver.integrity_status
-- One row per database: integrity posture WITHOUT running intrusive checks.
-- Reports database state, page-verify option, read-only flag, and a correlated
-- count of suspect (corruption-history) pages from msdb.dbo.suspect_pages.
-- Pure platform SQL: NO identity literal, NO @InstanceID/@UTCOFFSET. The collector
-- stamps instance_id/platform/collected_at after the read; this SELECT emits the
-- native database_id (instance_id + database_id is the key) plus data columns only.
-- Aliases are snake_case and match common.integrity_status exactly.
-- Target SQL Server 2016+ (engine 13+): sys.databases (source_database_id excludes
-- snapshots) and msdb.dbo.suspect_pages are present on every supported box edition.
SELECT
    d.database_id                                   AS database_id,
    d.name                                          AS database_name,
    d.state_desc                                    AS state,
    d.page_verify_option_desc                       AS page_verify_option,
    CAST(d.is_read_only AS BIT)                     AS is_read_only,
    (SELECT COUNT(*)
     FROM msdb.dbo.suspect_pages AS sp WITH (NOLOCK)
     WHERE sp.database_id = d.database_id)          AS suspect_page_count
FROM sys.databases AS d WITH (NOLOCK)
WHERE d.source_database_id IS NULL;
