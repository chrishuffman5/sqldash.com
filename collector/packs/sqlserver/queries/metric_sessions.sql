-- pack: sqlserver  collector: metric_sessions  ->  common.metric_sessions
-- Count of active user sessions (excludes 'sa').
SELECT
    COUNT(*) AS active_sessions
FROM sys.dm_exec_sessions WITH (NOLOCK)
WHERE login_name <> 'sa'
  AND is_user_process = 1;
