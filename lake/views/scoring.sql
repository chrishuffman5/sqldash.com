-- =====================================================================================================
-- SQLDash — Health Scoring view chain (DuckDB / DuckLake)
-- PORT of legacy LoadMetricsIntoReportingTAble (SQL/procedures.sql lines 2093-2467) plus the
-- home-page "problematic instances" surface (SQL/views.sql lines 599-622), re-expressed as a
-- pure-DuckDB read-side view chain over the DuckLake `common` schema.
--
-- Grain of the leaf scoring row = (instance_id, database_id, coll_hr) == legacy
-- ReportInstanceAllMetrics keyed by (Coll_HR, Instance_ID, Database_ID).
--
-- CPU / PLE(memory) / sessions are instance-level streams -> they are FANNED OUT across the
-- instance's eligible user databases via the join to common.databases (mirrors legacy
-- INNER JOIN dbo.Databases). Latency and blocking are genuinely per-database.
--
-- Banding is driven entirely by data in common.score_thresholds (NO hardcoded cutoffs). Each band
-- CASE consults BOTH the thresholds AND the `direction` column, so direction is authoritative:
-- a reseed that flips a direction flips the banding without any SQL change. Per the seed
-- (lake/ddl/40_seed.sql), the actual direction values are 'higher_worse' / 'lower_worse':
--   direction = 'higher_worse'  (cpu, read_latency, write_latency, blocker):
--        value <  warn_threshold        -> band 0
--        value <  crit_threshold        -> band 1
--        else (value >= crit_threshold) -> band 2
--   direction = 'lower_worse'   (memory / PLE):  warn=3600 (healthy floor), crit=300 (pressure floor)
--        value >= warn_threshold        -> band 0
--        value >= crit_threshold        -> band 1
--        else (value <  crit_threshold) -> band 2
--
-- Hourly bucket = date_trunc('hour', collected_at)  (== legacy DATEADD(hh, datepart(hh,..), date)).
--
-- INTENTIONAL DEVIATIONS FROM THE LEGACY LOADER (documented, not accidental):
--   * No 24h source window: legacy gated each source with collect_dt >= dateadd(dd,-1,...), an
--     incremental-load optimization. As a continuous read-side view this chain scores full history.
--     (LAG deltas therefore span the full per-(instance,db) series, which is correct for a view.)
--   * No idempotent anti-join / insert: the legacy NOT EXISTS against ReportInstanceAllMetrics is a
--     loader concern; a view is inherently idempotent.
--   * IN-FLIGHT-HOUR EXCLUSION IS RETAINED: legacy line 2463 dropped the current partial hour; we
--     reproduce it in v_health_scores (coll_hr < date_trunc('hour', current UTC)).
--
-- Created in strict dependency order; every object is CREATE OR REPLACE VIEW.
-- =====================================================================================================


-- -----------------------------------------------------------------------------------------------------
-- common.v_databases_latest
-- Latest databases-registry snapshot per (instance_id, native database_id).
-- Dedupe via QUALIFY row_number() partitioned by (instance_id, database_id), newest collected_at wins.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_databases_latest AS
SELECT
    d.instance_id,
    d.database_id,
    d.platform,
    d.database_name,
    d.collected_at
FROM common.databases AS d
-- keep only the most recent registry row for each (instance, native database id)
QUALIFY row_number() OVER (
            PARTITION BY d.instance_id, d.database_id
            ORDER BY d.collected_at DESC
        ) = 1;


-- -----------------------------------------------------------------------------------------------------
-- common.v_eligible_databases
-- Latest db snapshot joined to instance registry, restricted to:
--   * production instances : status IN ('a','b') AND environment = 'P'
--   * user databases       : database_id > 4 AND name NOT IN system/uhtdba set
-- This is the canonical fan-out dimension for instance-level metrics and the system-DB exclusion
-- (legacy: Database_ID > 4 AND DatabaseName <> 'uhtdba'; system DBs master/tempdb/model/msdb are <= 4).
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_eligible_databases AS
SELECT
    dl.instance_id,
    dl.database_id,
    dl.platform,
    dl.database_name
