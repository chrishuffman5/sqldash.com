-- pack: sqlserver  collector: metric_wait_stats  ->  common.metric_wait_stats
-- Instance-level top-25 CUMULATIVE waits since last restart (sys.dm_os_wait_stats).
-- RAW counters only (avg/pct/running-% are computed read-side in scoring). Benign/idle
-- waits are filtered out via the NOT-IN list. last_restart_at = tempdb create_date.
-- Pure platform SQL: NO identity literal, NO @InstanceID/@UTCOFFSET; the collector stamps
-- instance_id/platform/collected_at after the read. Valid on SQL Server 2016+.
;WITH filtered_waits AS
(
    SELECT
        wait_type,
        waiting_tasks_count,
        wait_time_ms,
        max_wait_time_ms,
        signal_wait_time_ms
    FROM sys.dm_os_wait_stats WITH (NOLOCK)
    WHERE wait_type NOT IN
    (
        -- Sleeping / idle background waits
        N'SLEEP_TASK',                       N'SLEEP_SYSTEMTASK',
        N'SLEEP_BPOOL_FLUSH',                N'SLEEP_DBSTARTUP',
        N'SLEEP_DCOMSTARTUP',                N'SLEEP_MASTERDBREADY',
        N'SLEEP_MASTERMDREADY',              N'SLEEP_MASTERUPGRADED',
        N'SLEEP_MSDBSTARTUP',                N'SLEEP_TEMPDBSTARTUP',
        N'LAZYWRITER_SLEEP',                 N'WAITFOR',
        N'WAITFOR_TASKSHUTDOWN',             N'WAIT_FOR_RESULTS',
        N'SERVER_IDLE_CHECK',                N'KSOURCE_WAKEUP',
        -- Checkpoint / log housekeeping
        N'CHECKPOINT_QUEUE',                 N'CHKPT',
        N'LOGMGR_QUEUE',                     N'DIRTY_PAGE_POLL',
        N'REDO_THREAD_PENDING_WORK',
        -- Service Broker idle loops
        N'BROKER_EVENTHANDLER',              N'BROKER_RECEIVE_WAITFOR',
        N'BROKER_TASK_STOP',                 N'BROKER_TO_FLUSH',
        N'BROKER_TRANSMITTER',
        -- CLR / dispatcher / XE idle
        N'CLR_AUTO_EVENT',                   N'CLR_MANUAL_EVENT',
        N'CLR_SEMAPHORE',                    N'DISPATCHER_QUEUE_SEMAPHORE',
        N'ONDEMAND_TASK_QUEUE',              N'SOS_WORK_DISPATCHER',
        N'XE_DISPATCHER_JOIN',               N'XE_DISPATCHER_WAIT',
        N'XE_TIMER_EVENT',                   N'XE_BUFFERMGR_ALLPROCESSED_EVENT',
        N'XE_LIVE_TARGET_TVF',
        -- Full-text idle
        N'FT_IFTS_SCHEDULER_IDLE_WAIT',      N'FT_IFTSHC_MUTEX',
        N'FSAGENT',
        -- Database mirroring idle
        N'DBMIRROR_DBM_EVENT',               N'DBMIRROR_EVENTS_QUEUE',
        N'DBMIRROR_WORKER_QUEUE',            N'DBMIRRORING_CMD',
        -- Always On / HADR idle & redo housekeeping
        N'HADR_CLUSAPI_CALL',                N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT',             N'HADR_NOTIFICATION_DEQUEUE',
        N'HADR_TIMER_TASK',                  N'HADR_WORK_QUEUE',
        N'PARALLEL_REDO_DRAIN_WORKER',       N'PARALLEL_REDO_LOG_CACHE',
        N'PARALLEL_REDO_TRAN_LIST',          N'PARALLEL_REDO_WORKER_SYNC',
        N'PARALLEL_REDO_WORKER_WAIT_WORK',
        -- Query Store background tasks
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE',
        -- In-Memory OLTP (XTP) housekeeping
        N'WAIT_XTP_CKPT_CLOSE',              N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',    N'WAIT_XTP_RECOVERY',
        -- Diagnostics / trace / misc idle
        N'SP_SERVER_DIAGNOSTICS_SLEEP',      N'SQLTRACE_BUFFER_FLUSH',
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
        N'REQUEST_FOR_DEADLOCK_SEARCH',      N'RESOURCE_QUEUE',
        N'EXECSYNC',                         N'SNI_HTTP_ACCEPT',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'VDI_CLIENT_OTHER',                 N'MEMORY_ALLOCATION_EXT',
        N'PVS_PREALLOCATE',                  N'PREEMPTIVE_XE_GETTARGETSTATE',
        N'PREEMPTIVE_OS_FLUSHFILEBUFFERS',   N'PREEMPTIVE_OS_AUTHENTICATIONOPS',
        N'PREEMPTIVE_OS_GETPROCADDRESS'
    )
    AND waiting_tasks_count > 0
)
SELECT TOP (25)
    (SELECT create_date FROM sys.databases WHERE database_id = 2) AS last_restart_at,  -- tempdb
    fw.wait_type                                        AS wait_type,
    fw.waiting_tasks_count                              AS waiting_tasks_count,
    fw.wait_time_ms                                     AS wait_time_ms,
    fw.signal_wait_time_ms                              AS signal_wait_time_ms,
    fw.max_wait_time_ms                                 AS max_wait_time_ms
FROM filtered_waits AS fw
ORDER BY fw.wait_time_ms DESC;
