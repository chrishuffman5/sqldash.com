# Phase 0 acceptance gate — DuckLake on Postgres catalog + S3

> **Historical record.** This gate predates the integer-key refactor and the direct-write decision. Its
> findings (0 conflicts, ~9.6 commits/sec ceiling, 201→1 compaction) stand and are carried forward, but the
> "TypeScript writer / sole committer" framing is obsolete — collectors now write directly (see
> [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) / [`docs/INGEST-DECISION.md`](INGEST-DECISION.md)). The gate's
> standalone reproducer (`writer/gate.ts`, `lake/run-gate.ps1`) has been superseded by the ingest-method
> harness `bench/` (see [`bench/results/SCORECARD.md`](../bench/results/SCORECARD.md)); the gate code remains
> in git history.

The plan gated the project on a concurrency/throughput/file-sizing benchmark against the real storage
stack before scaling. This is that result.

## Stack under test

- **DuckLake** (v1.0+ format) via **DuckDB 1.5.3** + extensions `ducklake`, `postgres`, `httpfs`.
- **Catalog (metadata):** PostgreSQL 17 database `sqldash_catalog` in the local `postgres17` Docker container.
- **Data:** S3 bucket `s3://sqldash-data-<account-id>/sqldash/` (us-east-1), ZSTD Parquet.
- Catalog connection from the PowerShell secret vault. **S3 auth via the DuckDB `aws` extension
  `credential_chain` (`CHAIN 'process'`)** resolving an `~/.aws` bridge profile `ducklake` — no keys in
  code, auto-refreshing.

## Method

`writer/src/gate.ts` spawns **N independent writers** (separate `DuckDBInstance`s = separate catalog
transactions, approximating separate nodes). All writers commit batches into the **same hot partition**
(`common.metric_cpu`, `platform='sqlserver'`, today) — the worst case the adversarial review flagged.
Each commit is caught for `SERIALIZATION_CONFLICT`/concurrency errors and retried with backoff (counted).
Reproduce: `pwsh lake/run-gate.ps1 -Writers 8 -Rounds 25 -Batch 500`.

## Results (8 writers × 25 rounds × 500 rows = 200 commits, 100k rows, one partition)

| Metric | Result |
|---|---|
| Commits | 200 (8 concurrent committers) |
| **Commit conflicts / retries** | **0** |
| Errors | 0 |
| Wall clock | 20.9 s |
| **Commit throughput** | **~9.6 commits/sec** |
| Row throughput | ~4,800 rows/sec |
| Files written (pre-compaction) | 201 objects, ~2.0 MB (≈7 KB each) |
| **Files after merge + expire + cleanup** | **1 object, ~681 KB** |

## Verdict

- **Concurrency — PASS.** 8 writers committing into the *same* time/platform partition produced **zero**
  serialization conflicts. DuckLake appends create *new* files per commit, so concurrent appends don't
  contend on existing data; the catalog serializes commits cleanly. The `SERIALIZATION_CONFLICT` storm the
  review feared does **not** occur for the append-only ingest path. (Conflicts would be more likely on
  concurrent *compaction*/updates — keep those single-writer/scheduled.)
- **Throughput — commit-bound (~9.6 commits/sec), as expected.** Each commit is a Postgres catalog
  transaction + an S3 file write, so commit *rate* is the limiter, not row volume. **Design implication
  (confirms the plan):** do **not** commit per-instance. Collectors emit files; a *few* writers ingest
  *large multi-instance batches*. At, say, 50k rows/commit a single writer sustains hundreds of thousands
  of rows/sec — ample for thousands of instances at a 5–15 min cadence.
- **Small files — confirmed, and remediated.** 200 small commits → 201 tiny Parquet files; **compaction +
  `expire_snapshots` + `cleanup_old_files` collapsed them to a single 681 KB file.** Schedule that
  maintenance (the DuckLake equivalent of the legacy partition-management procs).

## Caveats

- Writers are concurrent **connections/instances** within a bounded N, not a literal thousands-of-hosts
  fleet; the catalog commit path exercised is identical, but absolute throughput on production hardware /
  network to S3 will differ — re-run with realistic N and batch sizes before final sign-off.
- **S3 credentials** resolve through the `aws` extension's `credential_chain` (`CHAIN 'process'`) via an
  `~/.aws` profile `ducklake` whose `credential_process` runs
  `aws configure export-credentials --profile default --format process`. DuckDB fetches and **auto-refreshes**
  the temporary creds itself — no keys in code or SQL. (The default `config`-only chain can't see the custom
  `aws login` creds; the bridge profile is the fix. The `ducklake` profile must exist in `~/.aws/config`.)
- The gate commits one 500-row batch per commit to stress *commit rate*; the production writer batches far
  more per commit, so effective rows/sec is much higher than the gate's stress figure.

## Reproduce

The gate's standalone runner was removed with the `writer/` tier. The same storage stack — and the same
concurrency/throughput/file-sizing behavior — is now exercised by the ingest-method harness:

```powershell
pwsh lake/apply-cloud.ps1                                          # provision/attach the cloud lake (PG catalog + S3)
pwsh bench/run-bench.ps1 -Methods M1,M2,M3,M4 -FleetLimit 1000 -Compact   # writes + PG/S3 telemetry + compaction
```