FROM common.v_databases_latest AS dl
INNER JOIN common.instances AS i
    ON i.instance_id = dl.instance_id
WHERE
    -- production-only eligibility (legacy: i.Status in ('a','b') and i.Environment = 'P')
    i.status IN ('a', 'b')
    AND i.environment = 'P'
    -- system-database exclusion
    AND dl.database_id > 4
    AND dl.database_name NOT IN ('master', 'tempdb', 'model', 'msdb', 'uhtdba');


-- -----------------------------------------------------------------------------------------------------
-- common.v_cpu_hourly
-- Per (instance_id, coll_hr) AVG of engine / other / idle CPU.
-- Instance-level (no database grain). Legacy InstCPU aggregation (procedures.sql 2112-2135).
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_cpu_hourly AS
SELECT
    c.instance_id,
    date_trunc('hour', c.collected_at)        AS coll_hr,            -- hourly bucket
    AVG(c.engine_cpu_percent)                 AS avg_engine_cpu,     -- legacy SQLServerProcessCPUUtilization
    AVG(c.other_cpu_percent)                  AS avg_other_cpu,      -- legacy OtherProcessCPUUtilization
    AVG(c.system_idle_percent)                AS avg_idle_cpu        -- legacy SystemIdleProcess
FROM common.metric_cpu AS c
GROUP BY
    c.instance_id,
    date_trunc('hour', c.collected_at);


-- -----------------------------------------------------------------------------------------------------
-- common.v_memory_hourly
-- Per (instance_id, coll_hr) AVG page_residency_seconds (SQL Server PLE).
-- Memory stream is a curated superset; only PLE rows carry page_residency_seconds, so non-PLE rows
-- (e.g. PG buffer_hit_ratio) are excluded explicitly to keep buckets PLE-only.
-- Legacy InstPLE aggregation (procedures.sql 2151-2169).
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_memory_hourly AS
SELECT
    m.instance_id,
    date_trunc('hour', m.collected_at)        AS coll_hr,
    AVG(m.page_residency_seconds)             AS avg_ple_sec
FROM common.metric_memory AS m
WHERE m.page_residency_seconds IS NOT NULL    -- ignore non-PLE rows
GROUP BY
    m.instance_id,
    date_trunc('hour', m.collected_at);


-- -----------------------------------------------------------------------------------------------------
-- common.v_sessions_hourly
-- Per (instance_id, coll_hr) AVG active_sessions. Instance-level.
-- Legacy Sessions aggregation (procedures.sql 2184-2196). Feeds the blocker_ratio denominator.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_sessions_hourly AS
SELECT
    s.instance_id,
    date_trunc('hour', s.collected_at)        AS coll_hr,
    AVG(s.active_sessions)                     AS avg_active_sessions
FROM common.metric_sessions AS s
GROUP BY
    s.instance_id,
    date_trunc('hour', s.collected_at);


