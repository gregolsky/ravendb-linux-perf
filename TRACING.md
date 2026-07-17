# Tracing types reference

Full menu of what the toolkit can capture, what question each type answers,
which engine to use, and the overhead to expect on a production RavenDB box.

See [OVERHEAD.md](OVERHEAD.md) for a deeper explanation of the two engines
(perf vs eBPF) and the `DOTNET_*` knobs that control .NET symbol emission.

---

## Quick-pick table

| Category | `--type` | What it answers | Engine | Overhead | In toolkit |
|---|---|---|---|---|---|
| **On-CPU** | `cpu` | Where are CPU cycles being spent? | perf / eBPF | Low (~1% at 99 Hz) | ✅ |
| **On-CPU** | *(PMU events)* | *Why* is code slow — cache misses, branch mispredicts, LBR | perf `-e …` | Low; PMU-gated in VMs/cloud | 📖 reference-only |
| **Off-CPU** | `offcpu` | Where are threads blocked — I/O waits, locks, syscall sleep | perf / eBPF | perf: high · eBPF: low | ✅ |
| **Off-CPU** | `offwake` | Who *unblocked* a thread (waker + sleeper stacks) — great for contention chains | eBPF | Low | ✅ |
| **Scheduler** | `runqlat` | Time threads sit *runnable but waiting for a CPU* — CPU saturation, noisy-neighbour | eBPF | Low | ✅ |
| **Block I/O** | `io` | Disk latency histogram, per-I/O trace, which code issues I/O, I/O sizes | perf (code-path) / eBPF (all) | Low–medium | ✅ |
| **Filesystem** | `io` (eBPF) | Slow FS operations above a threshold (`ext4slower`/`fileslower`) | eBPF | Low | ✅ |
| **Page cache** | `io` (eBPF) | Cache hit/miss ratio — is the working set in RAM? | eBPF | Low | ✅ |

**Tip:** Use the **perf engine** for `cpu` (zero extra deps, works everywhere).
Use the **eBPF engine** for everything else — in-kernel aggregation, lower overhead,
and access to tools that have no clean perf equivalent.

---

## Detailed descriptions

### `cpu` — On-CPU flamegraph

**Question:** "Where are my CPU cycles going?"

A classic timed-sampling flamegraph. The profiler fires at ~99 Hz, captures the
call stack, and the resulting SVG shows which call chains consume the most CPU
time. Width ∝ time on CPU.

**What to look for in RavenDB:**
- Wide `Raven.Server.Documents.Queries` / `Corax.*` towers → query engine hot
- Wide `Voron.Trees.*` / `Voron.Impl.Journal.*` → storage/journal hot
- Wide `libcoreclr!GarbageCollect*` → GC pressure
- Wide `sys_futex` / `pthread_mutex_*` → lock contention (but use `offcpu` to confirm)

| Engine | Command |
|---|---|
| perf (default) | `sudo bash perf/raven-perf-collect.sh --type cpu --service ravendb` |
| eBPF | `sudo bash ebpf/raven-ebpf-collect.sh --type cpu --service ravendb` |

Render: `bash perf/raven-perf-render.sh bundle.tgz` (or `ebpf/raven-ebpf-render.sh`)
Example: [cpu-flame.svg](examples/cpu-flame.svg)

---

### `offcpu` — Off-CPU (blocked-time) flamegraph

**Question:** "Where are my threads blocked, and for how long?"

Instead of sampling when threads are *running*, this captures when they are
*sleeping* — waiting for I/O, a lock, a futex, a network response. The flame is
time-weighted in microseconds (us): width ∝ total blocked time.

Differs from `cpu` in a critical way: a thread that holds a lock and does CPU work
will show up in `cpu`. The thread *waiting* for that lock will show up in `offcpu`.
Together they diagnose contention.

**What to look for in RavenDB:**
- `Raven.*` → `sys_read`/`sys_write` → `schedule` → wide block: I/O waits
- `Raven.*` → `futex_wait` → `schedule`: lock contention
- `Raven.*` → `epoll_wait` → `schedule`: idle network wait (often OK)
- Disproportionately large GC `schedule` blocks: GC stop-the-world pauses

| Engine | Command |
|---|---|
| perf | `sudo bash perf/raven-perf-collect.sh --type offcpu --service ravendb --sysctl-fix` |
| eBPF (recommended) | `sudo bash ebpf/raven-ebpf-collect.sh --type offcpu --service ravendb` |

> **Note (perf engine):** requires `kernel.sched_schedstats=1` for time-weighted
> stacks. The collector checks and optionally fixes this with `--sysctl-fix`.

Render: `bash perf/raven-perf-render.sh bundle.tgz`
Example: [offcpu-flame.svg](examples/offcpu-flame.svg)

---

### `offwake` — Off-wake / waker flamegraph

**Question:** "Who unblocked me? What's the contention chain?"

