/**
 * SQLDash DuckLake writer/ingester (Phase 0).
 *
 * The SOLE DuckLake committer. Reads node-sharded Parquet from the inbox, enforces the schema
 * contract (parquet column-set AND type-set must equal the target table), appends to DuckLake with
 * idempotent dedupe, and moves consumed files to processed/ (rejects to quarantine/).
 *
 * Dev defaults attach a local DuckLake (DuckDB catalog + local data dir). Prod overrides via env:
 *   SQLDASH_CATALOG=postgres:dbname=sqldash_catalog host=...   SQLDASH_DATA=s3://sqldash-lake/data/
 */
import { DuckDBInstance, type DuckDBConnection } from '@duckdb/node-api';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const cfg = {
  inboxRoot:     process.env.SQLDASH_INBOX     ?? path.join(repoRoot, 'lake/local/inbox'),
  processedRoot: process.env.SQLDASH_PROCESSED ?? path.join(repoRoot, 'lake/local/processed'),
  quarantineRoot:process.env.SQLDASH_QUARANTINE?? path.join(repoRoot, 'lake/local/quarantine'),
  catalog:       process.env.SQLDASH_CATALOG   ?? path.join(repoRoot, 'lake/local/catalog.ducklake'),
  dataPath:      process.env.SQLDASH_DATA      ?? path.join(repoRoot, 'lake/local/data'),
};
const fwd = (p: string) => p.replace(/\\/g, '/');
const sqlStr = (p: string) => `'${p.replace(/'/g, "''")}'`;

type Col = { name: string; type: string };

async function describe(conn: DuckDBConnection, relationSql: string): Promise<Col[]> {
  const r = await conn.runAndReadAll(`DESCRIBE ${relationSql}`);
  return r.getRowObjects().map((o: any) => ({
    name: String(o.column_name),
    type: String(o.column_type).toUpperCase().trim(),
  }));
}

/** Contract check: column NAME set and TYPE set must match exactly (order-independent). */
function checkContract(parquetCols: Col[], targetCols: Col[]): string[] {
  const errs: string[] = [];
  const pt = new Map(parquetCols.map((c) => [c.name, c.type]));
  const tt = new Map(targetCols.map((c) => [c.name, c.type]));
  for (const c of targetCols) {
    if (!pt.has(c.name)) errs.push(`missing column '${c.name}'`);
    else if (pt.get(c.name) !== c.type) errs.push(`type mismatch '${c.name}': parquet ${pt.get(c.name)} != target ${c.type}`);
  }
  for (const c of parquetCols) if (!tt.has(c.name)) errs.push(`extra column '${c.name}' not in target`);
  return errs;
}

function listParquet(root: string): string[] {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root, { recursive: true })
    .map((e) => path.join(root, e.toString()))
    .filter((p) => p.endsWith('.parquet') && fs.statSync(p).isFile());
}

function moveFile(file: string, destRoot: string): void {
  const rel = path.relative(cfg.inboxRoot, file);
  const dest = path.join(destRoot, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.renameSync(file, dest);
}

async function main(): Promise<void> {
  const instance = await DuckDBInstance.create(':memory:');
  const conn = await instance.connect();
  await conn.run('INSTALL ducklake; LOAD ducklake; INSTALL httpfs; LOAD httpfs;');
  await conn.run(`ATTACH IF NOT EXISTS 'ducklake:${fwd(cfg.catalog)}' AS lake (DATA_PATH '${fwd(cfg.dataPath)}')`);
  await conn.run('USE lake;');

  const files = listParquet(cfg.inboxRoot);
  console.log(`inbox: ${files.length} parquet file(s)`);
  let ingested = 0, rows = 0, rejected = 0;

  for (const file of files) {
    // target table = parent dir name (e.g. 'common.metric_cpu')
    const table = path.basename(path.dirname(file));
    const [schema, name] = table.split('.');
    if (!schema || !name) { console.warn(`  SKIP ${file}: cannot parse table from path`); continue; }
    const target = `${schema}."${name}"`;
    const readPq = `read_parquet(${sqlStr(fwd(file))})`;

    try {
      const targetCols = await describe(conn, target);
      const pqCols = await describe(conn, `SELECT * FROM ${readPq}`);
      const errs = checkContract(pqCols, targetCols);
      if (errs.length) {
        console.error(`  REJECT ${table}/${path.basename(file)}: ${errs.join('; ')}`);
        moveFile(file, cfg.quarantineRoot);
        rejected++;
        continue;
      }

      const colList = targetCols.map((c) => `"${c.name}"`).join(', ');
      const hasSqid = targetCols.some((c) => c.name === 'source_query_id');
      const isDimension = !hasSqid && targetCols.some((c) => c.name === 'instance_key');

      await conn.run('BEGIN TRANSACTION;');
      if (hasSqid) {
        // fact: idempotent re-ingest — purge any prior rows from this exact emit, then insert
        await conn.run(`DELETE FROM ${target} WHERE source_query_id IN (SELECT DISTINCT source_query_id FROM ${readPq});`);
      } else if (isDimension) {
        // dimension: upsert by instance_key
        await conn.run(`DELETE FROM ${target} WHERE instance_key IN (SELECT DISTINCT instance_key FROM ${readPq});`);
      }
      const before = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${target}`)).getRowObjects()[0] as any;
      await conn.run(`INSERT INTO ${target} (${colList}) SELECT ${colList} FROM ${readPq};`);
      const after = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${target}`)).getRowObjects()[0] as any;
      await conn.run('COMMIT;');

      const n = Number(after.n) - Number(before.n);
      rows += n; ingested++;
      console.log(`  OK ${table}/${path.basename(file)}: +${n} row(s)`);
      moveFile(file, cfg.processedRoot);
    } catch (e) {
      await conn.run('ROLLBACK;').catch(() => {});
      console.error(`  ERROR ${table}/${path.basename(file)}: ${(e as Error).message}`);
      moveFile(file, cfg.quarantineRoot);
      rejected++;
    }
  }

  console.log(`\ndone: ${ingested} file(s) ingested, ${rows} row(s) committed, ${rejected} rejected`);
}

main().catch((e) => { console.error(e); process.exit(1); });
