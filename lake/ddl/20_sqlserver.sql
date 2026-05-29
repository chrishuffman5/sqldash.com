-- SQLDash lake — sqlserver (engine-only) tables
-- Concepts with no cross-platform analog live here and join back to common on the integer keys.

-- SQL-Server-only extension of common.instance_details (1:1 by instance_id + collected_at).
CREATE TABLE IF NOT EXISTS sqlserver.instance_details_ext (
    instance_id                   INTEGER   NOT NULL,
    collected_at                  TIMESTAMP NOT NULL,
    is_hadr_enabled               BOOLEAN,
    hadr_manager_status           SMALLINT,
    is_mirrored                   BOOLEAN,
    available_physical_memory_mb  INTEGER,
    bpool_committed_mb            INTEGER,
    bpool_committed_target_mb     INTEGER,
    bpool_visible_target_mb       INTEGER,
    deadlocks_per_hour            INTEGER,
    max_workers_count             INTEGER,
    scheduler_count               INTEGER,
    virtual_machine_type          INTEGER
);

-- AlwaysOn availability database replica health (deferred detail; created now for shape).
CREATE TABLE IF NOT EXISTS sqlserver.ha_databases (
    instance_id                INTEGER   NOT NULL,
    database_id                INTEGER   NOT NULL,
    collected_at               TIMESTAMP NOT NULL,
    year                       SMALLINT  NOT NULL,
    month                      TINYINT   NOT NULL,
    day                        TINYINT   NOT NULL,
    availability_group_name    VARCHAR,
    availability_replica_name  VARCHAR,
    synchronization_state      VARCHAR,
    synchronization_health     VARCHAR,
    is_suspended               BOOLEAN,
    is_failover_ready          BOOLEAN,
    estimated_data_loss_sec    INTEGER,
    log_send_queue_kb          BIGINT,
    redo_queue_kb              BIGINT
);

-- Curated sp_configure / sys.configurations key settings (one row per setting). Config-drift telemetry;
-- current-state snapshot (NOT partitioned, low volume). is_pending = configured value <> running value.
CREATE TABLE IF NOT EXISTS sqlserver.config_settings (
    instance_id       INTEGER   NOT NULL,
    collected_at      TIMESTAMP NOT NULL,
    setting_name      VARCHAR   NOT NULL,
    configured_value  BIGINT,
    running_value     BIGINT,
    is_advanced       BOOLEAN,
    is_dynamic        BOOLEAN,
    is_pending        BOOLEAN
);

-- Active GLOBAL trace flags (DBCC TRACESTATUS(-1)); one row per enabled flag. Current-state snapshot.
CREATE TABLE IF NOT EXISTS sqlserver.trace_flags (
    instance_id   INTEGER   NOT NULL,
    collected_at  TIMESTAMP NOT NULL,
    trace_flag    INTEGER   NOT NULL,
    is_enabled    BOOLEAN,
    is_global     BOOLEAN
);

-- Last full/diff/log backup per database (RPO posture). Per-db snapshot; staleness scored read-side.
CREATE TABLE IF NOT EXISTS sqlserver.backup_status (
    instance_id                 INTEGER   NOT NULL,
    database_id                 INTEGER   NOT NULL,
    collected_at                TIMESTAMP NOT NULL,
    year                        SMALLINT  NOT NULL,
    month                       TINYINT   NOT NULL,
    day                         TINYINT   NOT NULL,
    database_name               VARCHAR,
    recovery_model              VARCHAR,
    log_reuse_wait_desc         VARCHAR,
    last_full_backup            TIMESTAMP,
    last_diff_backup            TIMESTAMP,
    last_log_backup             TIMESTAMP,
    last_full_size_bytes        BIGINT,
    last_full_compressed_bytes  BIGINT
);

-- Corruption posture per database: state, page_verify, read-only, recorded suspect (corrupt) page count.
CREATE TABLE IF NOT EXISTS sqlserver.integrity_status (
    instance_id         INTEGER   NOT NULL,
    database_id         INTEGER   NOT NULL,
    collected_at        TIMESTAMP NOT NULL,
    year                SMALLINT  NOT NULL,
    month               TINYINT   NOT NULL,
    day                 TINYINT   NOT NULL,
    database_name       VARCHAR,
    state               VARCHAR,
    page_verify_option  VARCHAR,
    is_read_only        BOOLEAN,
    suspect_page_count  INTEGER
);

-- WSFC/Pacemaker cluster the AG/FCI rides on, as seen by the instance: quorum + per-member state/votes.
-- One row per cluster member; zero rows on a non-clustered/non-HADR instance.
CREATE TABLE IF NOT EXISTS sqlserver.ha_cluster_members (
    instance_id   INTEGER   NOT NULL,
    collected_at  TIMESTAMP NOT NULL,
    year          SMALLINT  NOT NULL,
    month         TINYINT   NOT NULL,
    day           TINYINT   NOT NULL,
    cluster_name  VARCHAR,
    quorum_type   VARCHAR,
    quorum_state  VARCHAR,
    member_name   VARCHAR,
    member_type   VARCHAR,
    member_state  VARCHAR,
    quorum_votes  TINYINT
);

-- AlwaysOn availability replica state/health (per replica, instance view). Zero rows on a non-AG instance.
CREATE TABLE IF NOT EXISTS sqlserver.ha_availability_replicas (
    instance_id                INTEGER   NOT NULL,
    collected_at               TIMESTAMP NOT NULL,
    year                       SMALLINT  NOT NULL,
    month                      TINYINT   NOT NULL,
    day                        TINYINT   NOT NULL,
    availability_group_name    VARCHAR,
    replica_server_name        VARCHAR,
    replica_role               VARCHAR,   -- NOT current_role (Postgres reserved word; breaks DuckLake inlining)
    availability_mode          VARCHAR,
    failover_mode              VARCHAR,
    seeding_mode               VARCHAR,
    operational_state          VARCHAR,
    connected_state            VARCHAR,
    recovery_health            VARCHAR,
    sync_health                VARCHAR,
    is_local                   BOOLEAN,
    last_connect_error_number  INTEGER,
    last_connect_error_at      TIMESTAMP
);

-- Database mirroring session health (deprecated feature, still seen in fleets). Zero rows when unused.
CREATE TABLE IF NOT EXISTS sqlserver.mirroring_health (
    instance_id       INTEGER   NOT NULL,
    database_id       INTEGER   NOT NULL,
    collected_at      TIMESTAMP NOT NULL,
    year              SMALLINT  NOT NULL,
    month             TINYINT   NOT NULL,
    day               TINYINT   NOT NULL,
    database_name     VARCHAR,
    mirroring_state   VARCHAR,
    mirroring_role    VARCHAR,
    safety_level      VARCHAR,
    partner_instance  VARCHAR,
    witness_name      VARCHAR,
    witness_state     VARCHAR,
    redo_queue_kb     BIGINT
);
