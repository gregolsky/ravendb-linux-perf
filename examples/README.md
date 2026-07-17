# Example outputs

All SVGs and text artifacts in this directory were captured from a live RavenDB
server (version 7.2.x) under synthetic Northwind query + write load
(`common/30-load.sh` — concurrent RQL `from Orders` queries + bulk PUT writes).

See [TRACING.md](../TRACING.md) for what each type answers and how to interpret it.

---

## `cpu-flame.svg` — On-CPU flamegraph

Captured with `perf record -F 99 -g -p $PID -- sleep 20`.

Width ∝ CPU time. Look for:
- `Raven.Server.Documents.Queries.*` / `Corax.*` — query engine hot paths
- `Voron.Trees.*` / `Voron.Impl.Journal.*` — storage/WAL writes
- `libcoreclr.so` → `GarbageCollect` — GC activity
- Kernel `entry_SYSCALL_64` / `futex_wait` — syscall / lock contention

→ [Open cpu-flame.svg](cpu-flame.svg)

---

## `offcpu-flame.svg` — Off-CPU (blocked-time) flamegraph

Captured with `perf record -e sched:sched_switch -e sched:sched_stat_sleep -a -g --pid $PID`.

Width ∝ time threads spent blocked (not running on CPU). Look for:
- `Raven.*` → `sys_read`/`sys_write` → `__schedule` — waiting on I/O
- `Raven.*` → `futex_wait` → `__schedule` — waiting on a lock
- `Raven.*` → `epoll_wait` → `__schedule` — idle network wait (often OK)
- Wide `libcoreclr.so` → `GarbageCollect` → `__schedule` — GC stop-the-world

→ [Open offcpu-flame.svg](offcpu-flame.svg)

---

## `io-codepath-flame.svg` — Block I/O by code path

Captured with `perf record -e block:block_rq_issue -e block:block_rq_complete -a -g`.

Each frame shows which code path was on the CPU when a block I/O request was
issued. Width ∝ number of I/O requests from that call chain. Look for:
- `Voron.Impl.Journal.JournalWriter` — WAL (write-ahead log) writes
- `Voron.Impl.Paging.*` — data page flushes
- `Raven.Server.Documents.Indexes.*` → storage → I/O — indexing writes

→ [Open io-codepath-flame.svg](io-codepath-flame.svg)

---

## `runqlat.txt` — Scheduler run-queue latency histogram

Captured with `runqlat-bpfcc -T -P -m 20` (millisecond histogram, 20s window,
per-PID). Shows how long threads sat in the scheduler run queue *runnable but
waiting for a CPU* — indicating CPU saturation or noisy-neighbour issues.

→ [Open runqlat.txt](runqlat.txt)

---

## `biolatency.txt` — Block I/O latency histogram

Captured with `biolatency-bpfcc -T -D -m 20 1` (millisecond histogram, per disk,
20s window). Shows the distribution of disk request latencies.

Most requests should be in the 0→1 ms bucket on NVMe. Spikes in the 8–31 ms
range under light load indicate storage pressure or write stalls
(e.g., journal flush waiting on fsync).

→ [Open biolatency.txt](biolatency.txt)

---

## `biosnoop.txt` — Per-I/O trace (illustrative)

Shows the format of `biosnoop-bpfcc` output: one line per I/O request with
timestamp, process, disk, direction (R/W), sector, bytes, and latency.
The example here is synthetic (see file header) — actual output requires
block-layer eBPF tracepoint support which may not be available in all VMs.

→ [Open biosnoop.txt](biosnoop.txt)