An extension of off-CPU: each sample shows *two* stacks — the blocked thread's
stack (what it was waiting for) and the *waker thread's* stack (what triggered
the wakeup). Critical for diagnosing lock chains where Thread A wakes Thread B
which wakes Thread C.

eBPF-only (`offwaketime` from bcc-tools).

| Engine | Command |
|---|---|
| eBPF | `sudo bash ebpf/raven-ebpf-collect.sh --type offwake --service ravendb` |

Render: `bash ebpf/raven-ebpf-render.sh bundle.tgz`
Example: [offwake-flame.svg](examples/offwake-flame.svg)

---

### `runqlat` — Run-queue latency histogram

**Question:** "Are threads *waiting for a CPU* even when they're not blocked?"

This measures the time a thread sits in the run queue — it's *runnable* but can't
get a CPU because all cores are busy. High run-queue latency points to CPU
saturation or noisy-neighbour issues (other processes/containers stealing cores).

Output is a histogram (text), not a flamegraph. eBPF-only (`runqlat` from bcc-tools).

| Engine | Command |
|---|---|
| eBPF | `sudo bash ebpf/raven-ebpf-collect.sh --type runqlat --service ravendb` |

Render: `bash ebpf/raven-ebpf-render.sh bundle.tgz` (prints histogram)
Example: [runqlat.txt](examples/runqlat.txt)

---

### `io` — Block I/O profiling suite

**Question:** "What is the disk doing, and which code paths cause it?"

The `io` type runs several complementary tools and bundles their output together:

| Output file | Tool | What it shows |
|---|---|---|
| `biolatency.txt` | `biolatency` | Disk request latency histogram (µs distribution per device) |
| `biosnoop.txt` | `biosnoop` | Every I/O request: PID, device, sector, bytes, latency — spot slow outliers |
| `io-codepath-flame.svg` | `biostacks` / `block:block_rq_issue` | Flamegraph of which code paths issue block I/O |
| `bitesize.txt` | `bitesize` | I/O request-size distribution — hints at random vs sequential access |
| `ext4slower.txt` | `ext4slower` | FS-level operations exceeding 1ms threshold |
| `cachestat.txt` | `cachestat` | Page-cache hits/misses/evictions per second |

**What to look for in RavenDB:**
- High `biolatency` p99/p999 (> 10ms for HDDs, > 1ms for NVMe) → storage bottleneck
- `biosnoop` rows with high latency from `Raven.Server` PID → transaction flushes or journal writes
- Wide `Voron.Impl.Journal.JournalWriter` stacks in `io-codepath` → WAL writes dominating
- `cachestat` showing low hit ratio → working set larger than available RAM

| Engine | Command |
|---|---|
| perf (code-path only) | `sudo bash perf/raven-perf-collect.sh --type io --service ravendb` |
| eBPF (full suite, recommended) | `sudo bash ebpf/raven-ebpf-collect.sh --type io --service ravendb` |

Render: `bash ebpf/raven-ebpf-render.sh bundle.tgz`
Examples: [io-codepath-flame.svg](examples/io-codepath-flame.svg) · [biolatency.txt](examples/biolatency.txt) · [biosnoop.txt](examples/biosnoop.txt)

---

## Reference-only (not scripted)

### Hardware-event / PMU CPU profiling

`perf record -e cache-misses -g -p $PID` samples on hardware performance counter
overflows rather than a timer. This gives a flamegraph weighted by a specific CPU
micro-architectural event — e.g., which code paths cause the most L3 cache misses
or branch mispredictions.

Useful when you *know* a hot path from `cpu` exists but want to understand *why*
it's slow at the micro-architectural level. Requires PMU access (often not available
in VMs or containers).

```bash
# Example: cache-miss flamegraph
sudo perf record -e cache-misses -g -F 99 -p $RAVEN_PID -- sleep 20
# Render with perf/raven-perf-render.sh or manually:
perf script | stackcollapse-perf.pl | flamegraph.pl --title "Cache misses" > cache-flame.svg
```

---

## Engine comparison

| | perf engine | eBPF engine |
|---|---|---|
| **Extra deps on RavenDB box** | None (`perf` usually pre-installed) | `bpfcc-tools` or `bpftrace` |
| **Output size** | Large `perf.data` (MB–GB for DWARF) | Tiny folded/text (KB) |
| **Off-CPU** | Needs `schedstats`; time-weighted via `perf inject -s` | Direct via `offcputime`; always time-weighted |
| **I/O details** | Code-path flamegraph only | Full suite: latency/snoop/sizes/FS/cache |
| **Scheduler** | No equivalent | `runqlat`/`runqlen` |
| **Waker stacks** | No equivalent | `offwaketime` |
| **Managed frames** | Via `/tmp/perf-<pid>.map` (both engines need this) | Same |
| **Recommended for** | `cpu` (FP or DWARF) on constrained boxes | Off-CPU/I/O/runqlat/offwake; anything needing low overhead |
