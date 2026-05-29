-- pack: sqlserver  collector: instance_details  ->  common.instance_details
-- Current point-in-time instance details: one row per instance per collection.
-- Pure platform SQL: NO identity literal, NO @InstanceID/@UTCOFFSET. The collector
-- stamps instance_id/platform/collected_at after the read.
-- Aliases are snake_case and match common.instance_details exactly.
-- Target SQL Server 2016+ (engine 13+): the modern sys.dm_os_sys_info column names
--   physical_memory_kb and sqlserver_start_time are present on every supported version,
--   so no SERVERPROPERTY('ProductVersion') branch is required here.
-- physical_cpu_count = cpu_count / hyperthread_ratio, guarded against a 0 ratio via NULLIF.
SELECT
    CAST(SERVERPROPERTY('ServerName')          AS VARCHAR(128)) AS server_name,
    CAST(SERVERPROPERTY('ProductVersion')      AS VARCHAR(128)) AS product_version,
    CAST(SERVERPROPERTY('ProductLevel')        AS VARCHAR(128)) AS product_level,
    CAST(SERVERPROPERTY('Edition')             AS VARCHAR(128)) AS edition,
    CAST(SERVERPROPERTY('EngineEdition')       AS SMALLINT)     AS engine_edition,
    CAST(SERVERPROPERTY('Collation')           AS VARCHAR(128)) AS collation_default,
    CAST(SERVERPROPERTY('IsClustered')         AS BIT)          AS is_clustered,
    CAST(SERVERPROPERTY('IsFullTextInstalled') AS BIT)          AS is_full_text_installed,
    CAST(osi.cpu_count                                 AS INTEGER)  AS logical_cpu_count,
    CAST(osi.cpu_count / NULLIF(osi.hyperthread_ratio, 0) AS INTEGER) AS physical_cpu_count,
    CAST(osi.hyperthread_ratio                         AS INTEGER)  AS hyperthread_ratio,
    CAST(osi.physical_memory_kb / 1024                 AS BIGINT)   AS physical_memory_mb,
    CAST((SELECT c.value_in_use FROM sys.configurations AS c
          WHERE c.name = 'min server memory (MB)')     AS INTEGER)  AS min_memory_mb,
    CAST((SELECT c.value_in_use FROM sys.configurations AS c
          WHERE c.name = 'max server memory (MB)')     AS INTEGER)  AS max_memory_mb,
    CAST((SELECT c.value_in_use FROM sys.configurations AS c
          WHERE c.name = 'max degree of parallelism')  AS SMALLINT) AS max_dop,
    CAST(osi.sqlserver_start_time                      AS DATETIME2(0)) AS engine_start_time
FROM sys.dm_os_sys_info AS osi WITH (NOLOCK)
OPTION (RECOMPILE);
