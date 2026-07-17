# Profiling knobs: what they do, what they cost, and alternatives

Reference for RavenDB operators deciding what to enable in production.
Everything here applies to any self-contained .NET 6+ application, not just RavenDB.

For the full menu of trace types (on-CPU, off-CPU, I/O, run-queue latency, off-wake)
and when to use each, see **[TRACING.md](TRACING.md)**.

---

## What each knob does

### `DOTNET_PerfMapEnabled`

Controls whether the .NET JIT writes a **symbol side-channel** to disk as it compiles
methods. External profilers (`perf`, eBPF, Parca, Pyroscope …) only see raw
instruction pointers; without this, every JIT frame shows as a hex address.

| Value | Files written | Used by |
|---|---|---|
| `1` | `/tmp/perf-<pid>.map` **and** `/tmp/jit-<pid>.dump` | Either recipe below |
| `2` | `/tmp/jit-<pid>.dump` only | DWARF + `perf inject` recipe |
| `3` | `/tmp/perf-<pid>.map` only | Frame-pointer (`-g`) recipe |

**`/tmp/perf-<pid>.map`** (perfmap) — a plain-text `address size symbol` file the
kernel's `perf script` reads at symbolization time. One line per JIT method,
appended as the JIT compiles new methods. Very fast to write; fast to read.

**`/tmp/jit-<pid>.dump`** (jitdump) — a binary log of every JIT event (method load,
method unload, line-number table). Used by `perf inject --jit` to synthesize
per-method ELF objects in `~/.debug/jit/`, which gives exact line numbers and
inlined frame information — richer but heavier to process.

**Timing**: the runtime writes to these files **at JIT time** (when a method is
first compiled), not at sample time. Once the server has warmed up and all hot paths
have been JITted, there is essentially zero ongoing I/O from this knob.

---

### `DOTNET_EnableWriteXorExecute=0`

Disables the **W^X (Write-XOR-Execute) hardening** on JIT code pages.

By default (.NET 6+, Linux), the JIT emits code through a "doublemapper": it maps
the same physical memory twice — once writable (for the JIT to write into) and once
executable (for the CPU to run). The two mappings have *different virtual addresses*.
`perf` sees the executable address in the instruction pointer, but the perfmap records
the *writable* address — they don't match, so every managed frame resolves to
`memfd:doublemapper` (an anonymous mapping name) instead of `Raven.Something`.

Setting this to `0` makes JIT pages **RWX** (readable, writable, and executable from
the same address), eliminating the address mismatch. The tradeoff: this is a security
regression — it removes a hardening layer that makes exploiting JIT bugs harder.

