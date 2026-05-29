/**
 * M4 — All-DuckDB: ODBC fan-out -> DURABLE local DuckDB stage -> batch-MERGE.
 *
 * Same ODBC fan-out read as M1, but each wave's rows land in a DURABLE on-disk DuckDB file (ATTACH
 * '<file>' AS stage) rather than an in-memory TEMP table, and the wave is committed to the lake with
 * a single MERGE keyed on (instance_id[, database_id], collected_at) instead of a plain INSERT. This
 * isolates two variables vs M1: a crash-recoverable staging buffer (re-runnable) and MERGE (idempotent
 * upsert / natural dedup) vs in-memory stage + append. One MERGE per wave = one commit.
 *
 * Env: same as M1, plus BENCH_STAGE_FILE (default: a temp .duckdb file).
 */
import { DuckDBInstance, type DuckDBConnection } from '@duckdb/node-api';
import { readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const PGCONN = req('SQLDASH_BENCH_PGCONN');
const DATA = req('SQLDASH_BENCH_DATA');
const REGION = process.env.AWS_REGION ?? 'us-east-1';
const FLEET_CSV = req('BENCH_FLEET_CSV');
const METRIC = process.env.BENCH_METRIC ?? 'metric_cpu';
const FLUSH = Number(process.env.BENCH_FLUSH_BATCH ?? 32);
const THREADS = Number(process.env.BENCH_THREADS ?? 24);
const PACK_DIR = process.env.BENCH_PACK_DIR ?? '';
const ODBC_DRIVER = process.env.BENCH_ODBC_DRIVER ?? 'ODBC Driver 18 for SQL Server';
const STAGE_FILE = (process.env.BENCH_STAGE_FILE ?? join(tmpdir(), 'sqldash-m4-stage.duckdb')).replace(/\\/g, '/');

function req(name: string): string { const v = process.env[name]; if (!v) { console.error(`missing env ${name}`); process.exit(2); } return v; }
const isConflict = (m: string) => /conflict|serializ|concurrent|out of date|snapshot|transaction|retry/i.test(m);
const sqlLit = (s: string) => s.replace(/'/g, "''");
const connStr = (target: string) => `Driver={${ODBC_DRIVER}};Server=${target};Trusted_Connection=Yes;TrustServerCertificate=Yes`;

type Instance = { id: number; target: string };
type Col = { name: string; type: string; source: 'stamp' | 'query' | 'const'; const?: unknown };
type Collector = { name: string; target_table: string; query: string; schema: Col[] };

function loadFleet(): Instance[] {
  return readFileSync(FLEET_CSV, 'utf8').split(/\r?\n/).filter((l) => l && !l.startsWith('instance_id'))
    .map((l) => { const [id, target] = l.split(','); return { id: Number(id), target }; });
}
function loadCollector(): { col: Collector; querySql: string } {
  const pack = JSON.parse(readFileSync(join(PACK_DIR, 'collections.json'), 'utf8'));
  const col = (pack.collectors as Collector[]).find((c) => c.name === METRIC);
  if (!col) { console.error(`collector ${METRIC} not found`); process.exit(2); }
  return { col, querySql: readFileSync(join(PACK_DIR, col.query), 'utf8').trim().replace(/;\s*$/, '') };
}

const now = new Date();
const pad = (n: number) => String(n).padStart(2, '0');
const COLLECTED_AT = `${now.getUTCFullYear()}-${pad(now.getUTCMonth() + 1)}-${pad(now.getUTCDate())} ${pad(now.getUTCHours())}:${pad(now.getUTCMinutes())}:${pad(now.getUTCSeconds())}`;
const [Y, M, D] = [now.getUTCFullYear(), now.getUTCMonth() + 1, now.getUTCDate()];

/** target-column expression, reading query cols from the staged raw table (alias r). */
function colExpr(c: Col): string {
  if (c.source === 'query') return `r."${c.name}"`;
  if (c.source === 'const') return c.const === undefined ? 'NULL' : `${typeof c.const === 'string' ? `'${sqlLit(c.const)}'` : c.const}`;
  switch (c.name) {
    case 'instance_id': return 'r.instance_id';
    case 'platform': return `'sqlserver'`;
    case 'collected_at': return `TIMESTAMP '${COLLECTED_AT}'`;
    case 'year': return String(Y);
    case 'month': return String(M);
    case 'day': return String(D);
    default: return 'NULL';
  }
}
const stageBranch = (i: Instance, q: string) =>
  `SELECT ${i.id} AS instance_id, x.* FROM odbc_query(odbc_connect('${sqlLit(connStr(i.target))}'), '${sqlLit(q)}') x`;

async function setup(): Promise<DuckDBConnection> {
  const inst = await DuckDBInstance.create(':memory:');
  const c = await inst.connect();
  await c.run('INSTALL aws; LOAD aws; INSTALL ducklake; LOAD ducklake; INSTALL postgres; LOAD postgres; INSTALL httpfs; LOAD httpfs; INSTALL odbc; LOAD odbc;');
  await c.run(`CREATE OR REPLACE SECRET s3cred (TYPE s3, PROVIDER credential_chain, CHAIN 'process', REGION '${REGION}')`);
  await c.run(`ATTACH 'ducklake:postgres:${PGCONN}' AS lake (DATA_PATH '${DATA}')`);
  try { rmSync(STAGE_FILE, { force: true }); } catch { /* fresh stage file */ }
  await c.run(`ATTACH '${STAGE_FILE}' AS stage;`);    // durable on-disk staging buffer
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

  // MERGE key: instance/time, plus native database_id when the metric is database-grained.
  const keyCols = ['instance_id', ...(col.schema.some((s) => s.name === 'database_id') ? ['database_id'] : []), 'collected_at'];
  const onClause = keyCols.map((k) => `t.${k} = s.${k}`).join(' AND ');
  const colNames = col.schema.map((s) => `"${s.name}"`).join(', ');
  const usingSelect = col.schema.map((s) => `${colExpr(s)} AS "${s.name}"`).join(', ');
  const insVals = col.schema.map((s) => `s."${s.name}"`).join(', ');

  let commits = 0, conflicts = 0, errors = 0, rows = 0, pingRows = 0;
  let lastError: string | undefined;

  // One ODBC connection per instance: collecting into the durable stage IS the connectivity test, so
  // the ping is DERIVED from it (no second connect) — matching M2/M3's reuse of one connection.
  const pingOk = (ms: number) =>
    `INSERT INTO common.pings (instance_id, platform, collected_at, year, month, day, response_time_ms, is_success)
     SELECT DISTINCT instance_id, 'sqlserver', TIMESTAMP '${COLLECTED_AT}', ${Y}, ${M}, ${D}, ${ms}, TRUE FROM stage.raw;`;
  const pingFail = (id: number) =>
    `INSERT INTO common.pings (instance_id, platform, collected_at, year, month, day, response_time_ms, is_success)
     VALUES (${id}, 'sqlserver', TIMESTAMP '${COLLECTED_AT}', ${Y}, ${M}, ${D}, 5000, FALSE);`;

  const t0 = performance.now();
  for (const wave of waves) {
    try {
      const staging = wave.map((i) => stageBranch(i, querySql)).join(' UNION ALL ');
      const pt0 = performance.now();
      await c.run(`CREATE OR REPLACE TABLE stage.raw AS ${staging};`);   // durable stage = connectivity test
      const waveMs = Math.round(performance.now() - pt0);
      const cnt = (await c.runAndReadAll('SELECT count(*) AS n FROM stage.raw')).getRowObjects()[0] as any;
      await c.run(pingOk(waveMs));
      pingRows += wave.length;
      await c.run(`MERGE INTO ${col.target_table} AS t
                   USING (SELECT ${usingSelect} FROM stage.raw r) AS s
                   ON ${onClause}
                   WHEN NOT MATCHED THEN INSERT (${colNames}) VALUES (${insVals});`);   // commit
      commits++; rows += Number(cnt.n);
    } catch (e) {
      const msg = (e as Error).message;
      if (isConflict(msg)) conflicts++;
      for (const i of wave) {
        try {
          const pt0 = performance.now();
          await c.run(`CREATE OR REPLACE TABLE stage.raw AS ${stageBranch(i, querySql)};`);
          const ms = Math.round(performance.now() - pt0);
          await c.run(pingOk(ms));
          await c.run(`MERGE INTO ${col.target_table} AS t USING (SELECT ${usingSelect} FROM stage.raw r) AS s ON ${onClause} WHEN NOT MATCHED THEN INSERT (${colNames}) VALUES (${insVals});`);
          commits++; rows += 1; pingRows += 1;
        } catch (e2) {
          errors++; lastError = (e2 as Error).message;
          try { await c.run(pingFail(i.id)); pingRows += 1; } catch { /* best-effort */ }
        }
      }
    }
  }
  const elapsed = (performance.now() - t0) / 1000;

  console.log(JSON.stringify({
    method: 'M4', metric: METRIC, target_table: col.target_table,
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
