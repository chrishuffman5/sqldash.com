-- pack: sqlserver  collector: config_settings  ->  sqlserver.config_settings
-- Curated high-value sp_configure / sys.configurations settings, one row PER setting (EAV).
-- Pure platform SQL: NO identity literal, NO @InstanceID/@UTCOFFSET. The collector
-- stamps instance_id/platform/collected_at after the read.
-- Aliases are snake_case. value/value_in_use are sql_variant, so CAST to BIGINT.
-- Target SQL Server 2016+ (engine 13+): is_advanced and is_dynamic both exist on
--   sys.configurations on every supported version (verified on 2025). is_pending is
--   derived from value <> value_in_use. Settings absent on a given build simply
--   yield fewer rows (natural 0-row degradation, no guards).
SELECT
    c.name                                              AS setting_name,
    CAST(c.value AS BIGINT)                             AS configured_value,
    CAST(c.value_in_use AS BIGINT)                      AS running_value,
    CAST(c.is_advanced AS BIT)                          AS is_advanced,
    CAST(c.is_dynamic AS BIT)                           AS is_dynamic,
    CAST(CASE WHEN c.value <> c.value_in_use THEN 1 ELSE 0 END AS BIT) AS is_pending
FROM sys.configurations AS c WITH (NOLOCK)
WHERE c.name IN (
    'max degree of parallelism',
    'cost threshold for parallelism',
    'max server memory (MB)',
    'min server memory (MB)',
    'optimize for ad hoc workloads',
    'priority boost',
    'lightweight pooling',
    'backup compression default',
    'remote admin connections',
    'fill factor (%)',
    'tempdb metadata memory-optimized',
    'automatic soft-NUMA disabled'
)
ORDER BY c.name;
