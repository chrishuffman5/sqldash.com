-- SQLDash lake — common (cross-platform) tables
-- Conventions: snake_case; UTC `collected_at` on every fact row; booleans is_*;
-- self-describing tuple on every fact row: instance_key, platform, collected_at, source_query_id.
-- Time-series tables carry stamped year/month/day partition columns (derived from collected_at
-- by the collector) and are partitioned by (platform, year, month, day).

------------------------------------------------------------------------------------------------
-- Registry / inventory (dimensions — not partitioned, low volume)
------------------------------------------------------------------------------------------------

-- Instance registry. instance_key is minted by the registration authority (get-or-create on
-- normalized instance_fqn). Uniqueness is enforced at the registration path, NOT by the lake.
CREATE TABLE IF NOT EXISTS common.instances (
    instance_key     UUID        NOT NULL,
    instance_fqn     VARCHAR     NOT NULL,   -- normalized 'server\instance:port' (natural key)
    instance_name    VARCHAR,
    platform         VARCHAR     NOT NULL,   -- 'sqlserver' | 'postgres'
    environment      VARCHAR,                -- 'P','Q',...  (legacy Environment)
    status           VARCHAR,                -- 'a','b' active; legacy Status
    category         VARCHAR,
    engine_version   VARCHAR,
    is_clustered     BOOLEAN,
    dmz              BOOLEAN,
    domain           VARCHAR,
    auth_mode        VARCHAR     NOT NULL,   -- 'integrated' | 'sql' | 'vault-ref'
    registered_at    TIMESTAMP   NOT NULL,
    updated_at       TIMESTAMP
);

-- Database registry. database_key is get-or-create on (instance_key, normalized database_name)
-- so it survives native database_id/oid reuse after DROP and AG failover.
CREATE TABLE IF NOT EXISTS common.databases (
    instance_key         UUID      NOT NULL,
    database_key         UUID      NOT NULL,
    platform             VARCHAR   NOT NULL,
    database_id          INTEGER,             -- native id (non-key attribute)
    database_name        VARCHAR   NOT NULL,
    create_date          TIMESTAMP,
    compatibility_level  SMALLINT,
    collation_name       VARCHAR,
    recovery_model       VARCHAR,
    state                VARCHAR,
    user_access          VARCHAR,
    is_read_only         BOOLEAN,
    is_mirrored          BOOLEAN,
    is_alwayson          BOOLEAN,
    owner_name           VARCHAR,
    data_file_size_mb    INTEGER,
    log_file_size_mb     INTEGER,
    collected_at         TIMESTAMP NOT NULL,
    source_query_id      VARCHAR   NOT NULL
);

-- Point-in-time instance details (current state; one row per instance per collection).
CREATE TABLE IF NOT EXISTS common.instance_details (
    instance_key            UUID      NOT NULL,
    platform                VARCHAR   NOT NULL,
    server_name             VARCHAR,
    product_version         VARCHAR,
    product_level           VARCHAR,
    edition                 VARCHAR,
    engine_edition          SMALLINT,
    collation_default       VARCHAR,
    is_clustered            BOOLEAN,
    is_full_text_installed  BOOLEAN,
    logical_cpu_count       INTEGER,
    physical_cpu_count      INTEGER,
    hyperthread_ratio       INTEGER,
    physical_memory_mb      BIGINT,
    min_memory_mb           INTEGER,
    max_memory_mb           INTEGER,
    max_dop                 SMALLINT,
    engine_start_time       TIMESTAMP,
    collected_at            TIMESTAMP NOT NULL,
    source_query_id         VARCHAR   NOT NULL
);

------------------------------------------------------------------------------------------------
-- Telemetry streams (time-series — partitioned by platform/year/month/day)
------------------------------------------------------------------------------------------------

-- Heartbeat / reachability. Drives discovery eligibility and "unresponsive" detection.
CREATE TABLE IF NOT EXISTS common.pings (
    instance_key     UUID      NOT NULL,
    platform         VARCHAR   NOT NULL,
    collected_at     TIMESTAMP NOT NULL,
    year             SMALLINT  NOT NULL,
    month            TINYINT   NOT NULL,
    day              TINYINT   NOT NULL,
    response_time_ms INTEGER,
    is_success       BOOLEAN   NOT NULL,
    source_query_id  VARCHAR   NOT NULL
);

CREATE TABLE IF NOT EXISTS common.metric_cpu (
    instance_key        UUID      NOT NULL,
    platform            VARCHAR   NOT NULL,
    collected_at        TIMESTAMP NOT NULL,
    year                SMALLINT  NOT NULL,
    month               TINYINT   NOT NULL,
    day                 TINYINT   NOT NULL,
    engine_cpu_percent  SMALLINT,            -- SQL: SQLServerProcessCPUUtilization
    other_cpu_percent   SMALLINT,            -- SQL: OtherProcessCPUUtilization
    system_idle_percent SMALLINT,
    source_query_id     VARCHAR   NOT NULL
);

-- Unified memory stream (curated superset; rows are sparse per platform/collector).
CREATE TABLE IF NOT EXISTS common.metric_memory (
    instance_key            UUID      NOT NULL,
    platform                VARCHAR   NOT NULL,
    collected_at            TIMESTAMP NOT NULL,
    year                    SMALLINT  NOT NULL,
    month                   TINYINT   NOT NULL,
    day                     TINYINT   NOT NULL,
    page_residency_seconds  BIGINT,          -- SQL Server PLE only
    buffer_hit_ratio        DECIMAL(5,2),    -- PostgreSQL only (future)
    grants_pending          INTEGER,         -- SQL only
    grants_outstanding      INTEGER,         -- SQL only
    source_query_id         VARCHAR   NOT NULL
);

