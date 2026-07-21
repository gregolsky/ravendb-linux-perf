# Verify `--type alloc` (native memory allocation tracing) on a Linux box

This is the end-to-end check for the new eBPF `--type alloc` capture. **Run it on the
Linux RavenDB box** — it cannot be exercised from WSL/Windows (no perf/eBPF, no RavenDB).

`alloc` traces RavenDB's **unmanaged** memory (not the managed GC heap) by uprobing the
three native symbols its allocations bottom out on:

- `libc:malloc` — Sparrow `NativeMemory` / `ByteString` arenas (`Marshal.AllocHGlobal`)
- `libc:mmap64` — 4 KB-aligned encryption/IO buffers + (transitively) Voron file mappings
- `librvnpal:rvn_allocate_more_space` — Voron data/journal file growth

It produces call-count-weighted **allocation-site flamegraphs** (`stackcount`) plus a
bytes-weighted **outstanding/leak report** (`memleak`).

---

## 0. Prereqs (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y bpfcc-tools bpftrace linux-headers-$(uname -r) perl git
sudo bash common/00-prereqs.sh        # sysctls, BTF check, clones FlameGraph

# Tools the alloc type uses:
which bpftrace                                  # byte-VOLUME flames (bytes allocated)
which memleak-bpfcc    || ls /usr/share/bcc/tools/memleak     # byte-HELD flame (outstanding)
which stackcount-bpfcc || ls /usr/share/bcc/tools/stackcount  # call-count fallback
```

**`bpftrace`** drives the byte-weighted *volume* flames (sum of `malloc`/`mmap` sizes) — the
"which path allocated the most memory" view. **`memleak`** gives the *held*-bytes flame. If
`bpftrace` is absent the collector falls back to `stackcount` call-count flames (clearly labeled
"not size"). None are strictly required, but with neither `bpftrace` nor `memleak` you get no
byte view.

---

## 1. RavenDB must run WITH the profiling knobs

Managed frames only resolve if RavenDB was **started** with these (they cannot be injected
into a live process):

```
DOTNET_PerfMapEnabled=1
DOTNET_EnableWriteXorExecute=0
DOTNET_ReadyToRun=0            # optional: also names System.*/Microsoft.* frames
```

**systemd service:**
```bash
sudo systemctl edit ravendb
# add inside [Service]:
#   Environment="DOTNET_PerfMapEnabled=1"
#   Environment="DOTNET_EnableWriteXorExecute=0"
#   Environment="DOTNET_ReadyToRun=0"
sudo systemctl restart ravendb
```

**Docker:**
```bash
docker run \
  -e DOTNET_PerfMapEnabled=1 \
  -e DOTNET_EnableWriteXorExecute=0 \
  -e DOTNET_ReadyToRun=0 \
  ... (your existing flags) ... \
  ravendb/ravendb
```

**Manual / POC shell:**
```bash
export DOTNET_PerfMapEnabled=1 DOTNET_EnableWriteXorExecute=0 DOTNET_ReadyToRun=0
./RavenDB/Server/Raven.Server
```

Verify the knobs and the side-channel file:
```bash
PID=$(pgrep -f Raven.Server | head -1); echo "PID=$PID"
tr '\0' '\n' < /proc/$PID/environ | grep -E 'DOTNET_(PerfMapEnabled|EnableWriteXorExecute)'
ls -l /tmp/perf-$PID.map        # must exist and be non-empty
```

Have some load running (real traffic, or `bash common/30-load.sh --duration 120` on a POC
box) so there are allocations to trace.

---

## 2. Capture

```bash
sudo bash ebpf/raven-ebpf-collect.sh --pid "$PID" --type alloc --duration 15 --output ./out
```

Keep `--duration` short — the `malloc`/`mmap64` probes fire on every native allocation.
The collector runs its probes sequentially, so expect a few ×duration wall-clock.

(`--service ravendb` or `--docker <name>` work too; Docker resolves the container-internal
PID and `librvnpal` path automatically. Note: in `--docker`, managed frames may show as
`[native]` — see the container caveat in the README.)

---

## 3. Render

```bash
bash ebpf/raven-ebpf-render.sh out/raven-ebpf-alloc-*.tgz --output-dir ./out
```

---

## 4. Checks

```bash
# Artifacts exist. The key memory flames:
#   *-alloc-malloc-bytes-flame.svg / *-alloc-mmap-bytes-flame.svg  → bytes ALLOCATED (volume, bpftrace)
#   *-alloc-outstanding-bytes-flame.svg                            → bytes HELD (memleak)
#   *-alloc-malloc-flame.svg (only if bpftrace was absent)         → call count (fallback)
ls -la out/*alloc*-flame.svg out/*.folded out/memleak.txt

# "Which path allocated the most memory?" → widest tower in the byte-VOLUME flame;
# top line of the folded is the biggest single path:
sort -t' ' -k2 -nr out/*alloc-malloc-bytes.folded 2>/dev/null | head -3

# Managed frames resolved somewhere (expect > 0)
grep -Ehc 'Raven\.|Sparrow\.|Voron\.' out/*alloc*.folded

# W^X knob working: no doublemapper frames (expect 0)
grep -c 'memfd:doublemapper' out/*.folded

# Held native allocations by stack (bytes)
head -40 out/memleak.txt
```

**Acceptance:**
- `raven-ebpf-alloc-*-alloc-malloc-flame.svg` is produced and non-trivial; opening it shows
  `Sparrow.*` / `ByteStringContext` / `Voron.*` towers above the `malloc` leaf (not raw hex,
  no `memfd:doublemapper`). `alloc-mmap` and `alloc-rvn` flames appear when there is mmap /
  Voron-growth activity in the window.
- `memleak.txt` lists stacks with outstanding byte totals.
- **Cross-check:** compare the `memleak.txt` totals against RavenDB's own native figure
  (Studio → server memory, or `Sparrow.Utils.NativeMemory.TotalAllocatedMemory`) for an
  order-of-magnitude match.

**Negative paths (should behave gracefully):**
```bash
# perf engine rejects alloc with an eBPF redirect:
sudo bash perf/raven-perf-collect.sh --pid "$PID" --type alloc --duration 5 --output ./out
# → "--type alloc is eBPF-only. Use the eBPF collector instead: ..."
```
- On a box without `bpfcc-tools`, the collector fails fast in `need_bcc stackcount` with the
  `apt-get install bpfcc-tools` hint.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `alloc-malloc.folded` empty | No allocations in the window (idle server) — add load / raise `--duration`; or `c:malloc` didn't resolve on this libc build. |
| `alloc-mmap.folded` empty | Try `c:mmap` instead of `c:mmap64` in the collector's `alloc)` branch — glibc symbol naming varies. |
| Managed frames show as hex | Knobs missing at process start, or `/tmp/perf-$PID.map` absent — re-check step 1 and restart RavenDB. |
| `memfd:doublemapper` towers | `DOTNET_EnableWriteXorExecute=0` was not set — restart with it. |
| `librvnpal not found ... skipping` warning | `alloc-rvn` is best-effort; the `mmap64` flame still covers Voron mappings transitively. |
| `stackcount`/`memleak` flag error | bcc version differences — the collector wraps probes in `timeout -s INT ... || true`; adjust flags in `ebpf/raven-ebpf-collect.sh` `alloc)` branch if needed. |
