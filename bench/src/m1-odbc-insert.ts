/**
 * M1 — All-DuckDB: ODBC fan-out -> in-memory staging -> batched INSERT.  ★ leading candidate
 *
 * ONE DuckDB process (in-memory) attaches the bench DuckLake, then per wave of FLUSH_BATCH instances:
 *   1. ping-first: a single fan-out statement opens one ODBC connection per instance and confirms
 *      `SELECT 1`; the reachable instances are written to common.pings (response_time_ms = wave
 *      elapsed — coarse but honest for a localhost fleet; see the plan's "timing tolerance").
 *   2. collect+flush: a single staging statement UNION-ALLs the metric's DMV query across the wave
 *      (one odbc_connect per instance), materializes an in-memory TEMP table, then ONE INSERT commits
 *      the whole wave into the lake. One commit per wave — the bulk-load model, not per-instance.
 *
 * Error isolation: if a wave's fan-out throws (one unreachable instance aborts the UNION ALL), the
 * wave falls back to per-instance staging so a single bad instance is logged-and-skipped, not fatal.
 *
 * The instance key (instance_id) is stamped into each branch literal, so loading is a dumb append.
 * Generic over any collector in collections.json (stamp | query | const column sources).
 *
 * Env: SQLDASH_BENCH_PGCONN, SQLDASH_BENCH_DATA, AWS_REGION, AWS_PROFILE (in env),
 *      BENCH_FLEET_CSV, BENCH_METRIC (default metric_cpu), BENCH_FLUSH_BATCH (32),
 *      BENCH_THREADS (24), BENCH_PACK_DIR, BENCH_ODBC_DRIVER.
 */
import { DuckDBInstance, type DuckDBConnection } from '@duckdb/node-api';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const PGCONN = req('SQLDASH_BENCH_PGCONN');
const DATA = req('SQLDASH_BENCH_DATA');
const REGION = process.env.AWS_REGION ?? 'us-east-1';
const FLEET_CSV = req('BENCH_FLEET_CSV');
const METRIC = process.env.BENCH_METRIC ?? 'metric_cpu';
const FLUSH = Number(process.env.BENCH_FLUSH_BATCH ?? 32);
const THREADS = Number(process.env.BENCH_THREADS ?? 24);
const PACK_DIR = process.env.BENCH_PACK_DIR ?? '';
const ODBC_DRIVER = process.env.BENCH_ODBC_DRIVER ?? 'ODBC Driver 18 for SQL Server';

