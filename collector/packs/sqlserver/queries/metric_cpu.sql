-- pack: sqlserver  collector: metric_cpu  ->  common.metric_cpu
-- Average CPU over the last 15 RING_BUFFER_SCHEDULER_MONITOR samples.
-- Pure platform SQL: NO identity literal, NO @UTCOFFSET. The collector stamps
-- instance_id/platform/collected_at/year/month/day after the read.
-- Aliases are snake_case and match common.metric_cpu exactly (fixes DATATYPE-VALIDATION debt).
WITH ring AS (
    SELECT TOP (15)
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')        AS system_idle,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS sql_util,
        record.value('(./Record/@id)[1]', 'int')                                                   AS record_id
    FROM (
        SELECT CONVERT(XML, record) AS record
        FROM sys.dm_os_ring_buffers WITH (NOLOCK)
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE N'%<SystemHealth>%'
    ) x
    ORDER BY record_id DESC
)
SELECT
    CAST(AVG(sql_util) AS SMALLINT)                                                       AS engine_cpu_percent,
    CAST(CASE WHEN AVG(100 - system_idle - sql_util) < 0 THEN 0
              ELSE AVG(100 - system_idle - sql_util) END AS SMALLINT)                     AS other_cpu_percent,
    CAST(AVG(system_idle) AS SMALLINT)                                                    AS system_idle_percent
FROM ring
OPTION (RECOMPILE);
