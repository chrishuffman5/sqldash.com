/**
 * Phase 0 concurrency / throughput acceptance gate.
 *
 * Spawns N independent DuckLake writers (separate DuckDBInstances = separate catalog transactions,
 * approximating separate nodes) that all commit batches into the SAME hot partition
 * (common.metric_cpu, platform='sqlserver', today) — the worst case the adversarial review flagged.
 * Measures: commits/sec, commit-conflict (SERIALIZATION) rate + retries, errors. File sizing is
 * reported by the PowerShell runner via `aws s3 ls` before/after compaction.
 *
 * Env: SQLDASH_PGCONN (libpq DSN incl. password), SQLDASH_DATA (s3://...), AWS_* creds, REGION,
 *      GATE_WRITERS, GATE_ROUNDS, GATE_BATCH, GATE_MAX_RETRY.
 */
import { DuckDBInstance, type DuckDBConnection } from '@duckdb/node-api';
import { randomUUID } from 'node:crypto';

const PGCONN = process.env.SQLDASH_PGCONN ?? '';
const DATA   = process.env.SQLDASH_DATA ?? '';
const REGION = process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION ?? 'us-east-1';
// S3 auth: the DuckDB `aws` extension resolves creds via PROVIDER credential_chain (CHAIN 'process'),
// reading the AWS_PROFILE bridge profile from the environment — no keys in code.
const N         = Number(process.env.GATE_WRITERS ?? 8);
const ROUNDS    = Number(process.env.GATE_ROUNDS ?? 25);
const BATCH     = Number(process.env.GATE_BATCH ?? 500);
const MAX_RETRY = Number(process.env.GATE_MAX_RETRY ?? 12);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const isConflict = (m: string) => /conflict|serializ|concurrent|out of date|snapshot|transaction|retry/i.test(m);
const now = new Date();
const [Y, M, D] = [now.getUTCFullYear(), now.getUTCMonth() + 1, now.getUTCDate()];

type Stats = { commits: number; rows: number; conflicts: number; errors: number; lastError?: string };

async function makeWriter(): Promise<DuckDBConnection> {
  const inst = await DuckDBInstance.create(':memory:');
  const c = await inst.connect();
  await c.run('INSTALL aws; LOAD aws; INSTALL ducklake; LOAD ducklake; INSTALL postgres; LOAD postgres; INSTALL httpfs; LOAD httpfs;');
  await c.run(`CREATE OR REPLACE SECRET s3cred (TYPE s3, PROVIDER credential_chain, CHAIN 'process', REGION '${REGION}')`);
  await c.run(`ATTACH 'ducklake:postgres:${PGCONN}' AS lake (DATA_PATH '${DATA}')`);
  await c.run('USE lake;');
  return c;
}

async function runWriter(id: number, c: DuckDBConnection, s: Stats): Promise<void> {
  const ik = randomUUID(); // distinct instance per writer
  for (let r = 0; r < ROUNDS; r++) {
    const sqid = `gate-w${id}-r${r}`;
    let attempt = 0;
    for (;;) {
      try {
        await c.run(
          `INSERT INTO common.metric_cpu (instance_key, platform, collected_at, year, month, day, engine_cpu_percent, other_cpu_percent, system_idle_percent, source_query_id)
           SELECT '${ik}'::UUID, 'sqlserver', now(), ${Y}, ${M}, ${D},
                  (random()*80)::SMALLINT, (random()*20)::SMALLINT, (random()*100)::SMALLINT, '${sqid}-' || i
           FROM range(${BATCH}) t(i);`,
        );
        s.commits++; s.rows += BATCH; break;
      } catch (e) {
        const msg = (e as Error).message;
        if (isConflict(msg) && attempt < MAX_RETRY) { s.conflicts++; attempt++; await sleep(15 + attempt * 25 + Math.floor(Math.random() * 30)); continue; }
        s.errors++; s.lastError = msg; break;
      }
    }
  }
}

async function main(): Promise<void> {
  if (!PGCONN || !DATA) { console.error('missing env (SQLDASH_PGCONN / SQLDASH_DATA)'); process.exit(2); }
  console.error(`gate: ${N} writers x ${ROUNDS} rounds x ${BATCH} rows -> common.metric_cpu partition (sqlserver,${Y}-${M}-${D})`);

  const conns = await Promise.all(Array.from({ length: N }, () => makeWriter()));
  const stats: Stats[] = conns.map(() => ({ commits: 0, rows: 0, conflicts: 0, errors: 0 }));

  const t0 = performance.now();
  await Promise.all(conns.map((c, i) => runWriter(i, c, stats[i])));
  const elapsed = (performance.now() - t0) / 1000;

  const agg = stats.reduce((a, s) => ({
    commits: a.commits + s.commits, rows: a.rows + s.rows, conflicts: a.conflicts + s.conflicts, errors: a.errors + s.errors,
  }), { commits: 0, rows: 0, conflicts: 0, errors: 0 });

  // sanity: row count in the partition via a fresh reader
  const reader = conns[0];
  const cnt = (await reader.runAndReadAll(
    `SELECT count(*) AS n FROM common.metric_cpu WHERE platform='sqlserver' AND year=${Y} AND month=${M} AND day=${D} AND source_query_id LIKE 'gate-%'`,
  )).getRowObjects()[0] as any;

  // best-effort compaction
  let compaction = 'not attempted';
  for (const fn of [`CALL ducklake_merge_adjacent_files('lake')`, `CALL lake.merge_adjacent_files()`]) {
    try { await reader.run(fn); compaction = `ok via ${fn}`; break; } catch (e) { compaction = `unavailable (${(e as Error).message.split('\n')[0]})`; }
  }

  const lastErr = stats.map((s) => s.lastError).find(Boolean);
  console.log(JSON.stringify({
    writers: N, rounds: ROUNDS, batch: BATCH,
    elapsed_sec: Number(elapsed.toFixed(2)),
    commits: agg.commits, rows_committed: agg.rows,
    commits_per_sec: Number((agg.commits / elapsed).toFixed(1)),
    rows_per_sec: Number((agg.rows / elapsed).toFixed(0)),
    conflict_retries: agg.conflicts,
    conflict_rate: Number((agg.conflicts / (agg.commits + agg.conflicts || 1)).toFixed(3)),
    errors: agg.errors, last_error: lastErr ?? null,
    partition_rows_in_lake: Number(cnt.n),
    compaction,
  }, null, 2));
}

main().catch((e) => { console.error(e); process.exit(1); });