CREATE TABLE IF NOT EXISTS common.metric_sessions (
    instance_key     UUID      NOT NULL,
    platform         VARCHAR   NOT NULL,
    collected_at     TIMESTAMP NOT NULL,
    year             SMALLINT  NOT NULL,
    month            TINYINT   NOT NULL,
    day              TINYINT   NOT NULL,
    active_sessions  INTEGER,
    source_query_id  VARCHAR   NOT NULL
);

-- Per-database IO. CUMULATIVE counters — deltas are computed read-side in the scoring views,
-- with reset/restart guards. last_restart_at enables the restart-hour exclusion.
CREATE TABLE IF NOT EXISTS common.metric_database_io (
    instance_key          UUID      NOT NULL,
    database_key          UUID      NOT NULL,
    platform              VARCHAR   NOT NULL,
    collected_at          TIMESTAMP NOT NULL,
    year                  SMALLINT  NOT NULL,
    month                 TINYINT   NOT NULL,
    day                   TINYINT   NOT NULL,
    last_restart_at       TIMESTAMP,
    num_of_reads          BIGINT,
    num_of_bytes_read     BIGINT,
    io_stall_read_ms      BIGINT,
    num_of_writes         BIGINT,
    num_of_bytes_written  BIGINT,
    io_stall_write_ms     BIGINT,
    io_stall              BIGINT,
    size_on_disk_bytes    BIGINT,
    source_query_id       VARCHAR   NOT NULL
);

-- Per-database blocking summary (count of blocked sessions per collection). Feeds blocker ratio.
CREATE TABLE IF NOT EXISTS common.metric_blocking (
    instance_key           UUID      NOT NULL,
    database_key           UUID      NOT NULL,
    platform               VARCHAR   NOT NULL,
    collected_at           TIMESTAMP NOT NULL,
    year                   SMALLINT  NOT NULL,
    month                  TINYINT   NOT NULL,
    day                    TINYINT   NOT NULL,
    blocked_session_count  INTEGER,
    source_query_id        VARCHAR   NOT NULL
);

------------------------------------------------------------------------------------------------
-- Operational logs
------------------------------------------------------------------------------------------------

-- One row per (collector, instance) per cycle — including empty collections (status='empty').
CREATE TABLE IF NOT EXISTS common.collection_log (
    instance_key     UUID,
    platform         VARCHAR,
    collector_name   VARCHAR   NOT NULL,
    collected_at     TIMESTAMP NOT NULL,
    year             SMALLINT  NOT NULL,
    month            TINYINT   NOT NULL,
    day              TINYINT   NOT NULL,
    rows_collected   INTEGER,
    duration_ms      INTEGER,
    status           VARCHAR,              -- 'ok' | 'empty' | 'error'
    source_query_id  VARCHAR   NOT NULL
);

CREATE TABLE IF NOT EXISTS common.collection_errors (
    instance_key     UUID,
    instance_fqn     VARCHAR,
    platform         VARCHAR,
    collector_name   VARCHAR,
    collected_at     TIMESTAMP NOT NULL,
    year             SMALLINT  NOT NULL,
    month            TINYINT   NOT NULL,
    day              TINYINT   NOT NULL,
    error_type       VARCHAR,
    error_message    VARCHAR
);

------------------------------------------------------------------------------------------------
-- Scoring (materialized by the scoring view chain — see lake/views/scoring.sql)
------------------------------------------------------------------------------------------------

-- Per-(instance,database,hour) health score — faithful to legacy ReportInstanceAllMetrics.
CREATE TABLE IF NOT EXISTS common.health_scores (
    instance_key          UUID      NOT NULL,
    database_key          UUID      NOT NULL,
    platform              VARCHAR   NOT NULL,
    coll_hr               TIMESTAMP NOT NULL,   -- hourly bucket
    year                  SMALLINT  NOT NULL,
    month                 TINYINT   NOT NULL,
    sql_cpu               SMALLINT,
    idl_cpu               SMALLINT,
    oth_cpu               SMALLINT,
    ple_sec               BIGINT,
    read_latency_ms       BIGINT,
    write_latency_ms      BIGINT,
    max_blocking_sessions INTEGER,
    avg_active_sessions   INTEGER,
    blocker_ratio         DOUBLE,
    cpu_index             TINYINT,
    memory_index          TINYINT,
    read_latency_index    TINYINT,
    write_latency_index   TINYINT,
    blocking_index        TINYINT,
    irc_index             TINYINT               -- 0-10 composite (higher = more problematic)
);

-- Scoring band thresholds as DATA (a band tweak is a row change, not DDL).
CREATE TABLE IF NOT EXISTS common.score_thresholds (
    index_name      VARCHAR NOT NULL,   -- 'cpu' | 'memory' | 'read_latency' | 'write_latency' | 'blocker'
    direction       VARCHAR NOT NULL,   -- 'higher_worse' | 'lower_worse'
    warn_threshold  DOUBLE  NOT NULL,   -- -> band 1
    crit_threshold  DOUBLE  NOT NULL    -- -> band 2
);