function req(name: string): string {
  const v = process.env[name];
  if (!v) { console.error(`missing env ${name}`); process.exit(2); }
  return v;
}
const isConflict = (m: string) => /conflict|serializ|concurrent|out of date|snapshot|transaction|retry/i.test(m);
const sqlLit = (s: string) => s.replace(/'/g, "''");                  // escape single quotes for SQL literal
const connStr = (target: string) => `Driver={${ODBC_DRIVER}};Server=${target};Trusted_Connection=Yes;TrustServerCertificate=Yes`;

type Instance = { id: number; target: string };
type Col = { name: string; type: string; source: 'stamp' | 'query' | 'const'; const?: unknown };
type Collector = { name: string; target_table: string; query: string; schema: Col[] };

function loadFleet(): Instance[] {
  const lines = readFileSync(FLEET_CSV, 'utf8').split(/\r?\n/).filter((l) => l && !l.startsWith('instance_id'));
  return lines.map((l) => { const [id, target] = l.split(','); return { id: Number(id), target }; });
}
function loadCollector(): { col: Collector; querySql: string } {
  const pack = JSON.parse(readFileSync(join(PACK_DIR, 'collections.json'), 'utf8'));
  const col = (pack.collectors as Collector[]).find((c) => c.name === METRIC);
  if (!col) { console.error(`collector ${METRIC} not found in pack`); process.exit(2); }
  const querySql = readFileSync(join(PACK_DIR, col.query), 'utf8').trim().replace(/;\s*$/, '');
  return { col, querySql };
}

// Stamp values shared by the whole cycle (one collected_at per cycle — jitter across instances is fine).
const now = new Date();
const pad = (n: number) => String(n).padStart(2, '0');
const COLLECTED_AT = `${now.getUTCFullYear()}-${pad(now.getUTCMonth() + 1)}-${pad(now.getUTCDate())} ${pad(now.getUTCHours())}:${pad(now.getUTCMinutes())}:${pad(now.getUTCSeconds())}`;
const [Y, M, D] = [now.getUTCFullYear(), now.getUTCMonth() + 1, now.getUTCDate()];

/** SQL expression for a target column given its source (used in the flush INSERT ... SELECT). */
function colExpr(c: Col): string {
  if (c.source === 'query') return `stg."${c.name}"`;
  if (c.source === 'const') return c.const === undefined ? 'NULL' : `${typeof c.const === 'string' ? `'${sqlLit(c.const)}'` : c.const}`;
  switch (c.name) {                                   // stamp
    case 'instance_id': return 'stg.instance_id';
    case 'platform': return `'sqlserver'`;
    case 'collected_at': return `TIMESTAMP '${COLLECTED_AT}'`;
    case 'year': return String(Y);
    case 'month': return String(M);
    case 'day': return String(D);
    default: return 'NULL';
  }
}

/** One staging branch per instance: stamp instance_id, fan out the DMV via its own ODBC connection. */
function stageBranch(inst: Instance, querySql: string): string {
  return `SELECT ${inst.id} AS instance_id, q.* FROM odbc_query(odbc_connect('${sqlLit(connStr(inst.target))}'), '${sqlLit(querySql)}') q`;
}

async function setup(): Promise<DuckDBConnection> {
  const inst = await DuckDBInstance.create(':memory:');
  const c = await inst.connect();
  await c.run('INSTALL aws; LOAD aws; INSTALL ducklake; LOAD ducklake; INSTALL postgres; LOAD postgres; INSTALL httpfs; LOAD httpfs; INSTALL odbc; LOAD odbc;');
  await c.run(`CREATE OR REPLACE SECRET s3cred (TYPE s3, PROVIDER credential_chain, CHAIN 'process', REGION '${REGION}')`);
  await c.run(`ATTACH 'ducklake:postgres:${PGCONN}' AS lake (DATA_PATH '${DATA}')`);
  await c.run('USE lake;');
  await c.run(`SET threads = ${THREADS};`);
  return c;
}

async function main(): Promise<void> {
  const fleet = loadFleet();
  const { col, querySql } = loadCollector();
  const c = await setup();

  const waves: Instance[][] = [];
  for (let i = 0; i < fleet.length; i += FLUSH) waves.push(fleet.slice(i, i + FLUSH));

  const colNames = col.schema.map((s) => `"${s.name}"`).join(', ');
  const colExprs = col.schema.map(colExpr).join(', ');

  let commits = 0, conflicts = 0, errors = 0, rows = 0, pingRows = 0;
  let lastError: string | undefined;

  // One ODBC connection per instance: the metric fan-out IS the connectivity test, so the ping is
  // DERIVED from the collection attempt (no second connect) — matching how M2/M3 reuse one connection
  // for ping + DMV. response_time_ms is the wave's stage elapsed (coarse; see "timing tolerance").
  const pingOk = (ids: string, ms: number) =>
    `INSERT INTO common.pings (instance_id, platform, collected_at, year, month, day, response_time_ms, is_success)
     SELECT DISTINCT instance_id, 'sqlserver', TIMESTAMP '${COLLECTED_AT}', ${Y}, ${M}, ${D}, ${ms}, TRUE FROM ${ids};`;
  const pingFail = (id: number) =>
    `INSERT INTO common.pings (instance_id, platform, collected_at, year, month, day, response_time_ms, is_success)
     VALUES (${id}, 'sqlserver', TIMESTAMP '${COLLECTED_AT}', ${Y}, ${M}, ${D}, 5000, FALSE);`;

  const t0 = performance.now();
  for (const wave of waves) {
    try {
      const staging = wave.map((i) => stageBranch(i, querySql)).join(' UNION ALL ');
      const pt0 = performance.now();
      await c.run(`CREATE OR REPLACE TEMP TABLE stg AS ${staging};`);   // stage = connectivity test
      const waveMs = Math.round(performance.now() - pt0);
      const cnt = (await c.runAndReadAll('SELECT count(*) AS n FROM stg')).getRowObjects()[0] as any;
      await c.run(pingOk('stg', waveMs));
      pingRows += wave.length;
      await c.run(`INSERT INTO ${col.target_table} (${colNames}) SELECT ${colExprs} FROM stg;`);   // commit
      commits++; rows += Number(cnt.n);
    } catch (e) {
      const msg = (e as Error).message;
      if (isConflict(msg)) { conflicts++; }
      // error isolation: re-try per-instance so one unreachable instance doesn't lose the whole wave
      for (const i of wave) {
        try {
          const pt0 = performance.now();
          await c.run(`CREATE OR REPLACE TEMP TABLE stg AS ${stageBranch(i, querySql)};`);
          const ms = Math.round(performance.now() - pt0);
          await c.run(pingOk('stg', ms));
          await c.run(`INSERT INTO ${col.target_table} (${colNames}) SELECT ${colExprs} FROM stg;`);
          commits++; rows += 1; pingRows += 1;
        } catch (e2) {
          errors++; lastError = (e2 as Error).message;
          try { await c.run(pingFail(i.id)); pingRows += 1; } catch { /* ping is best-effort */ }
        }
      }
    }
  }
  const elapsed = (performance.now() - t0) / 1000;

  console.log(JSON.stringify({
    method: 'M1', metric: METRIC, target_table: col.target_table,
    instances: fleet.length, flush_batch: FLUSH, threads: THREADS, waves: waves.length,
    commits, rows_written: rows, ping_rows: pingRows,
    conflicts, errors, last_error: lastError ?? null,
    elapsed_sec: Number(elapsed.toFixed(2)),
    rows_per_sec: Number((rows / elapsed).toFixed(0)),
    commits_per_sec: Number((commits / elapsed).toFixed(2)),
  }));
  await c.disconnectSync();
}

main().catch((e) => { console.error(e); process.exit(1); });
