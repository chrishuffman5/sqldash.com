// Marker type so the deps-only project compiles. Nothing references this — the PowerShell collector
// loads the restored DuckDB.NET + Microsoft.Data.SqlClient assemblies directly (see
// collector/Initialize-SqlDashRuntime.ps1). See Runtime.csproj for why this project exists.
namespace SqlDash.Runtime;

internal static class Marker { }