-- -----------------------------------------------------------------------------------------------------
-- common.v_io_latency_hourly
-- Per (instance_id, database_id, coll_hr) read/write latency in ms-per-operation, computed as
--   delta(io_stall) / delta(io_count)
-- from CUMULATIVE counters, faithful to legacy DatabaseIO -> DBIO (procedures.sql 2216-2324).
--
-- LEGACY ORDER (replicated): BUCKET FIRST, THEN LAG.
--   Step 1 (DatabaseIO): AVG the cumulative counters per (instance,db,hour) bucket, EXCLUDING the
--           restart hour, THEN
--   Step 2 (DBIO): LAG over the ordered hourly buckets to form deltas.
--
-- Guards reproduced faithfully:
--   * RESTART-HOUR EXCLUSION : drop any bucket whose hour == the restart hour (date_trunc of
--                              last_restart_at). Matches legacy exactly: in T-SQL the bucket-vs-bucket
--                              inequality is UNKNOWN when last_restart is NULL and the row is DROPPED;
--                              we reproduce that by requiring last_restart_at IS NOT NULL.
--   * RESET GUARD            : if lag > current the counter reset/rolled over -> delta = 0.
--   * ALL-LAGS-PRESENT       : legacy WHERE (all four lags <> 0) -> with LAG default 0 this drops the
--                              first bucket per (instance,db) and any bucket whose prior bucket carried
--                              a zero counter. Replicated as an explicit predicate.
--   * DIVISION-BY-ZERO GUARD : final WHERE (delta reads <> 0 AND delta writes <> 0); NULLIF on the
--                              divisor as belt-and-suspenders.
--   * INTEGER TRUNCATION     : legacy stored BIGINT/BIGINT, i.e. floor of ms-per-op. DuckDB returns a
--                              DOUBLE, so latency is floor()'d here to match the legacy stored value.
--                              (Bands are unaffected: floor(v) < N == v < N for integer cutoffs.)
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_io_latency_hourly AS
WITH database_io AS (
    -- Step 1: bucket cumulative counters to the hour (AVG within hour), with restart-hour exclusion.
    SELECT
        dio.instance_id,
        dio.database_id,
        date_trunc('hour', dio.collected_at)            AS coll_hr,
        AVG(dio.num_of_reads)                           AS num_of_reads,       -- cumulative (avg in hr)
        AVG(dio.io_stall_read_ms)                       AS io_wait_read_ms,    -- cumulative (avg in hr)
        AVG(dio.num_of_writes)                          AS num_of_writes,      -- cumulative (avg in hr)
        AVG(dio.io_stall_write_ms)                      AS io_wait_write_ms    -- cumulative (avg in hr)
    FROM common.metric_database_io AS dio
    WHERE
        -- restart-hour exclusion (legacy-exact): NULL last_restart -> UNKNOWN -> row dropped.
        dio.last_restart_at IS NOT NULL
        AND date_trunc('hour', dio.collected_at) <> date_trunc('hour', dio.last_restart_at)
    GROUP BY
        dio.instance_id,
        dio.database_id,
        date_trunc('hour', dio.collected_at)
),
lagged AS (
    -- Step 2: LAG each cumulative counter over the ordered hourly buckets per (instance, database).
    -- Default 0 on the first bucket (legacy LAG(...,1,0)).
    SELECT
        x.instance_id,
        x.database_id,
        x.coll_hr,
        x.num_of_reads,
        LAG(x.num_of_reads,    1, 0) OVER w  AS lag_num_of_reads,
        x.io_wait_read_ms,
        LAG(x.io_wait_read_ms, 1, 0) OVER w  AS lag_io_wait_read_ms,
        x.num_of_writes,
        LAG(x.num_of_writes,   1, 0) OVER w  AS lag_num_of_writes,
        x.io_wait_write_ms,
        LAG(x.io_wait_write_ms,1, 0) OVER w  AS lag_io_wait_write_ms
    FROM database_io AS x
    WINDOW w AS (
        PARTITION BY x.instance_id, x.database_id
        ORDER BY x.coll_hr
    )
),
deltas AS (
    -- All-lags-present requirement: skip the first bucket (all lags defaulted to 0) and any bucket
    -- whose prior bucket carried a zero counter (legacy: all four lag_* <> 0).
    SELECT
        y.instance_id,
        y.database_id,
        y.coll_hr,
        -- reset guard on each counter: lag <= current -> diff, else (reset/rollover) -> 0
        CASE WHEN y.lag_num_of_reads     <= y.num_of_reads
             THEN y.num_of_reads     - y.lag_num_of_reads     ELSE 0 END  AS num_of_reads,
        CASE WHEN y.lag_io_wait_read_ms  <= y.io_wait_read_ms
             THEN y.io_wait_read_ms  - y.lag_io_wait_read_ms  ELSE 0 END  AS io_wait_read_ms,
        CASE WHEN y.lag_num_of_writes    <= y.num_of_writes
             THEN y.num_of_writes    - y.lag_num_of_writes    ELSE 0 END  AS num_of_writes,
        CASE WHEN y.lag_io_wait_write_ms <= y.io_wait_write_ms
             THEN y.io_wait_write_ms - y.lag_io_wait_write_ms ELSE 0 END  AS io_wait_write_ms
    FROM lagged AS y
    WHERE
        y.lag_num_of_reads     <> 0
        AND y.lag_io_wait_read_ms  <> 0
        AND y.lag_num_of_writes    <> 0
        AND y.lag_io_wait_write_ms <> 0
)
SELECT
    z.instance_id,
    z.database_id,
    z.coll_hr,
    -- latency ms-per-op = stall-delta / op-count-delta. floor() reproduces legacy BIGINT/BIGINT
    -- integer truncation; NULLIF guards a zero divisor.
    floor(z.io_wait_read_ms  / NULLIF(z.num_of_reads,  0))  AS read_latency_ms,
    floor(z.io_wait_write_ms / NULLIF(z.num_of_writes, 0))  AS write_latency_ms
