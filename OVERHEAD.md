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

## Production safety

Running these collectors against a live production RavenDB is designed to be safe, but
**no profiler is zero-impact** — be honest about which capture you run and for how long.

### What the collectors do and don't do

- **A normal capture (`--service` / `--pid`) is read-only w.r.t. the system and RavenDB.**
  It reads `/proc`, attaches kernel-mediated probes, and writes only its own bundle (temp dir
  or `--output`). It does **not** write RavenDB data, restart/stop the process, or change any
  config. The temp dir is removed on exit (`trap`).
- **eBPF is kernel-verified and can't crash the kernel.** uprobes/tracepoints detach on normal
  exit, on `Ctrl-C` (SIGINT), and even on SIGKILL — the kernel releases the BPF links when the
  tool process dies, so **no instrumentation is ever left attached** to RavenDB.
- **Every capture is time-bounded** by `--duration`, with a hard runtime ceiling in the
  collector (`_capture`): if a probe fails to self-terminate it is SIGINT-ed then SIGKILL-ed, so
  a capture can never run away or hang the box.
- The **worst case is transient CPU/latency overhead during the capture window**, not a crash,
  data change, or lingering state.

### Per-type overhead (lowest → highest)

| `--type` | Mechanism | Overhead | Prod guidance |
|---|---|---|---|
| `cpu` | timed sampling @99 Hz | ~1% | ✅ Safe; run freely (short windows) |
| `runqlat` | sched tracepoints, in-kernel histogram | Very low | ✅ Safe |
| `offcpu` / `offwake` | sched tracepoints, in-kernel aggregation | Low | ✅ Safe |
| `io` | block tracepoints + `biosnoop` per-I/O | Low–medium | ✅ Safe; heavy only under extreme IOPS |
| `faults` | `page_fault_user` tracepoint + user stack walk per fault | Medium | ⚠️ Fine for short windows; scales with fault rate |
| `managed-alloc` | EventPipe GC events (verbose) | Medium | ⚠️ Scales with allocation rate; bounded to duration |
| `alloc` | **uprobes on `malloc`/`mmap`** (stackcount + bpftrace) **+ `memleak`** | **Highest** | ⚠️ **Use with care** — see below |

### `alloc` is the one to treat carefully

It instruments `malloc`/`mmap` — very hot paths — with a **stack walk on every call**, via up to
three tools (stackcount, bpftrace, memleak) run sequentially, and `memleak` additionally holds a
map of outstanding allocations. On an allocation-heavy workload this adds **measurable CPU and
latency for the duration of the capture**. RavenDB's arena pooling keeps the raw `malloc` rate
moderate, which helps, but treat `alloc` as a deliberate, short, ideally off-peak capture
(**5–15 s**), not something to leave running. All other types are much lighter.

### Opt-in changes that are NOT part of a normal capture

- **`--sysctl-fix`** changes **host-wide** kernel settings — `perf_event_paranoid=-1` and
  `kptr_restrict=0` (security-relevant: lets any user profile and exposes kernel addresses) and
  `sched_schedstats=1` (a tiny always-on scheduler cost). It is **opt-in**; without it the
  collector just tells you what to change. `common/00-prereqs.sh --persist` additionally makes
  these survive reboot. Revert with:
  ```bash
  sudo sysctl kernel.perf_event_paranoid=2 kernel.kptr_restrict=1 kernel.sched_schedstats=0
  sudo rm -f /etc/sysctl.d/99-perf.conf     # if --persist was used
  ```
- **`DOTNET_EnableWriteXorExecute=0`** (set at RavenDB launch, not by the collector) removes a
  JIT-hardening mitigation — weigh it for your threat model (see the knob section above).
- **`--demo`** downloads, launches, and kills **its own** RavenDB — it is a POC helper. **Never
  run `--demo` against a production server.**
- **`--dwarf`** (perf engine) copies 64 KB of stack per sample — high CPU/IO; prefer the default
  frame-pointer (`--fp`) capture in production.

### Bottom line

`cpu`, `offcpu`, `offwake`, `runqlat`, `io`, and `faults` are low-risk on production with short
windows. `managed-alloc` and especially **`alloc`** cost more — run them briefly and deliberately.
Nothing here modifies RavenDB or persists on the box (absent `--sysctl-fix`/`--persist`), and
instrumentation always detaches when the tool exits.

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

**Now scripted:** `dotnet/raven-dotnet-collect.sh` uses exactly this pipeline for the
`managed-alloc` trace type — it collects `GCAllocationTick` events and the renderer converts them
into a byte-weighted managed-allocation flamegraph (see [TRACING.md](TRACING.md#managed-alloc)).

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
supporting seven trace types:

| `--type` | bcc tool(s) | What it produces |
|---|---|---|
| `cpu` | `profile` | On-CPU folded stacks |
| `offcpu` | `offcputime` | Time-weighted blocked-time folded stacks |
| `offwake` | `offwaketime` | Off-CPU + waker stacks |
| `io` | `biolatency` + `biosnoop` + `biostacks` + `ext4slower` + `cachestat` + `bitesize` | Block I/O suite |
| `runqlat` | `runqlat` | Run-queue latency histogram |
| `alloc` | `bpftrace` (sum malloc/mmap size → bytes) + `memleak` (held bytes) + `stackcount` (call-count fallback) | Byte-VOLUME flames (allocated) + byte-HELD flame (outstanding) + call-count fallback |
| `faults` | `stackcount t:exceptions:page_fault_user` | Page-fault (RSS-growth) folded stacks |

> **`alloc` overhead is higher than the others.** `cpu`/`offcpu`/`io`/`runqlat` sample or
> hook a bounded set of events; `alloc` attaches **uprobes to `malloc`/`mmap64`**, which fire
> on *every* native allocation in the target. RavenDB's arena/pool allocators keep the rate
> moderate (block-level, not per-object), but treat it as **medium** overhead: use short
> windows (10–15 s), and note the collector runs its probes sequentially so only one uprobe
> set is active at a time. For fine-grained bytes-weighting, `memleak -s SAMPLE_RATE` can
> sample every Nth allocation to trade accuracy for lower cost.

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
