# Verify `managed-alloc` (managed .NET GC-heap allocation flamegraph)

Run on the Linux RavenDB box (collector) + a box with the **.NET SDK** (renderer — can be the
same box or your workstation). Unlike `alloc`/`faults`, this uses the runtime's **EventPipe**
(`dotnet-trace`) — **no root, no `perf_event_paranoid`, and no `DOTNET_*` symbol knobs needed**.

The converter (`dotnet/nettrace-to-folded`) has been validated end-to-end against a real trace;
the parts below that need your box are the live capture + the SDK-based render.

---

## 1. Collect (on the RavenDB box)

Attach as the **same user as RavenDB** (the diagnostics socket is owned by that user), or root.

```bash
# systemd service (RavenDB usually runs as user 'ravendb'):
sudo -u ravendb bash dotnet/raven-dotnet-collect.sh --service ravendb --duration 30 --output /tmp/out
# or an explicit PID:
sudo -u ravendb bash dotnet/raven-dotnet-collect.sh --pid "$(pgrep -f Raven.Server | head -1)" --duration 30 --output /tmp/out
# finer per-object sampling (heavier):
#   … --sampled
```

`dotnet-trace` is auto-downloaded (self-contained, from `https://aka.ms/dotnet-trace/linux-x64`)
if not already installed — no SDK required on the RavenDB box.

**Docker:** the diagnostics socket lives inside the container, so pass `--docker <name>`; the
collector runs `dotnet-trace` via `docker exec` (the tool must be present in the container, or run
a sidecar sharing its PID namespace).

Bundle lands at `/tmp/out/raven-dotnet-managed-alloc-<host>-<ts>.tgz` (contains
`managed-alloc.nettrace` + `meta.txt`).

## 2. Render (on a box with the .NET SDK)

```bash
# scp the bundle over first if rendering elsewhere
bash dotnet/raven-dotnet-render.sh /tmp/out/raven-dotnet-managed-alloc-*.tgz --output-dir /tmp/out
```

The renderer builds the `nettrace-to-folded` converter on first use (needs `dotnet` SDK), converts
the `.nettrace` to byte-weighted folded stacks, and renders with `flamegraph.pl`.

## 3. Checks

```bash
ls -la /tmp/out/*managed-alloc-flame.svg /tmp/out/*managed-alloc-bytype.txt /tmp/out/*managed-alloc.folded
echo "== top managed types by bytes =="; head -15 /tmp/out/*managed-alloc-bytype.txt
```

**Acceptance:**
- `*-managed-alloc-flame.svg` opens with the **allocated type as the flame leaf** (e.g.
  `System.String`, `System.Byte[]`, `Raven.*`/`Sparrow.*` types) and managed call paths above it —
  **no `[unknown]` walls** (managed stacks are clean, unlike the native `alloc` type).
- `*-managed-alloc-bytype.txt` lists bytes by type.
- **Cross-check:** compare the top types against RavenDB's built-in
  `GET /admin/debug/memory/allocations?delay=5` (Operator auth) — same `GCAllocationTick` source, so
  the top types should broadly agree.

**Troubleshooting:**
| Symptom | Fix |
|---|---|
| `dotnet-trace` can't attach / "not running" | Run as the RavenDB user (`sudo -u ravendb`) or root; confirm the process is .NET and diagnostics aren't disabled (`DOTNET_EnableDiagnostics` not `0`). |
| Windows/Git-Bash PID mismatch when testing | Use `dotnet-trace ps` to get the real PID. |
| `no GCAllocationTick events` warning | The app was idle, or the window was too short — capture under load / raise `--duration`. |
| Renderer: "needs the .NET SDK" | Install the SDK on the render box, or render on a box that has it. |
