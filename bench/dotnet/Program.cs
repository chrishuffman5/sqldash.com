// M2 — PowerShell-orchestrated, but the in-process writer is .NET DuckDB.NET (the legacy SqlBulkCopy
// analog). Microsoft.Data.SqlClient (SSPI) reads each instance in parallel; a SINGLE persistent
// DuckDB.NET connection attaches the lake ONCE and commits each flush batch via the Appender (fast
// in-process marshaling into a staging table) + one INSERT...SELECT into the DuckLake table.
// Contract is identical to the other runners: env in, one JSON line out.

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using DuckDB.NET.Data;
using Microsoft.Data.SqlClient;

static string Req(string n) => Environment.GetEnvironmentVariable(n) ?? throw new Exception($"missing env {n}");
static string Env(string n, string d) => Environment.GetEnvironmentVariable(n) is { Length: > 0 } v ? v : d;

string pgconn   = Req("SQLDASH_BENCH_PGCONN");
string data     = Req("SQLDASH_BENCH_DATA");
string region   = Env("AWS_REGION", "us-east-1");
string fleetCsv = Req("BENCH_FLEET_CSV");
string metric   = Env("BENCH_METRIC", "metric_cpu");
int    flush    = int.Parse(Env("BENCH_FLUSH_BATCH", "32"));
int    threads  = int.Parse(Env("BENCH_THREADS", "24"));
string packDir  = Req("BENCH_PACK_DIR");

// ---- load fleet + collector definition ----
var fleet = File.ReadAllLines(fleetCsv).Where(l => l.Length > 0 && !l.StartsWith("instance_id"))
    .Select(l => { var p = l.Split(','); return (Id: int.Parse(p[0]), Target: p[1]); }).ToList();

using var packDoc = JsonDocument.Parse(File.ReadAllText(Path.Combine(packDir, "collections.json")));
var col = packDoc.RootElement.GetProperty("collectors").EnumerateArray().First(c => c.GetProperty("name").GetString() == metric);
string target = col.GetProperty("target_table").GetString()!;
string queryFile = col.GetProperty("query").GetString()!;
string querySql = File.ReadAllText(Path.Combine(packDir, queryFile)).Trim().TrimEnd(';');
var schema = col.GetProperty("schema").EnumerateArray().Select(c => new Col(
    c.GetProperty("name").GetString()!, c.GetProperty("type").GetString()!, c.GetProperty("source").GetString()!,
    c.TryGetProperty("const", out var k) ? k.ToString() : null)).ToList();
var queryCols = schema.Where(c => c.Source == "query").ToList();

var nowUtc = DateTime.UtcNow;
string collectedAt = nowUtc.ToString("yyyy-MM-dd HH:mm:ss");
int Y = nowUtc.Year, M = nowUtc.Month, D = nowUtc.Day;

// ---- parallel reads: ping (timed SELECT 1) + metric DMV ----
var results = new ConcurrentBag<ReadResult>();
int readErrors = 0;
string? readErrorSample = null;
Parallel.ForEach(fleet, new ParallelOptions { MaxDegreeOfParallelism = threads }, inst =>
{
    var rr = new ReadResult { Id = inst.Id, PingMs = 5000, PingOk = false, Rows = new() };
    string cs = $"Server={inst.Target};Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=5;Application Name=SqlDashBenchM2";
    try
    {
        using var conn = new SqlConnection(cs);
        var sw = Stopwatch.StartNew();
        conn.Open();
        using (var pc = conn.CreateCommand()) { pc.CommandText = "SELECT 1"; pc.CommandTimeout = 5; pc.ExecuteScalar(); }
        sw.Stop(); rr.PingMs = (int)sw.ElapsedMilliseconds; rr.PingOk = true;
        using var cmd = conn.CreateCommand();
        cmd.CommandText = querySql; cmd.CommandTimeout = int.Parse(col.GetProperty("timeout_seconds").GetRawText());
        using var rdr = cmd.ExecuteReader();
        while (rdr.Read())
        {
            var row = new Dictionary<string, object?>();
            for (int i = 0; i < rdr.FieldCount; i++) row[rdr.GetName(i)] = rdr.IsDBNull(i) ? null : rdr.GetValue(i);
            rr.Rows.Add(row);
        }
    }
    catch (Exception ex) { rr.Error = ex.Message; Interlocked.Increment(ref readErrors); readErrorSample ??= ex.Message; }
    results.Add(rr);
});
var ok = results.Where(r => r.PingOk).ToList();

