-- SQLDash lake — seed data: scoring band thresholds (legacy IRC bands).
-- index value 0 = healthy; 1 = warn; 2 = critical. irc_index = sum of the five (0-10).
--   cpu  uses (engine_cpu_percent + other_cpu_percent):  <75 ->0, <90 ->1, else 2
--   memory (PLE seconds, lower is worse):                >=3600 ->0, >=300 ->1, else 2
--   read/write latency (ms, higher worse):               <25 ->0, <125 ->1, else 2
--   blocker_ratio (higher worse):                        <0.05 ->0, <0.15 ->1, else 2
DELETE FROM common.score_thresholds;
INSERT INTO common.score_thresholds (index_name, direction, warn_threshold, crit_threshold) VALUES
    ('cpu',           'higher_worse',   75.0,   90.0),
    ('memory',        'lower_worse',  3600.0,  300.0),
    ('read_latency',  'higher_worse',   25.0,  125.0),
    ('write_latency', 'higher_worse',   25.0,  125.0),
    ('blocker',       'higher_worse',    0.05,   0.15);
