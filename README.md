# RavenDB perf flamegraphs

Brendan-Gregg-style flamegraphs from a live RavenDB server showing merged
**managed .NET frames · RavenDB/Voron internals · libcoreclr/JIT/GC native frames · kernel stacks**.

## Architecture

```
┌──────────────────────────────────┐         ┌─────────────────────────────────┐
│  RavenDB server (constrained)    │  nc/S3  │  Renderer (your workstation /   │
│                                  │ ──────► │  EC2 / Docker)                  │
│  raven-perf-collect.sh           │         │                                 │
│  ├─ preflight (env + sysctl)     │         │  raven-perf-render.sh           │
│  ├─ perf record (light FP)       │         │  ├─ perf inject --jit (dwarf)   │
│  ├─ gather: perf.data +          │         │  ├─ perf script --kallsyms      │
│  │   perfmap/jitdump + kallsyms  │         │  ├─ stackcollapse-perf.pl       │
│  └─ tar | nc / aws s3 cp         │         │  ├─ flamegraph.pl               │
└──────────────────────────────────┘         │  └─ publish SVG → S3 / browser  │
                                             └─────────────────────────────────┘
```

Nothing heavy (DWARF unwind, inject, SVG render) runs on the DB host.

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

Run `sudo bash 00-prereqs.sh [--persist]` to check and fix all of the above in one shot.

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
Or use `20-run-ravendb-profiled.sh` (POC only; downloads RavenDB automatically).

| `DOTNET_PerfMapEnabled` | Effect |
|---|---|
| `1` | Both perfmap + jitdump (use either recipe) |
| `2` | Jitdump only (`/tmp/jit-<pid>.dump`) — DWARF+inject recipe |
| `3` | Perfmap only (`/tmp/perf-<pid>.map`) — FP recipe |

---

## Quick start: POC on a dev box

```bash
# 0. Clone this repo / cd into this directory
cd /home/gregolsky/Dev/perf

# 1. Prerequisites (kernel settings + FlameGraph clone)
sudo bash 00-prereqs.sh --persist

# 2. Download RavenDB (skip if already installed)
bash 10-get-ravendb.sh

# 3. Launch RavenDB with profiling knobs (in a separate terminal)
bash 20-run-ravendb-profiled.sh --fp      # or --dwarf for richer frames

# 4. In another terminal: load some data and drive CPU
bash 30-load.sh --duration 60

# 5. Collect (while load is running)
sudo bash raven-perf-collect.sh \
  --pid "$(pgrep -f Raven.Server | head -1)" \
  --duration 20 \
  --output /tmp/raven-perf-out

# 6. Render (on this box or transfer to another)
bash raven-perf-render.sh /tmp/raven-perf-out/raven-perf-*.tgz --open
```

---

## Production usage: `curl | bash` one-liner

```bash
# Systemd service → send over nc to renderer
curl -fsSL https://gist.github.com/gregolsky/raven_perf/raw | \
  sudo bash -s -- --service ravendb --duration 20 --nc renderer-host:9000

# Docker container → send to S3
curl -fsSL https://gist.github.com/gregolsky/raven_perf/raw | \
  sudo -E S3_BUCKET=s3://debug-greg/perf-artifacts \
  bash -s -- --docker ravendb --duration 20

# Explicit PID → save locally
curl -fsSL https://gist.github.com/gregolsky/raven_perf/raw | \
  sudo bash -s -- --pid 12345 --output /var/tmp/perf-out --nc renderer-host:9000
```

`raven-perf-collect.sh` *is* the gist body — publish it to GitHub Gist as-is.

### Renderer side (nc transport)

```bash
# 1. Listen for the bundle
nc -l 9000 > bundle.tgz

# 2. Render → SVG (local)
bash raven-perf-render.sh bundle.tgz

# 3. Or render → S3
bash raven-perf-render.sh bundle.tgz --s3-bucket s3://debug-greg/perf-artifacts

# 4. Or use the Docker renderer (no local perf/perl needed):
docker build -f Dockerfile.renderer -t gregolsky/raven-perf-renderer .
nc -l 9000 > bundle.tgz
docker run --rm -v "$(pwd)":/data -e S3_BUCKET=s3://debug-greg/perf-artifacts \
  gregolsky/raven-perf-renderer bundle.tgz --s3-bucket "$S3_BUCKET"
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
wrong PID. The collector preflight should have caught this, but if you bypassed it,
check `ls -l /tmp/perf-<pid>.map /tmp/jit-<pid>.dump`.

---

## Gotchas

### Clock mismatch → no managed symbols after inject
`perf record -k CLOCK_MONOTONIC` must match the clock the jitdump uses. If `perf inject`
runs fine but managed frames still show as hex addresses, the timestamps didn't align.
Try without `-k` (some .NET builds use arch/TSC). perf 6.8 (on this box) handles
`JITDUMP_USE_ARCH_TIMESTAMP` auto-detection, so this is rarely a problem here.

### `perf_event_paranoid` / `kptr_restrict` revert on reboot
Use `00-prereqs.sh --persist` to write `/etc/sysctl.d/99-perf.conf`.

### Container PID namespace
In `--docker` mode the perfmap/jitdump filenames use the **container-internal PID**
(`NSpid` from `/proc/<hostpid>/status`) and live in the container's `/tmp` (readable
from the host at `/proc/<hostpid>/root/tmp/`). The collector handles this automatically:
- perfmap is renamed to the host PID (so `perf script` finds it by the recorded PID)
- jitdump keeps the namespaced PID (so `perf inject` finds it by the MMAP path in `perf.data`)

Getting this wrong = unresolved managed frames even though everything "ran fine."

### Knobs need a restart
`systemctl edit` / `docker run -e` take effect only after a restart. A restart
re-JITs everything under a fresh PID → re-resolve target PID each capture.

### `DOTNET_ReadyToRun=0` and startup time
This makes the runtime JIT-compile all framework code instead of using precompiled R2R
images. Startup is a few seconds slower, but all library symbols appear in the flamegraph.
Omit it in production if startup latency matters — managed app code still symbolizes.

### Same technique for source builds
Export the same `DOTNET_*` vars before launching your dev `Raven.Server` binary.
Nothing here is release-specific — it's all .NET runtime knobs and standard Linux perf.

---

## File layout

```
perf/
├── 00-prereqs.sh                  # Check/fix kernel settings + clone FlameGraph
├── 10-get-ravendb.sh              # Download RavenDB release (POC only)
├── 20-run-ravendb-profiled.sh     # Launch with profiling knobs (POC only)
├── 30-load.sh                     # Northwind sample data + query/write load loop
├── raven-perf-collect.sh          # Thin on-box collector (publish as gist)
├── raven-perf-render.sh           # Off-box renderer
├── Dockerfile.renderer            # Self-contained Docker renderer image
├── FlameGraph/                    # Cloned by 00-prereqs.sh
│   ├── flamegraph.pl
│   └── stackcollapse-perf.pl
└── README.md                      # This file
```
