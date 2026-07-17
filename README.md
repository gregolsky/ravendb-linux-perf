# RavenDB perf flamegraphs

Brendan-Gregg-style flamegraphs from a live RavenDB server showing merged
**managed .NET frames · RavenDB/Voron internals · libcoreclr/JIT/GC native frames · kernel stacks**.

Supports **on-CPU**, **off-CPU** (blocked time), **I/O**, **run-queue latency**,
and **off-wake** profiling — across two engines (perf tracepoints or eBPF).

See [TRACING.md](TRACING.md) for a full menu of trace types and what each answers.
See [OVERHEAD.md](OVERHEAD.md) for knob explanations and overhead comparisons.
See [examples/](examples/) for real captures from a RavenDB server.

---

## Architecture

```
┌──────────────────────────────────────┐         ┌─────────────────────────────────┐
│  RavenDB server (constrained)        │  nc/S3  │  Renderer (your workstation /   │
│                                      │ ──────► │  EC2 / Docker)                  │
│  perf/raven-perf-collect.sh          │         │                                 │
│  ebpf/raven-ebpf-collect.sh          │         │  perf/raven-perf-render.sh      │
│  ├─ preflight (env + sysctl)         │         │  ebpf/raven-ebpf-render.sh      │
│  ├─ perf record OR eBPF tools        │         │  ├─ perf inject --jit (dwarf)   │
│  ├─ gather: data + side-channel +    │         │  ├─ perf script --kallsyms      │
│  │   kallsyms + meta                 │         │  ├─ stackcollapse-perf.pl       │
│  └─ tar | nc / aws s3 cp             │         │  ├─ flamegraph.pl               │
└──────────────────────────────────────┘         │  └─ publish SVG → S3 / browser  │
                                                 └─────────────────────────────────┘
```

Nothing heavy (inject, DWARF unwind, SVG render) runs on the DB host.

---

## Engine × type matrix

| `--type` | What it answers | perf engine | eBPF engine |
|---|---|---|---|
| `cpu` | Where are CPU cycles? | ✅ default | ✅ |
| `offcpu` | Where are threads blocked? | ✅ (needs schedstats) | ✅ recommended |
| `io` | What is the disk doing? | ✅ code-path only | ✅ full suite |
| `runqlat` | Waiting for a CPU? | ❌ | ✅ |
| `offwake` | Who unblocked me? | ❌ | ✅ |

**Tip:** use the **perf engine** for `cpu`; use the **eBPF engine** for everything else.

---

## Prerequisites

### On the RavenDB server

| Requirement | Check | Fix |
|---|---|---|
| `perf` | `perf --version` | `apt-get install linux-tools-$(uname -r)` |
| `perf_event_paranoid ≤ 1` | `cat /proc/sys/kernel/perf_event_paranoid` | `sudo sysctl kernel.perf_event_paranoid=-1` |
| `kptr_restrict = 0` | `cat /proc/sys/kernel/kptr_restrict` | `sudo sysctl kernel.kptr_restrict=0` |
| `nc` (for nc transport) | `nc --version` | `apt-get install netcat-openbsd` |
| `aws` CLI (for S3 transport) | `aws --version` | `snap install aws-cli --classic` |
| eBPF tools (for `offcpu`/`io`/`runqlat`/`offwake`) | `offcputime-bpfcc --version` | `apt-get install bpfcc-tools` |

`perf_event_paranoid` controls who can use the kernel's performance event subsystem.
The default on most distros is `2` or `4` (restrict to root only); `perf` needs `≤ 1`
to sample other processes. Set to `-1` to allow any user to profile any process.

`kptr_restrict` controls whether kernel symbol addresses are exposed in
`/proc/kallsyms`. At `1` (default) symbol addresses are zeroed out for non-root
users, so kernel frames in the flamegraph show as hex addresses. Setting it to `0`
makes the full symbol table visible, giving you readable kernel stack frames
(`entry_SYSCALL_64`, `futex_wait`, etc.). The `--kallsyms=` snapshot the collector
captures preserves these symbols for use on the off-box renderer.

Run `sudo bash common/00-prereqs.sh [--persist]` to check and fix all of the above.

### On the renderer

`perf`, `perl`, `git` (to clone FlameGraph), optionally `aws` CLI.
Or use the Docker image — it has everything.

### RavenDB must be launched with profiling knobs

The `DOTNET_*` knobs **must be set when the process starts** — they cannot be injected
into an already-running server.

**systemd service** (production):
```bash
sudo systemctl edit ravendb
```
Add inside `[Service]`:
```ini
[Service]
Environment="DOTNET_PerfMapEnabled=1"
Environment="DOTNET_ReadyToRun=0"
Environment="DOTNET_EnableWriteXorExecute=0"
```
```bash
sudo systemctl restart ravendb
```