FROM deltas AS z
WHERE
    -- division-by-zero guard (legacy final WHERE): require non-zero delta op counts
    z.num_of_reads  <> 0
    AND z.num_of_writes <> 0;


-- -----------------------------------------------------------------------------------------------------
-- common.v_blocking_hourly
-- Per (instance_id, database_id, coll_hr) MAX blocked_session_count.
-- metric_blocking.blocked_session_count is the ALREADY-COLLAPSED per-collection count of blocked
-- sessions (one value per (instance,db,collection)), so MAX() over the hour reproduces legacy
-- max(Count_Sessions_Per_Coll). Rows only exist when blocking was present -> absence later becomes
-- 0 blockers / band 0 via the LEFT JOIN + COALESCE in v_health_scores.
-- Legacy LeadBlockers peak feeding dbBLKR (procedures.sql 2342-2414).
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_blocking_hourly AS
SELECT
    b.instance_id,
    b.database_id,
    date_trunc('hour', b.collected_at)        AS coll_hr,
    MAX(b.blocked_session_count)              AS max_blocking_sessions
FROM common.metric_blocking AS b
GROUP BY
    b.instance_id,
    b.database_id,
    date_trunc('hour', b.collected_at);


-- -----------------------------------------------------------------------------------------------------
-- common.v_health_scores
-- The per-(instance_id, database_id, coll_hr) row equivalent to legacy ReportInstanceAllMetrics.
-- Column list (names + order) is byte-identical to common.health_scores.
--
-- Composition:
--   * driver / grain = eligible databases x the hours that have CPU data (cpu is the spine; legacy
--     joined Databases to the InstCPU-anchored set). Instance-level CPU/PLE/sessions are FANNED OUT
--     across each instance's eligible databases.
--   * per-database latency + blocking joined in on (instance_id, database_id, coll_hr).
--   * sessions joined on (instance_id, coll_hr) to supply the blocker_ratio denominator.
--   * banding consults common.score_thresholds AND its `direction` column (bands are DATA).
--   * IN-FLIGHT-HOUR EXCLUSION: drop the still-accumulating current hour (legacy line 2463), anchored
--     to UTC so it is independent of session timezone.
--
-- blocker_ratio = MAX(blocking) / NULLIF(AVG(active_sessions), 0)   (legacy max/avg ratio).
-- irc_index = cpu_index + memory_index + read_latency_index + write_latency_index + blocking_index.
-- Missing components (NULL PLE/latency/blocking) map to band 0 (legacy isnull(...,0) behavior).
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_health_scores AS
WITH base AS (
    SELECT
        ed.instance_id,
        ed.database_id,
        ed.platform,
        cpu.coll_hr,

        -- ---- raw instance-level metrics, fanned across this instance's eligible databases ----
        cpu.avg_engine_cpu,
        cpu.avg_other_cpu,
        cpu.avg_idle_cpu,
        mem.avg_ple_sec,
        ses.avg_active_sessions,

        -- ---- per-database metrics ----
        io.read_latency_ms,
        io.write_latency_ms,
        -- blocking absent for the bucket => treat as 0 peak blockers (band 0 healthy)
        COALESCE(blk.max_blocking_sessions, 0)                              AS max_blocking_sessions,

        -- cpu scored metric: SQL process + other process CPU (idle ignored), legacy sum
        (cpu.avg_engine_cpu + cpu.avg_other_cpu)                           AS cpu_busy_pct,

        -- blocker ratio = peak blockers / avg active sessions (NULLIF guards 0/NULL sessions)
        COALESCE(blk.max_blocking_sessions, 0)
            / NULLIF(ses.avg_active_sessions, 0)                          AS blocker_ratio
    FROM common.v_eligible_databases AS ed
    -- CPU is the instance-level spine; one bucket per instance-hour, fanned across databases
    INNER JOIN common.v_cpu_hourly AS cpu
        ON cpu.instance_id = ed.instance_id
    -- instance-level memory (PLE) for the same instance-hour (may be absent -> NULL PLE)
    LEFT JOIN common.v_memory_hourly AS mem
        ON mem.instance_id = ed.instance_id
        AND mem.coll_hr     = cpu.coll_hr
    -- instance-level sessions for the same instance-hour (denominator of blocker_ratio)
    LEFT JOIN common.v_sessions_hourly AS ses
        ON ses.instance_id = ed.instance_id
        AND ses.coll_hr     = cpu.coll_hr
    -- per-database IO latency for this database-hour
    LEFT JOIN common.v_io_latency_hourly AS io
        ON io.instance_id = ed.instance_id
        AND io.database_id = ed.database_id
        AND io.coll_hr      = cpu.coll_hr
    -- per-database blocking peak for this database-hour
    LEFT JOIN common.v_blocking_hourly AS blk
        ON blk.instance_id = ed.instance_id
        AND blk.database_id = ed.database_id
        AND blk.coll_hr      = cpu.coll_hr
    WHERE
        -- in-flight-hour exclusion (legacy line 2463): drop the current partial hour, UTC-anchored.
        cpu.coll_hr < date_trunc('hour', CAST(now() AT TIME ZONE 'UTC' AS TIMESTAMP))
),
-- pull each band's thresholds + direction out as scalar columns to keep the CASE logic flat.
th AS (
    SELECT
        MAX(CASE WHEN index_name = 'cpu'           THEN direction      END) AS cpu_dir,
        MAX(CASE WHEN index_name = 'cpu'           THEN warn_threshold END) AS cpu_warn,
        MAX(CASE WHEN index_name = 'cpu'           THEN crit_threshold END) AS cpu_crit,
        MAX(CASE WHEN index_name = 'memory'        THEN direction      END) AS mem_dir,
        MAX(CASE WHEN index_name = 'memory'        THEN warn_threshold END) AS mem_warn,
        MAX(CASE WHEN index_name = 'memory'        THEN crit_threshold END) AS mem_crit,
        MAX(CASE WHEN index_name = 'read_latency'  THEN direction      END) AS rl_dir,
        MAX(CASE WHEN index_name = 'read_latency'  THEN warn_threshold END) AS rl_warn,
        MAX(CASE WHEN index_name = 'read_latency'  THEN crit_threshold END) AS rl_crit,
        MAX(CASE WHEN index_name = 'write_latency' THEN direction      END) AS wl_dir,
        MAX(CASE WHEN index_name = 'write_latency' THEN warn_threshold END) AS wl_warn,
        MAX(CASE WHEN index_name = 'write_latency' THEN crit_threshold END) AS wl_crit,
        MAX(CASE WHEN index_name = 'blocker'       THEN direction      END) AS blk_dir,
        MAX(CASE WHEN index_name = 'blocker'       THEN warn_threshold END) AS blk_warn,
        MAX(CASE WHEN index_name = 'blocker'       THEN crit_threshold END) AS blk_crit
    FROM common.score_thresholds
),
scored AS (
    SELECT
        b.instance_id,
        b.database_id,
        b.platform,
        b.coll_hr,
        CAST(year(b.coll_hr)  AS SMALLINT)                                 AS year,
        CAST(month(b.coll_hr) AS TINYINT)                                  AS month,

        -- raw passthrough columns (mirror ReportInstanceAllMetrics) with TRY_CAST to target types
        TRY_CAST(b.avg_engine_cpu        AS SMALLINT)                      AS sql_cpu,
        TRY_CAST(b.avg_idle_cpu          AS SMALLINT)                      AS idl_cpu,
        TRY_CAST(b.avg_other_cpu         AS SMALLINT)                      AS oth_cpu,
        TRY_CAST(b.avg_ple_sec           AS BIGINT)                        AS ple_sec,
        TRY_CAST(b.read_latency_ms       AS BIGINT)                        AS read_latency_ms,
        TRY_CAST(b.write_latency_ms      AS BIGINT)                        AS write_latency_ms,
        TRY_CAST(b.max_blocking_sessions AS INTEGER)                       AS max_blocking_sessions,
        TRY_CAST(b.avg_active_sessions   AS INTEGER)                       AS avg_active_sessions,
        CAST(b.blocker_ratio             AS DOUBLE)                        AS blocker_ratio,

        -- CPU index: direction-driven banding (cpu = higher_worse). NULL busy% -> band 0.
        CAST(
            CASE
                WHEN b.cpu_busy_pct IS NULL                  THEN 0
                WHEN th.cpu_dir = 'higher_worse'
                     THEN CASE WHEN b.cpu_busy_pct < th.cpu_warn THEN 0
                               WHEN b.cpu_busy_pct < th.cpu_crit THEN 1
                               ELSE 2 END
                ELSE -- lower_worse
                     CASE WHEN b.cpu_busy_pct >= th.cpu_warn THEN 0
                          WHEN b.cpu_busy_pct >= th.cpu_crit THEN 1
                          ELSE 2 END
            END AS TINYINT)                                                AS cpu_index,

        -- Memory/PLE index: direction-driven (memory = lower_worse). NULL PLE -> band 0.
        CAST(
            CASE
                WHEN b.avg_ple_sec IS NULL                   THEN 0
                WHEN th.mem_dir = 'higher_worse'
                     THEN CASE WHEN b.avg_ple_sec < th.mem_warn THEN 0
                               WHEN b.avg_ple_sec < th.mem_crit THEN 1
                               ELSE 2 END
                ELSE -- lower_worse: ple >= warn(3600) ->0, >= crit(300) ->1, else 2
                     CASE WHEN b.avg_ple_sec >= th.mem_warn THEN 0
                          WHEN b.avg_ple_sec >= th.mem_crit THEN 1
                          ELSE 2 END
            END AS TINYINT)                                                AS memory_index,

        -- Read latency index: direction-driven (read_latency = higher_worse). NULL -> band 0.
        CAST(
            CASE
                WHEN b.read_latency_ms IS NULL               THEN 0
                WHEN th.rl_dir = 'higher_worse'
                     THEN CASE WHEN b.read_latency_ms < th.rl_warn THEN 0
                               WHEN b.read_latency_ms < th.rl_crit THEN 1
                               ELSE 2 END
                ELSE -- lower_worse
                     CASE WHEN b.read_latency_ms >= th.rl_warn THEN 0
                          WHEN b.read_latency_ms >= th.rl_crit THEN 1
                          ELSE 2 END
            END AS TINYINT)                                                AS read_latency_index,

        -- Write latency index: direction-driven (write_latency = higher_worse). NULL -> band 0.
        CAST(
            CASE
                WHEN b.write_latency_ms IS NULL              THEN 0
                WHEN th.wl_dir = 'higher_worse'
                     THEN CASE WHEN b.write_latency_ms < th.wl_warn THEN 0
                               WHEN b.write_latency_ms < th.wl_crit THEN 1
                               ELSE 2 END
                ELSE -- lower_worse
                     CASE WHEN b.write_latency_ms >= th.wl_warn THEN 0
                          WHEN b.write_latency_ms >= th.wl_crit THEN 1
                          ELSE 2 END
            END AS TINYINT)                                                AS write_latency_index,

        -- Blocking index: direction-driven (blocker = higher_worse). NULL ratio -> band 0.
        CAST(
            CASE
                WHEN b.blocker_ratio IS NULL                 THEN 0
                WHEN th.blk_dir = 'higher_worse'
                     THEN CASE WHEN b.blocker_ratio < th.blk_warn THEN 0
                               WHEN b.blocker_ratio < th.blk_crit THEN 1
                               ELSE 2 END
                ELSE -- lower_worse
                     CASE WHEN b.blocker_ratio >= th.blk_warn THEN 0
                          WHEN b.blocker_ratio >= th.blk_crit THEN 1
                          ELSE 2 END
            END AS TINYINT)                                                AS blocking_index
    FROM base AS b
    CROSS JOIN th
)
SELECT
    s.instance_id,
    s.database_id,
    s.platform,
    s.coll_hr,
    s.year,
    s.month,
    s.sql_cpu,
    s.idl_cpu,
    s.oth_cpu,
    s.ple_sec,
    s.read_latency_ms,
    s.write_latency_ms,
    s.max_blocking_sessions,
    s.avg_active_sessions,
    s.blocker_ratio,
    s.cpu_index,
    s.memory_index,
    s.read_latency_index,
    s.write_latency_index,
    s.blocking_index,
    -- IRC = sum of the five band indexes (0..10, higher = more problematic)
    CAST(
        s.cpu_index
      + s.memory_index
      + s.read_latency_index
      + s.write_latency_index
      + s.blocking_index AS TINYINT)                                       AS irc_index
