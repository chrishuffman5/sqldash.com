-- pack: sqlserver  collector: trace_flags  ->  sqlserver.trace_flags
-- Active GLOBAL trace flags via DBCC TRACESTATUS(-1). Instance-level: one row per enabled flag,
-- zero rows when none are enabled. Multi-statement batch REQUIRED: DBCC output is captured into a
-- temp table, then a single data SELECT is returned (the only result set the collector reads).
-- Pure platform SQL: NO identity literal, NO @InstanceID/@UTCOFFSET. The collector stamps
-- instance_id/platform/collected_at after the read. Valid on SQL Server 2016+.
SET NOCOUNT ON;

CREATE TABLE #tf
(
    TraceFlag INT,
    Status    INT,
    Global    INT,
    Session   INT
);

INSERT INTO #tf (TraceFlag, Status, Global, Session)
EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

SELECT
    tf.TraceFlag                AS trace_flag,
    CAST(tf.Status AS BIT)      AS is_enabled,
    CAST(tf.Global AS BIT)      AS is_global
FROM #tf AS tf
WHERE tf.Global = 1
ORDER BY tf.TraceFlag;

DROP TABLE #tf;