**Docker** (`docker run ravendb/ravendb`):
```bash
docker run \
  -e DOTNET_PerfMapEnabled=1 \
  -e DOTNET_ReadyToRun=0 \
  -e DOTNET_EnableWriteXorExecute=0 \
  ... (your existing flags) ... \
  ravendb/ravendb
```

**Manual shell** (POC / dev):
```bash
export DOTNET_PerfMapEnabled=1
export DOTNET_ReadyToRun=0
export DOTNET_EnableWriteXorExecute=0
./RavenDB/Server/Raven.Server
```
Or use `common/20-run-ravendb-profiled.sh` (POC only).

| `DOTNET_PerfMapEnabled` | Effect |
|---|---|
| `1` | Both perfmap + jitdump (use either recipe) |
| `2` | Jitdump only (`/tmp/jit-<pid>.dump`) — DWARF+inject recipe |
| `3` | Perfmap only (`/tmp/perf-<pid>.map`) — FP recipe |

---

## Quick start: POC on a dev box

```bash
# 0. Clone and cd
git clone https://github.com/gregolsky/ravendb-linux-perf && cd ravendb-linux-perf

# 1. Prerequisites (kernel settings + FlameGraph clone + eBPF check)
sudo bash common/00-prereqs.sh --persist

# 2. Download RavenDB (skip if already installed)
bash common/10-get-ravendb.sh

# 3. Launch RavenDB with profiling knobs (in a separate terminal)
bash common/20-run-ravendb-profiled.sh --fp      # or --dwarf for richer frames

# 4. Drive load (another terminal)
bash common/30-load.sh --duration 60

# 5a. Collect on-CPU (while load is running)
sudo bash perf/raven-perf-collect.sh \
  --pid "$(pgrep -f Raven.Server | head -1)" \
  --type cpu --duration 20 --output /tmp/raven-perf-out

# 5b. Or collect off-CPU:
sudo bash ebpf/raven-ebpf-collect.sh \
  --pid "$(pgrep -f Raven.Server | head -1)" \
  --type offcpu --duration 30 --output /tmp/raven-ebpf-out

# 6. Render (on this box or transfer to another)
bash perf/raven-perf-render.sh /tmp/raven-perf-out/raven-perf-cpu-*.tgz --open
bash ebpf/raven-ebpf-render.sh /tmp/raven-ebpf-out/raven-ebpf-offcpu-*.tgz --open
```

---

## Production usage: `curl | bash` one-liners

### perf engine (recommended for `cpu`)

```bash
# Systemd service → send over nc to renderer
curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/perf/raven-perf-collect.sh | \
  sudo bash -s -- --service ravendb --type cpu --duration 20 --nc renderer-host:9000

# Docker container → S3
curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/perf/raven-perf-collect.sh | \
  sudo -E S3_BUCKET=s3://debug-greg/perf-artifacts \
  bash -s -- --docker ravendb --type cpu --duration 20

# Explicit PID, off-CPU (perf engine)
curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/perf/raven-perf-collect.sh | \
  sudo bash -s -- --pid 12345 --type offcpu --duration 20 --nc renderer-host:9000
```

### eBPF engine (recommended for `offcpu`, `io`, `runqlat`, `offwake`)

```bash
# Systemd service, off-CPU → nc
curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/ebpf/raven-ebpf-collect.sh | \
  sudo bash -s -- --service ravendb --type offcpu --duration 30 --nc renderer-host:9000

# Docker container, full I/O suite → S3
curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/ebpf/raven-ebpf-collect.sh | \
  sudo -E S3_BUCKET=s3://debug-greg/perf-artifacts \
  bash -s -- --docker ravendb --type io --duration 30

# Run-queue latency (CPU saturation check)
curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/ebpf/raven-ebpf-collect.sh | \
  sudo bash -s -- --pid 12345 --type runqlat --duration 20 --nc renderer-host:9000
```

### Renderer side (nc transport)

```bash
# 1. Listen for the bundle
nc -l 9000 > bundle.tgz

# 2. Render (auto-detects engine and type from meta.txt)
bash perf/raven-perf-render.sh bundle.tgz          # perf bundles
bash ebpf/raven-ebpf-render.sh bundle.tgz          # eBPF bundles

# 3. Or render → S3
bash perf/raven-perf-render.sh bundle.tgz --s3-bucket s3://debug-greg/perf-artifacts

# 4. Or use the Docker renderer (no local perf/perl needed):
docker build -f perf/Dockerfile.renderer -t gregolsky/raven-perf-renderer .
nc -l 9000 > bundle.tgz
docker run --rm -v "$(pwd)":/data \
  gregolsky/raven-perf-renderer bundle.tgz
```

---

## FP vs DWARF capture

> For a full explanation of what each knob does, its overhead, and how it compares to
> eBPF continuous profilers and `dotnet-trace`, see **[OVERHEAD.md](OVERHEAD.md)**.

