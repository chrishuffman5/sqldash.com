-- SQLDash lake — schema namespaces
-- Run against an ATTACHed DuckLake (see lake/apply-local.ps1).
--
-- Schema-per-platform model:
--   common.*    cross-platform concepts; rows distinguished by the `platform` column.
--               A curated ADDITIVE superset — a column may apply to only one engine
--               (e.g. metric_memory.page_residency_seconds is SQL-only PLE).
--   sqlserver.* SQL-Server-only concepts (HADR/AlwaysOn, mirroring, buffer pool, backups).
--   postgres.*  future, same pattern.

CREATE SCHEMA IF NOT EXISTS common;
CREATE SCHEMA IF NOT EXISTS sqlserver;
-- CREATE SCHEMA IF NOT EXISTS postgres;  -- added in Phase 3
