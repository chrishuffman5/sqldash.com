/**
 * SQLDash MCP server — exposes the DuckLake fleet store to LLM clients over stdio.
 *
 * Read-only consumer of the lake the collectors populate (direct-write, integer instance_id keys).
 * Tools that read the scoring view chain (problematic_instances) require lake/views/scoring.sql applied.
 *
 * Env: SQLDASH_CATALOG, SQLDASH_DATA (default: local dev lake under lake/local/).
 */
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { DuckDBInstance, type DuckDBConnection } from '@duckdb/node-api';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { z } from 'zod';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const fwd = (p: string) => p.replace(/\\/g, '/');
const CATALOG = fwd(process.env.SQLDASH_CATALOG ?? path.join(repoRoot, 'lake/local/catalog.ducklake'));
const DATA = fwd(process.env.SQLDASH_DATA ?? path.join(repoRoot, 'lake/local/data'));

let conn: DuckDBConnection | null = null;
async function lake(): Promise<DuckDBConnection> {
  if (conn) return conn;
  const instance = await DuckDBInstance.create(':memory:');
  conn = await instance.connect();
  await conn.run('INSTALL ducklake; LOAD ducklake; INSTALL httpfs; LOAD httpfs;');
  await conn.run(`ATTACH 'ducklake:${CATALOG}' AS lake (DATA_PATH '${DATA}', READ_ONLY)`);
  await conn.run('USE lake;');
  return conn;
}

/** Run SELECT and return rows as JSON-safe objects (bigint -> number/string, values -> primitives). */
async function query(sql: string): Promise<Record<string, unknown>[]> {
  const c = await lake();
  const reader = await c.runAndReadAll(sql);
  return reader.getRowObjects().map((row) => {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(row)) {
      if (typeof v === 'bigint') out[k] = v >= -9007199254740991n && v <= 9007199254740991n ? Number(v) : v.toString();
      else if (v !== null && typeof v === 'object') out[k] = String(v);
      else out[k] = v;
    }
    return out;
  });
}

const asText = (rows: unknown) => ({ content: [{ type: 'text' as const, text: JSON.stringify(rows, null, 2) }] });
const asError = (e: unknown) => ({ content: [{ type: 'text' as const, text: `error: ${(e as Error).message}` }], isError: true });

const server = new McpServer({ name: 'sqldash', version: '0.1.0' });

server.registerTool(
  'list_instances',
  { title: 'List instances', description: 'List registered instances in the fleet (fqn, platform, status, version).',
    inputSchema: { platform: z.string().optional().describe("filter by platform, e.g. 'sqlserver'") } },
  async ({ platform }) => {
    try {
      const where = platform ? `WHERE platform = '${platform.replace(/'/g, "''")}'` : '';
      return asText(await query(`SELECT instance_fqn, platform, status, environment, engine_version, registered_at FROM common.instances ${where} ORDER BY instance_fqn`));
    } catch (e) { return asError(e); }
  },
);

server.registerTool(
  'problematic_instances',
  { title: 'Problematic instances', description: 'Worst instances by health score (high IRC) or unresponsive. Requires the scoring views (lake/views/scoring.sql).',
    inputSchema: { limit: z.number().int().positive().max(200).default(25) } },
  async ({ limit }) => {
    try { return asText(await query(`SELECT * FROM common.v_problematic_instances LIMIT ${limit}`)); }
    catch (e) { return asError(e); }
  },
);

server.registerTool(
  'instance_detail',
  { title: 'Instance detail', description: 'Latest details + most recent CPU/memory/session metrics for one instance.',
    inputSchema: { instance_fqn: z.string().describe("e.g. 'localhost'") } },
  async ({ instance_fqn }) => {
    try {
      const fqn = instance_fqn.replace(/'/g, "''");
      const ik = await query(`SELECT instance_id FROM common.instances WHERE instance_fqn = '${fqn}' LIMIT 1`);
      if (!ik.length) return asText({ note: `no instance '${instance_fqn}'` });
      const key = Number(ik[0].instance_id);
      const [details, cpu, mem, sess, dbs] = await Promise.all([
        query(`SELECT * FROM common.instance_details WHERE instance_id=${key} ORDER BY collected_at DESC LIMIT 1`),
        query(`SELECT collected_at, engine_cpu_percent, other_cpu_percent, system_idle_percent FROM common.metric_cpu WHERE instance_id=${key} ORDER BY collected_at DESC LIMIT 1`),
        query(`SELECT collected_at, page_residency_seconds FROM common.metric_memory WHERE instance_id=${key} AND page_residency_seconds IS NOT NULL ORDER BY collected_at DESC LIMIT 1`),
        query(`SELECT collected_at, active_sessions FROM common.metric_sessions WHERE instance_id=${key} ORDER BY collected_at DESC LIMIT 1`),
        query(`SELECT count(DISTINCT database_id) AS database_count FROM common.databases WHERE instance_id=${key}`),
      ]);
      return asText({ instance_fqn, instance_id: key, details: details[0] ?? null, latest_cpu: cpu[0] ?? null, latest_memory: mem[0] ?? null, latest_sessions: sess[0] ?? null, databases: dbs[0] ?? null });
    } catch (e) { return asError(e); }
  },
);

server.registerTool(
  'metric_history',
  { title: 'Metric history', description: 'Time series of a metric for one instance over the last N hours.',
    inputSchema: { instance_fqn: z.string(), metric: z.enum(['cpu', 'memory', 'sessions']), hours: z.number().int().positive().max(720).default(24) } },
  async ({ instance_fqn, metric, hours }) => {
    try {
      const fqn = instance_fqn.replace(/'/g, "''");
      const sel = metric === 'cpu' ? 'engine_cpu_percent, other_cpu_percent, system_idle_percent'
        : metric === 'memory' ? 'page_residency_seconds' : 'active_sessions';
      const table = metric === 'cpu' ? 'metric_cpu' : metric === 'memory' ? 'metric_memory' : 'metric_sessions';
      return asText(await query(
        `SELECT m.collected_at, ${sel} FROM common.${table} m JOIN common.instances i USING (instance_id)
         WHERE i.instance_fqn='${fqn}' AND m.collected_at >= now() - INTERVAL '${hours} hours' ORDER BY m.collected_at`));
    } catch (e) { return asError(e); }
  },
);

server.registerTool(
  'run_query',
  { title: 'Run read-only query', description: 'Run a bounded read-only SELECT against the lake (common.* / sqlserver.*). Single statement only.',
    inputSchema: { sql: z.string(), limit: z.number().int().positive().max(5000).default(500) } },
  async ({ sql, limit }) => {
    try {
      const trimmed = sql.trim().replace(/;\s*$/, '');
      if (!/^(select|with)\b/i.test(trimmed)) return asError(new Error('only SELECT/WITH queries are allowed'));
      if (trimmed.includes(';')) return asError(new Error('single statement only'));
      const wrapped = `SELECT * FROM (${trimmed}) LIMIT ${limit}`;
      return asText(await query(wrapped));
    } catch (e) { return asError(e); }
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`sqldash-mcp ready (catalog=${CATALOG})`);
