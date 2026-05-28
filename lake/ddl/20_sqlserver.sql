-- SQLDash lake — sqlserver (engine-only) tables
-- Concepts with no cross-platform analog live here and join back to common on the surrogate keys.

-- SQL-Server-only extension of common.instance_details (1:1 by instance_key + collected_at).
CREATE TABLE IF NOT EXISTS sqlserver.instance_details_ext (
    instance_key                  UUID      NOT NULL,
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
    virtual_machine_type          INTEGER,
    source_query_id               VARCHAR   NOT NULL
);

-- AlwaysOn availability database replica health (deferred detail; created now for shape).
CREATE TABLE IF NOT EXISTS sqlserver.ha_databases (
    instance_key               UUID      NOT NULL,
    database_key               UUID      NOT NULL,
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
    redo_queue_kb              BIGINT,
    source_query_id            VARCHAR   NOT NULL
);
