-- pack: sqlserver  collector: ha_cluster_members  ->  sqlserver.ha_cluster_members
-- Cluster members (nodes + witnesses) with the parent cluster's identity and quorum
-- stamped onto each row, via sys.dm_hadr_cluster_members CROSS JOIN sys.dm_hadr_cluster
-- (the latter is a single-row DMV). Instance-level: one row per cluster member.
-- Returns ZERO rows on a non-clustered, non-HADR instance (both DMVs are empty) — correct,
-- no IF/guard needed. Valid on SQL Server 2016+ (engine 13+); WSFC and Pacemaker clusters
-- surface through these DMVs.
SELECT
    c.cluster_name              AS cluster_name,
    c.quorum_type_desc          AS quorum_type,
    c.quorum_state_desc         AS quorum_state,
    m.member_name               AS member_name,
    m.member_type_desc          AS member_type,
    m.member_state_desc         AS member_state,
    m.number_of_quorum_votes    AS quorum_votes
FROM sys.dm_hadr_cluster_members AS m WITH (NOLOCK)
CROSS JOIN sys.dm_hadr_cluster AS c WITH (NOLOCK);