| | **Frame-pointer (default)** | **DWARF + `perf inject`** |
|---|---|---|
| **On-box cost** | Low — in-kernel unwinding, small `perf.data` | High — copies 64 KB stack per sample |
| **`DOTNET_PerfMapEnabled`** | `1` or `3` | `1` or `2` |
| **Extra `perf record` flag** | `-g` | `-k CLOCK_MONOTONIC --call-graph dwarf,65528` |
| **Renderer step** | None | `perf inject --jit` |
| **Frame quality** | Managed + native + kernel merged | + inlined frames + line numbers |
| **Recommended for** | Constrained prod boxes | Dev/analysis boxes |

---

## Verifying your flamegraph has all three layers

Open the SVG in a browser and look for:

| Layer | What to look for |
|---|---|
| **RavenDB managed** | `Raven.Server.*`, `Voron.*`, `Raven.Client.*` |
| **.NET runtime** | `libcoreclr.so`, `clrjit`, `GarbageCollect`, `JIT_*` |
| **Kernel** | `entry_SYSCALL_64`, `__x64_sys_*`, `futex_wait`, `schedule` |

**If you see wide `memfd:doublemapper` or `0x7f…` towers:** `DOTNET_EnableWriteXorExecute=0`
was not set on the RavenDB process. Relaunch with the knob and re-capture.

**If you see no managed frames at all:** The side-channel file was missing or had the
wrong PID. The collector preflight should have caught this, but check
`ls -l /tmp/perf-<pid>.map /tmp/jit-<pid>.dump`.

---

## Gotchas

### Clock mismatch → no managed symbols after inject
`perf record -k CLOCK_MONOTONIC` must match the clock the jitdump uses. If `perf inject`
runs fine but managed frames still show as hex addresses, the timestamps didn't align.
perf 6.8 (on this box) handles `JITDUMP_USE_ARCH_TIMESTAMP` auto-detection.

### `perf_event_paranoid` / `kptr_restrict` revert on reboot
Use `common/00-prereqs.sh --persist` to write `/etc/sysctl.d/99-perf.conf`.

### Container PID namespace
In `--docker` mode the perfmap/jitdump filenames use the **container-internal PID**
(`NSpid` from `/proc/<hostpid>/status`) and live in the container's `/tmp`. The
collector handles this automatically:
- perfmap is renamed to the host PID (so `perf script` finds it by the recorded PID)
- jitdump keeps the namespaced PID (so `perf inject` finds it by the MMAP path)

### Knobs need a restart
`systemctl edit` / `docker run -e` take effect only after a restart.

### `DOTNET_ReadyToRun=0` and startup time
Makes the runtime JIT-compile all framework code — startup is slower but all library
symbols appear in the flamegraph. Drop in production if startup latency matters.

### Off-CPU perf needs schedstats
`perf record -e sched:sched_stat_sleep` needs `kernel.sched_schedstats=1` to produce
time-weighted stacks. Use `--sysctl-fix` or set it manually.

### eBPF and VM environments
Some eBPF tools (`biosnoop`, `biolatency`) may produce no output in VMs where block I/O
bypasses the standard block-layer tracepoints (virtio-blk, cloud storage drivers).
Run `biolatency-bpfcc 1 3` to verify your environment; if empty, fall back to
`perf record -e block:block_rq_issue` (perf `io` type) which usually works.

---

## File layout

```
ravendb-linux-perf/
├── README.md                       # This file
├── OVERHEAD.md                     # Knob explanations + overhead reference
├── TRACING.md                      # Full trace-type reference table
├── common/
│   ├── 00-prereqs.sh               # Check/fix kernel settings + clone FlameGraph + eBPF check
│   ├── 10-get-ravendb.sh           # Download RavenDB release (POC only)
│   ├── 20-run-ravendb-profiled.sh  # Launch with profiling knobs (POC only)
│   └── 30-load.sh                  # Northwind sample data + query/write load loop
├── perf/
│   ├── raven-perf-collect.sh       # Thin on-box collector (perf engine)
│   ├── raven-perf-render.sh        # Off-box renderer (perf bundles)
│   └── Dockerfile.renderer         # Self-contained Docker renderer (works for eBPF bundles too)
├── ebpf/
│   ├── raven-ebpf-collect.sh       # Thin on-box collector (eBPF engine)
│   └── raven-ebpf-render.sh        # Off-box renderer (eBPF bundles)
├── examples/                       # Real RavenDB captures (Northwind load)
│   ├── cpu-flame.svg
│   ├── offcpu-flame.svg
│   ├── io-codepath-flame.svg
│   ├── runqlat.txt
│   ├── biolatency.txt
│   ├── biosnoop.txt
│   └── README.md
└── FlameGraph/                     # Cloned by common/00-prereqs.sh (gitignored)
    ├── flamegraph.pl
    └── stackcollapse-perf.pl
```