// ---- DuckDB.NET: one persistent in-process connection, attach the lake ONCE ----
using var duck = new DuckDBConnection("DataSource=:memory:");
duck.Open();
void Exec(string sql) { using var c = duck.CreateCommand(); c.CommandText = sql; c.ExecuteNonQuery(); }
Exec("INSTALL aws; LOAD aws; INSTALL ducklake; LOAD ducklake; INSTALL postgres; LOAD postgres; INSTALL httpfs; LOAD httpfs;");
Exec($"CREATE OR REPLACE SECRET s3cred (TYPE s3, PROVIDER credential_chain, CHAIN 'process', REGION '{region}')");
Exec($"ATTACH 'ducklake:postgres:{pgconn}' AS lake (DATA_PATH '{data}')");
// staging table (default 'memory' catalog) = instance_id + the query columns, in query order
string stgCols = "instance_id INTEGER, " + string.Join(", ", queryCols.Select(c => $"\"{c.Name}\" {c.Type}"));
Exec($"CREATE OR REPLACE TABLE stg ({stgCols});");

string colNames = string.Join(", ", schema.Select(c => $"\"{c.Name}\""));
string selectExprs = string.Join(", ", schema.Select(ColExpr));
string pingCols = "instance_id, platform, collected_at, year, month, day, response_time_ms, is_success";

int commits = 0, errors = 0, rowsWritten = 0, pingRows = 0;
string? lastError = null;
var swAll = Stopwatch.StartNew();

// pings: one INSERT...VALUES commit per flush-instance batch
for (int i = 0; i < ok.Count; i += flush)
{
    var chunk = ok.Skip(i).Take(flush).ToList();
    var vals = string.Join(",", chunk.Select(r => $"({r.Id},'sqlserver',TIMESTAMP '{collectedAt}',{Y},{M},{D},{r.PingMs},TRUE)"));
    try { Exec($"INSERT INTO lake.common.pings ({pingCols}) VALUES {vals};"); commits++; pingRows += chunk.Count; }
    catch (Exception ex) { errors++; lastError = ex.Message; }
}

// metric: Appender -> stg -> one INSERT...SELECT commit per flush-instance batch
for (int i = 0; i < ok.Count; i += flush)
{
    var chunk = ok.Skip(i).Take(flush).ToList();
    try
    {
        Exec("DELETE FROM stg;");
        using (var appender = duck.CreateAppender("stg"))
        {
            foreach (var r in chunk)
                foreach (var row in r.Rows)
                {
                    var ar = appender.CreateRow();
                    ar.AppendValue(r.Id);
                    foreach (var qc in queryCols) AppendTyped(ar, qc.Type, row.TryGetValue(qc.Name, out var v) ? v : null);
                    ar.EndRow();
                }
        }
        Exec($"INSERT INTO lake.{target} ({colNames}) SELECT {selectExprs} FROM stg;");
        commits++; rowsWritten += chunk.Sum(r => r.Rows.Count);
    }
    catch (Exception ex) { errors++; lastError = ex.Message; }
}
swAll.Stop();
double elapsed = Math.Round(swAll.Elapsed.TotalSeconds, 2);

var outObj = new
{
    method = "M2", metric, target_table = target,
    instances = fleet.Count, flush_batch = flush, threads,
    commits, rows_written = rowsWritten, ping_rows = pingRows,
    conflicts = 0, errors, read_errors = readErrors, last_error = lastError, read_error_sample = readErrorSample,
    elapsed_sec = elapsed,
    rows_per_sec = elapsed > 0 ? (int)(rowsWritten / elapsed) : 0,
    commits_per_sec = elapsed > 0 ? Math.Round(commits / elapsed, 2) : 0,
};
Console.WriteLine(JsonSerializer.Serialize(outObj));

// ---- helpers ----
string ColExpr(Col c) => c.Source switch
{
    "query" => $"stg.\"{c.Name}\"",
    "const" => c.Const is null ? "NULL" : c.Const,
    _ => c.Name switch
    {
        "instance_id" => "stg.instance_id",
        "platform" => "'sqlserver'",
        "collected_at" => $"TIMESTAMP '{collectedAt}'",
        "year" => Y.ToString(), "month" => M.ToString(), "day" => D.ToString(),
        _ => "NULL"
    }
};

static void AppendTyped(IDuckDBAppenderRow ar, string type, object? v)
{
    if (v is null) { ar.AppendNullValue(); return; }
    var t = type.ToUpperInvariant();
    if (t.StartsWith("SMALLINT") || t.StartsWith("INTEGER") || t.StartsWith("TINYINT")) ar.AppendValue(Convert.ToInt32(v));
    else if (t.StartsWith("BIGINT")) ar.AppendValue(Convert.ToInt64(v));
    else if (t.StartsWith("BOOLEAN")) ar.AppendValue(Convert.ToBoolean(v));
    else if (t.StartsWith("TIMESTAMP")) ar.AppendValue(Convert.ToDateTime(v));
    else if (t.StartsWith("DECIMAL") || t.StartsWith("DOUBLE")) ar.AppendValue(Convert.ToDecimal(v));
    else ar.AppendValue(Convert.ToString(v));
}

record Col(string Name, string Type, string Source, string? Const);
class ReadResult { public int Id; public int PingMs; public bool PingOk; public List<Dictionary<string, object?>> Rows = new(); public string? Error; }
