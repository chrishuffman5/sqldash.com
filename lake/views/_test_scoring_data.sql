-- Synthetic scoring fixture: 1 production instance + 1 user database across 3 complete past hours.
-- Hand-computed expected scoring (see lake/test-scoring.ps1 assertions):
--   H1 10:00  cpu sum 50 ->0   PLE 7200 ->0   (first IO bucket: no latency)   no blocking
--   H2 11:00  cpu sum 85 ->1   PLE 1800 ->1   read 20ms ->0  write 10ms ->0   blk 3/100=0.03 ->0   IRC=2
--   H3 12:00  cpu sum 96 ->2   PLE  120 ->2   read 100ms ->1 write 25ms ->1   blk 20/100=0.20 ->2  IRC=8
-- IO cumulative counters chosen so deltas give those latencies; last_restart_at avoids any coll_hr.

INSERT INTO common.instances (instance_key, instance_fqn, instance_name, platform, environment, status, auth_mode, registered_at)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','testsrv','testsrv','sqlserver','P','a','integrated', TIMESTAMP '2026-05-27 09:00:00');

INSERT INTO common.databases (instance_key, database_key, platform, database_id, database_name, collected_at, source_query_id)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','sqlserver',7,'AppDb', TIMESTAMP '2026-05-27 12:30:00','seed');

INSERT INTO common.metric_cpu (instance_key, platform, collected_at, year, month, day, engine_cpu_percent, other_cpu_percent, system_idle_percent, source_query_id) VALUES
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 10:30:00',2026,5,27,40,10,50,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 11:30:00',2026,5,27,70,15,15,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 12:30:00',2026,5,27,88,8,4,'seed');

INSERT INTO common.metric_memory (instance_key, platform, collected_at, year, month, day, page_residency_seconds, source_query_id) VALUES
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 10:30:00',2026,5,27,7200,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 11:30:00',2026,5,27,1800,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 12:30:00',2026,5,27, 120,'seed');

INSERT INTO common.metric_sessions (instance_key, platform, collected_at, year, month, day, active_sessions, source_query_id) VALUES
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 10:30:00',2026,5,27,100,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 11:30:00',2026,5,27,100,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sqlserver', TIMESTAMP '2026-05-27 12:30:00',2026,5,27,100,'seed');

INSERT INTO common.metric_database_io (instance_key, database_key, platform, collected_at, year, month, day, last_restart_at, num_of_reads, io_stall_read_ms, num_of_writes, io_stall_write_ms, source_query_id) VALUES
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','sqlserver', TIMESTAMP '2026-05-27 10:30:00',2026,5,27, TIMESTAMP '2026-05-27 03:00:00',1000, 10000,1000,  5000,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','sqlserver', TIMESTAMP '2026-05-27 11:30:00',2026,5,27, TIMESTAMP '2026-05-27 03:00:00',2000, 30000,2000, 15000,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','sqlserver', TIMESTAMP '2026-05-27 12:30:00',2026,5,27, TIMESTAMP '2026-05-27 03:00:00',3000,130000,3000, 40000,'seed');

INSERT INTO common.metric_blocking (instance_key, database_key, platform, collected_at, year, month, day, blocked_session_count, source_query_id) VALUES
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','sqlserver', TIMESTAMP '2026-05-27 11:30:00',2026,5,27, 3,'seed'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','sqlserver', TIMESTAMP '2026-05-27 12:30:00',2026,5,27,20,'seed');
