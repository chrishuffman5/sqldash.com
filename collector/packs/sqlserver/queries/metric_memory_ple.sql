-- pack: sqlserver  collector: metric_memory_ple  ->  common.metric_memory
-- Page Life Expectancy (instance-wide Buffer Manager). Higher is better (target > 300s).
-- buffer_hit_ratio / grants_* are left NULL by this collector (curated-superset table).
SELECT TOP (1)
    CAST(cntr_value AS BIGINT) AS page_residency_seconds
FROM sys.dm_os_performance_counters WITH (NOLOCK)
WHERE [object_name] LIKE N'%Buffer Manager%'
  AND counter_name = N'Page life expectancy'
OPTION (RECOMPILE);