FROM scored AS s;


-- -----------------------------------------------------------------------------------------------------
-- common.v_health_scores_instance
-- Instance-level rollup per (instance_id, coll_hr): worst-DB-wins, i.e. MAX of each band index
-- across the instance's databases, plus MAX(irc_index). Surfaces the most problematic database as
-- the instance's hourly posture.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_health_scores_instance AS
SELECT
    hs.instance_id,
    hs.platform,
    hs.coll_hr,
    MAX(hs.cpu_index)            AS cpu_index,
    MAX(hs.memory_index)         AS memory_index,
    MAX(hs.read_latency_index)   AS read_latency_index,
    MAX(hs.write_latency_index)  AS write_latency_index,
    MAX(hs.blocking_index)       AS blocking_index,
    MAX(hs.irc_index)            AS irc_index
FROM common.v_health_scores AS hs
GROUP BY
    hs.instance_id,
    hs.platform,
    hs.coll_hr;


-- -----------------------------------------------------------------------------------------------------
-- common.v_problematic_instances
-- Home dashboard. An instance is "problematic" if EITHER:
--   (A) UNRESPONSIVE: derived from common.pings (columns is_success BOOLEAN, collected_at TIMESTAMP).
--       Faithful to legacy vwGetUnavailableInstancesLive (views.sql 599-622): >= 3 failed pings in
--       the last 4 days, with NO successful ping after those failures, but HAD a successful ping in
--       the last 28 days (recently alive, not abandoned). Time math is UTC-anchored so the windows
--       are independent of session timezone.
--   (B) HIGH IRC: on its most-recent scored coll_hr the instance rollup irc_index is elevated.
--       PRODUCT DECISION (not a legacy constant; the legacy view had no IRC gate): threshold = 2,
--       i.e. at least one critical band or two warnings on the worst database. Latest hour per
--       instance via QUALIFY.
-- Ordered worst-first: unresponsive instances first, then by IRC desc, then most failures.
-- -----------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW common.v_problematic_instances AS
WITH ping_window AS (
    -- restrict to recent pings once (28-day "recently alive" envelope covers both sub-checks),
    -- UTC-anchored so the boundary is deterministic regardless of connection timezone.
    SELECT
        p.instance_id,
        p.collected_at,
        p.is_success
    FROM common.pings AS p
    WHERE p.collected_at > (CAST(now() AT TIME ZONE 'UTC' AS TIMESTAMP) - INTERVAL 28 DAY)
),
last_success AS (
    -- most recent successful ping per instance within the 28-day window
    SELECT
        pw.instance_id,
        MAX(pw.collected_at) AS last_success_at
    FROM ping_window AS pw
    WHERE pw.is_success
    GROUP BY pw.instance_id
),
recent_failures AS (
    -- failed pings in the last 4 days that occurred AFTER the instance's last successful ping
    -- (i.e. no success since) — count them; legacy HAVING Count(*) >= 3.
    SELECT
        pw.instance_id,
        COUNT(*) AS failed_pings
    FROM ping_window AS pw
    INNER JOIN last_success AS ls
        ON ls.instance_id = pw.instance_id
    WHERE
        pw.is_success = FALSE
        AND pw.collected_at > (CAST(now() AT TIME ZONE 'UTC' AS TIMESTAMP) - INTERVAL 4 DAY)
        AND pw.collected_at > ls.last_success_at        -- no success after these failures
    GROUP BY pw.instance_id
    HAVING COUNT(*) >= 3
),
unresponsive AS (
    -- production instances that are currently unreachable by the ping heuristic above
    SELECT
        i.instance_id,
        rf.failed_pings,
        ls.last_success_at
    FROM recent_failures AS rf
    INNER JOIN common.instances AS i
        ON i.instance_id = rf.instance_id
    INNER JOIN last_success AS ls
        ON ls.instance_id = rf.instance_id
    WHERE i.status IN ('a', 'b')                         -- production/active eligibility
),
latest_health AS (
    -- the instance's most-recent scored hour (one row per instance) via QUALIFY
    SELECT
        hsi.instance_id,
        hsi.coll_hr,
        hsi.irc_index
    FROM common.v_health_scores_instance AS hsi
    QUALIFY row_number() OVER (
                PARTITION BY hsi.instance_id
                ORDER BY hsi.coll_hr DESC
            ) = 1
),
high_irc AS (
    -- elevated IRC on the latest hour (product-decision cutoff >= 2; see header)
    SELECT
        lh.instance_id,
        lh.coll_hr        AS latest_coll_hr,
        lh.irc_index
    FROM latest_health AS lh
    WHERE lh.irc_index >= 2
),
-- union the two problem populations onto the instance keyset
problem_keys AS (
    SELECT instance_id FROM unresponsive
    UNION
    SELECT instance_id FROM high_irc
)
SELECT
    i.instance_id,
    i.instance_fqn,
    i.platform,
    i.environment,
    i.status,
    -- flags describing WHY the instance is problematic
    (u.instance_id IS NOT NULL)                 AS is_unresponsive,
    (h.instance_id IS NOT NULL)                 AS is_high_irc,
    u.failed_pings,
    u.last_success_at,
    h.latest_coll_hr,
    COALESCE(h.irc_index, 0)                      AS irc_index
FROM problem_keys AS pk
INNER JOIN common.instances AS i
    ON i.instance_id = pk.instance_id
LEFT JOIN unresponsive AS u
    ON u.instance_id = pk.instance_id
LEFT JOIN high_irc AS h
    ON h.instance_id = pk.instance_id
ORDER BY
    is_unresponsive DESC,                        -- unreachable instances first
    irc_index       DESC,                        -- then worst health
    u.failed_pings  DESC NULLS LAST;             -- then most ping failures
