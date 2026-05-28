-- SQLDash lake — partitioning for time-series tables.
-- Hot streams: (platform, year, month, day). Hourly rollup (health_scores): (platform, year, month).
-- Registry/dimension tables are intentionally NOT partitioned (low volume).
-- Never partition by raw instance_key (UUID -> file explosion); it stays a column with min/max stats.

ALTER TABLE common.pings              SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.metric_cpu         SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.metric_memory      SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.metric_sessions    SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.metric_database_io SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.metric_blocking    SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.collection_log     SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.collection_errors  SET PARTITIONED BY (platform, year, month, day);
ALTER TABLE common.health_scores      SET PARTITIONED BY (platform, year, month);
ALTER TABLE sqlserver.ha_databases    SET PARTITIONED BY (year, month, day);  -- platform implicit (sqlserver schema)