Reference: [dotnet/runtime#97765](https://github.com/dotnet/runtime/issues/97765).

**Performance impact**: none or slightly positive (no double-map bookkeeping).
**Security impact**: removes W^X protection from JIT pages.

---

### `DOTNET_ReadyToRun=0`

Disables **ReadyToRun (R2R) precompiled images** for framework assemblies.

By default, the .NET runtime ships `System.*`, `Microsoft.*`, and other framework
libraries as R2R binaries — partly compiled native images bundled inside the managed
DLLs. On startup the runtime uses the precompiled native code directly without
re-JITting it. These methods are not JIT-compiled, so they never get an entry in the
jitdump or perfmap, and they show as stripped native frames in a flamegraph (you see
`coreclr!MethodDesc::Call` but not `System.IO.Pipelines.PipeReader.ReadAsync`).

Setting this to `0` forces the runtime to **JIT-compile everything**, including all
framework code. All methods get entries in the side-channel, so your flamegraph shows
full managed call stacks through framework code.

The cost:
- **Startup is slower** (everything must be JITted before it can run).
- **Higher JIT CPU/memory** during warm-up; tiered compilation eventually re-optimizes
  hot methods, so steady-state throughput is usually not affected.

**Verdict**: optional. Your own `Raven.*`/`Voron.*` code was JITted regardless and
will always appear symbolized. `DOTNET_ReadyToRun=0` only adds framework frame names.
Use it on dev boxes when you want full stacks; omit it in production if startup
latency or warm-up JIT load matters.

---

### `DOTNET_PerfMapShowOptimizationTiers=1`

Appends the **optimization tier** to JIT method names in the side-channel:

- `Tier0` — quick first-time compilation, fewer optimizations.
- `Tier1` — re-compiled hot methods with full optimization.
- `OSR` (On-Stack Replacement) — an in-flight re-compilation of a long-running loop.

With this set, you can identify cold/under-optimized methods still in Tier0 directly
from the flamegraph — useful when diagnosing startup or warm-up behavior. Zero
overhead beyond slightly longer symbol strings in the map file.

---

### `perf record` flags that pair with the knobs

These are not `DOTNET_*` env vars but are part of the capture side of the same
pipeline:

| Flag | What it does | When to use |
|---|---|---|
| `-F 99` | Sample at 99 Hz (avoids lock-step with 100 Hz kernel timers) | Always |
| `-g` | Frame-pointer unwinding (in-kernel, cheap) | FP recipe (default) |
| `-k CLOCK_MONOTONIC` | Use monotonic clock for sample timestamps | **Mandatory** with `perf inject --jit`; jitdump timestamps use CLOCK_MONOTONIC and must match |
| `--call-graph dwarf,65528` | Copy up to 64 KB of raw stack per sample for DWARF unwinding | DWARF recipe (heavier) |
| `perf inject --jit` | Post-process jitdump into per-method ELFs; rewrites `perf.data` so managed frames resolve with line info | DWARF recipe |

---

## Overhead summary

The **knobs** are cheap; the **sampling method** is where the real cost is.

| Knob / flag | When the cost is paid | Steady-state impact | Prod-safe? |
|---|---|---|---|
| `DOTNET_PerfMapEnabled` (1/2/3) | JIT time (append to file as methods compile) | ~zero after warm-up | ✅ Yes — leave it on |
| `DOTNET_EnableWriteXorExecute=0` | Startup (changes memory mapping strategy) | None / slight positive | ⚠️ Perf-safe; security regression |
| `DOTNET_ReadyToRun=0` | Startup + entire warm-up (re-JITs framework) | Startup latency; tapers | ❌ Dev/debug only |
| `DOTNET_PerfMapShowOptimizationTiers=1` | JIT time (longer symbol strings) | Negligible | ✅ Yes |
| `perf record -F 99 -g` (FP) | During capture only | ~1% CPU | ✅ Low impact |
| `perf record --call-graph dwarf,65528` | During capture (64 KB stack copy per sample) | High CPU + I/O | ⚠️ Short windows only |
| `perf inject --jit` | Post-capture on renderer, never on DB box | N/A (off-box) | ✅ N/A |

---

## Alternative profiling approaches

### In-runtime: EventPipe (`dotnet-trace`, `dotnet-monitor`)

The .NET runtime has a built-in telemetry pipeline (EventPipe) that emits managed
events from inside the runtime. Tools like `dotnet-trace` attach to a running process
over a Unix socket — **no root, no `perf_event_paranoid`, no knobs needed**.

```bash
dotnet-trace collect --process-id $RAVEN_PID --output trace.nettrace
# Convert to Speedscope / PerfView format:
dotnet-trace convert trace.nettrace --format Speedscope
```

**What you get:** complete managed call stacks with exact symbol names, GC events,
thread contention, JIT stats. Works in locked-down containers.

**What you don't get:** native/kernel layers. You see that a method called into
`libcoreclr.so` but not the GC/JIT internals or the kernel syscalls beneath it. For
"why is the kernel layer hot" or "is this a GC pause or an I/O syscall" questions,
EventPipe is the wrong tool.

---

### External sampler: `perf` (what this toolkit uses for `cpu`, `offcpu`, `io`)

`perf record` is a kernel-side hardware/software counter sampler. It captures raw
instruction pointers from all frames — managed, native, kernel — and relies on the
`DOTNET_*` side-channel to turn managed addresses into names.

Best for ad-hoc captures; the `perf/raven-perf-collect.sh` + `perf/raven-perf-render.sh`
split keeps the DB box impact minimal.

For `offcpu` profiling via perf, `kernel.sched_schedstats=1` is required (to
time-weight stacks by sleep duration via `perf inject -s`).

---

### External sampler: eBPF (bcc-tools, bpftrace — `offcpu`, `io`, `runqlat`, `offwake`)

eBPF profilers run a BPF program in the kernel that fires on timer interrupts or
tracepoints, aggregates data in-kernel, and ships only the summary to userspace.
Compared to `perf record`:

- **Always-on**: continuous profiling with no manual capture/stop cycle.
- **Lower overhead**: stacks are aggregated in-kernel; you don't write a large
  `perf.data` file.
- **Fleet-friendly**: the agent runs as a daemon; data flows to a central backend
  (Parca server, Grafana Pyroscope) where you query over time.

This toolkit uses bcc-tools for ad-hoc captures in `ebpf/raven-ebpf-collect.sh`,
supporting five trace types:

| `--type` | bcc tool(s) | What it produces |
|---|---|---|
| `cpu` | `profile` | On-CPU folded stacks |
| `offcpu` | `offcputime` | Time-weighted blocked-time folded stacks |
| `offwake` | `offwaketime` | Off-CPU + waker stacks |
| `io` | `biolatency` + `biosnoop` + `biostacks` + `ext4slower` + `cachestat` + `bitesize` | Block I/O suite |
| `runqlat` | `runqlat` | Run-queue latency histogram |

For continuous fleet-wide profiling:
- [Grafana Pyroscope](https://grafana.com/oss/pyroscope/) — pull or push; Helm chart.
- [Parca](https://www.parca.dev/) — open source, pull-based via parca-agent.

See [TRACING.md](TRACING.md) for descriptions and per-type overhead.

---

## Does eBPF require the same knobs?

**Yes — the symbolization knobs are required by any external profiler, not just `perf`.**

The JIT symbol problem is fundamental: eBPF captures raw instruction pointers just
like `perf`. To turn `0x7f9a3c1d0ab0` into `Voron.Trees.Tree.FindPageFor` it needs
the same side-channel.

| Knob | `perf` | eBPF (Parca/Pyroscope) | `dotnet-trace` |
|---|---|---|---|
| `DOTNET_PerfMapEnabled` | Required | Required (reads same `/tmp/perf-<pid>.map`) | Not needed |
| `DOTNET_EnableWriteXorExecute=0` | Required (else `memfd:doublemapper`) | Required (same address mismatch) | Not needed |
| `DOTNET_ReadyToRun=0` | Optional | Optional | Not needed |
| `perf_event_paranoid ≤ 1` | Required | Required | Not needed |

What eBPF changes is the **collection and unwinding mechanism** — not the need for
the runtime to emit a symbol side-channel. The only way to avoid these knobs entirely
is to profile from inside the runtime (EventPipe) and accept the loss of native/kernel
visibility.

---

## Recommendation

| Setting | Production recommendation |
|---|---|
| `DOTNET_PerfMapEnabled=1` | **Enable permanently.** Near-zero steady-state cost; unlocks any external profiler (perf, eBPF) on demand without a restart. |
| `DOTNET_EnableWriteXorExecute=0` | **Enable permanently.** No perf cost; required knob for any external profiler. Weigh the hardening regression for your threat model. |
| `DOTNET_ReadyToRun=0` | **Dev/debug only.** Drop from production unless you specifically need framework frame names and can afford slower restarts. |
| `DOTNET_PerfMapShowOptimizationTiers=1` | Optional; useful while investigating warm-up or tiering behaviour. |
| eBPF continuous profiler | **Recommended for fleets.** With `PerfMapEnabled` and `EnableWriteXorExecute=0` always on, deploying a Parca or Pyroscope eBPF agent gives you always-on, low-overhead three-layer profiling with no manual `perf record` cycle. |
