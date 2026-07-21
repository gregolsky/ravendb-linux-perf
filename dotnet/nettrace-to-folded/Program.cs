// nettrace-to-folded — turn a dotnet-trace .nettrace of GC allocation events into
// byte-weighted folded stacks (root;...;leaf;<AllocatedType> <bytes>) for flamegraph.pl.
//
// dotnet-trace's own `convert --format speedscope` only understands the CPU sample
// profiler, not allocation events — so there is no stock way to get a managed-allocation
// flamegraph on Linux. This walks GCAllocationTick_V4 (and, if present, sampled object
// allocation) events, resolves each managed call stack via TraceLog, and sums bytes.
//
// Usage:  nettrace-to-folded <trace.nettrace> [--summary <summary.txt>]
//   folded stacks are written to stdout; a by-type summary to --summary (or stderr).

using System.Text;
using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;
using Microsoft.Diagnostics.Tracing.Parsers.Clr;

if (args.Length < 1 || args[0] is "-h" or "--help")
{
    Console.Error.WriteLine("usage: nettrace-to-folded <trace.nettrace> [--summary <path>]");
    return args.Length < 1 ? 2 : 0;
}

string input = args[0];
string? summaryPath = null;
for (int i = 1; i < args.Length; i++)
{
    if (args[i] == "--summary" && i + 1 < args.Length) summaryPath = args[++i];
}

if (!File.Exists(input))
{
    Console.Error.WriteLine($"error: file not found: {input}");
    return 1;
}

// Convert the EventPipe stream to an etlx so call stacks are resolvable.
string etlx = TraceLog.CreateFromEventPipeDataFile(input);

var folded = new Dictionary<string, long>(StringComparer.Ordinal);   // stack -> bytes
var byType = new Dictionary<string, long>(StringComparer.Ordinal);   // type  -> bytes
long totalBytes = 0;
long eventCount = 0;

try
{
    using var log = new TraceLog(etlx);
    TraceLogEventSource source = log.Events.GetSource();

    void Accumulate(TraceCallStack? cs, string type, long bytes)
    {
        if (bytes <= 0) return;
        eventCount++;
        totalBytes += bytes;
        type = string.IsNullOrEmpty(type) ? "[unknown-type]" : type;
        byType[type] = byType.GetValueOrDefault(type) + bytes;

        // Frames are leaf-first from the call stack; reverse to root-first and
        // append the allocated type as the flame leaf.
        var frames = new List<string>(32);
        for (TraceCallStack? f = cs; f != null; f = f.Caller)
        {
            string name = f.CodeAddress.FullMethodName;
            if (string.IsNullOrEmpty(name))
            {
                string module = f.CodeAddress.ModuleName;
                name = string.IsNullOrEmpty(module) ? "[unknown]" : module;
            }
            // folded frames are ';'-separated — neutralize any stray ';'
            frames.Add(name.Replace(';', ':'));
        }
        frames.Reverse();
        frames.Add(type.Replace(';', ':'));

        string key = frames.Count > 0 ? string.Join(";", frames) : "[no stack];" + type;
        folded[key] = folded.GetValueOrDefault(key) + bytes;
    }

    // Default provider (GCAllocationTick_V4): type name + allocation amount + stack.
    source.Clr.GCAllocationTick += d => Accumulate(d.CallStack(), d.TypeName, d.AllocationAmount64);

    source.Process();

    // Emit folded stacks (stdout), sorted descending so the file is readable.
    var outBuf = new StringBuilder();
    foreach (var kv in folded.OrderByDescending(k => k.Value))
        outBuf.Append(kv.Key).Append(' ').Append(kv.Value).Append('\n');
    Console.Out.Write(outBuf.ToString());

    // By-type summary.
    var summary = new StringBuilder();
    summary.Append($"# managed allocations: {eventCount} tick events, {totalBytes:N0} bytes attributed\n");
    summary.Append("# bytes\ttype\n");
    foreach (var kv in byType.OrderByDescending(k => k.Value).Take(40))
        summary.Append($"{kv.Value,14:N0}\t{kv.Key}\n");

    if (summaryPath != null) File.WriteAllText(summaryPath, summary.ToString());
    else Console.Error.Write(summary.ToString());

    if (eventCount == 0)
        Console.Error.WriteLine("warning: no GCAllocationTick events found — was the GC provider (keyword 0x1) enabled, and was the app allocating during the capture?");
}
finally
{
    try { if (File.Exists(etlx)) File.Delete(etlx); } catch { /* best effort */ }
}

return 0;
