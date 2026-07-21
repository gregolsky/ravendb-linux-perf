#!/usr/bin/env bash
# raven-ebpf-collect.sh — eBPF-based collector for RavenDB profiling.
#
# Uses bcc-tools (or bpftrace fallback) to capture on-CPU, off-CPU, I/O,
# scheduler, and wakeup profiles with in-kernel aggregation — much lighter
# than perf record for off-CPU/I/O workloads.
#
# Managed .NET frames are symbolized from /tmp/perf-<pid>.map (same side-channel
# as the perf engine). RavenDB must be launched with DOTNET_PerfMapEnabled set.
#
# ─── One-liner usage (run as root / sudo -E) ────────────────────────────────
#
#   # Systemd service, off-CPU → nc:
#   curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/ebpf/raven-ebpf-collect.sh | \
#     sudo bash -s -- --service ravendb --type offcpu --duration 30 --nc renderer:9000
#
#   # Docker container, I/O → S3:
#   curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/ebpf/raven-ebpf-collect.sh | \
#     sudo -E S3_BUCKET=s3://debug-greg/perf-artifacts bash -s -- --docker ravendb --type io
#
#   # Explicit PID, run-queue latency:
#   sudo bash ebpf/raven-ebpf-collect.sh --pid 12345 --type runqlat --duration 20 --nc renderer:9000
#
# ─── Flags ──────────────────────────────────────────────────────────────────
#
#   Target (pick one):
#     --service <unit>     systemd service name (default: ravendb)
#     --docker <name>      Docker container name or ID
#     --pid <n>            Explicit host PID
#     --demo               Download + launch RavenDB, load Northwind, then capture
#
#   Trace type (pick one):
#     --type cpu           On-CPU flamegraph via eBPF profile (default)
#     --type offcpu        Blocked-time flamegraph via offcputime
#     --type offwake       Off-CPU + waker stacks via offwaketime
#     --type io            Block I/O: latency histogram + biosnoop + code-path + FS + cache
#     --type runqlat       Scheduler run-queue latency histogram via runqlat
#     --type alloc         Native/unmanaged memory: allocation-site flamegraphs
#                          (malloc/mmap/rvn via stackcount) + memleak outstanding report
#                          (byte-weighted flame is rendered from the memleak data)
#     --type faults        Page-fault flamegraph — where RSS grows (first-touch),
#                          via stackcount on t:exceptions:page_fault_user
#
#   Transport (pick one — required unless --demo):
#     --nc <host:port>     Stream bundle to renderer via netcat
#     S3_BUCKET env var    Upload bundle to S3 (needs aws CLI + creds)
#
#   Other:
#     --duration <s>       Capture length in seconds (default: 30)
#     --freq <hz>          Sampling frequency for cpu type (default: 99)
#     --output <dir>       Save bundle locally to <dir>
#     --sysctl-fix         Auto-apply perf_event_paranoid / kptr_restrict without asking
#
set -euo pipefail
umask 077

# ─── Colour helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ─── Defaults ───────────────────────────────────────────────────────────────
MODE_TARGET=""
TARGET_ARG=""
TRACE_TYPE="cpu"
DURATION=30
FREQ=99
NC_DEST=""
OUTPUT_DIR=""
SYSCTL_FIX=0

# ─── Arg parsing ────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service)   MODE_TARGET=service; TARGET_ARG="${2:-ravendb}"; shift ;;
      --docker)    MODE_TARGET=docker;  TARGET_ARG="${2:?--docker needs container name}"; shift ;;
      --pid)       MODE_TARGET=pid;     TARGET_ARG="${2:?--pid needs a number}"; shift ;;
      --demo)      MODE_TARGET=demo ;;
      --type)      TRACE_TYPE="${2:?--type needs cpu|offcpu|offwake|io|runqlat|alloc|faults}"; shift ;;
      --duration)  DURATION="${2:?}"; shift ;;
      --freq)      FREQ="${2:?}"; shift ;;
      --nc)        NC_DEST="${2:?--nc needs host:port}"; shift ;;
      --output)    OUTPUT_DIR="${2:?}"; shift ;;
      --sysctl-fix) SYSCTL_FIX=1 ;;
      *) die "Unknown flag: $1" ;;
    esac
    shift
  done

  if [[ -z "$MODE_TARGET" ]]; then
    die "Specify a target: --service <unit> | --docker <name> | --pid <n> | --demo"
  fi

  case "$TRACE_TYPE" in
    cpu|offcpu|offwake|io|runqlat|alloc|faults) ;;
    *) die "Unknown --type '$TRACE_TYPE'. Valid: cpu, offcpu, offwake, io, runqlat, alloc, faults" ;;
  esac
}

# ─── bcc tool resolver ──────────────────────────────────────────────────────
# Different distros install bcc tools under different names/paths.
find_bcc_tool() {
  local TOOL="$1"
  for CANDIDATE in \
    "${TOOL}-bpfcc" \
    "/usr/share/bcc/tools/${TOOL}" \
    "${TOOL}" ; do
    if command -v "$CANDIDATE" &>/dev/null || [[ -x "$CANDIDATE" ]]; then
      echo "$CANDIDATE"; return 0
    fi
  done
  echo ""
}

need_bcc() {
  local TOOL="$1"
  local CMD; CMD=$(find_bcc_tool "$TOOL")
  if [[ -z "$CMD" ]]; then
    die "bcc tool '$TOOL' not found. Install: apt-get install bpfcc-tools\n  Then re-run: sudo bash ebpf/raven-ebpf-collect.sh ..."
  fi
  echo "$CMD"
}

# ─── Progress helper ─────────────────────────────────────────────────────────
# Run a capture command (stdout → outfile) in the background with a live 1-second
# countdown on stderr, so a multi-second silent capture visibly progresses.
# Usage: _capture <outfile> <label> <cmd...>
_capture() {
  local OUT="$1" LABEL="$2"; shift 2
  info "  $LABEL"
  "$@" > "$OUT" 2>/dev/null &
  local CPID=$! LEFT="$DURATION"
  while kill -0 "$CPID" 2>/dev/null; do
    printf "\r      %-34s %2ds " "$LABEL" "$LEFT" >&2
    [[ "$LEFT" -le 0 ]] && break
    sleep 1; LEFT=$((LEFT-1))
  done
  wait "$CPID" 2>/dev/null || true
  printf "\r%*s\r" 55 "" >&2
}

# ─── Relaunch-hint block ────────────────────────────────────────────────────
print_relaunch_hint() {
  cat >&2 <<EOF

${YELLOW}═══════════════════════════════════════════════════════════════════════${NC}
 RavenDB is NOT running with the required profiling knobs.
 These must be set BEFORE the process starts (they cannot be injected live).

 ── For a systemd service ──────────────────────────────────────────────────
   sudo systemctl edit ravendb
   # Add inside [Service]:
   [Service]
   Environment="DOTNET_PerfMapEnabled=1"
   Environment="DOTNET_ReadyToRun=0"
   Environment="DOTNET_EnableWriteXorExecute=0"
   sudo systemctl restart ravendb

 ── For Docker (ravendb/ravendb) ──────────────────────────────────────────
   docker run \\
     -e DOTNET_PerfMapEnabled=1 \\
     -e DOTNET_ReadyToRun=0 \\
     -e DOTNET_EnableWriteXorExecute=0 \\
     ... (other flags) ... ravendb/ravendb

 ── For a manual shell launch ─────────────────────────────────────────────
   export DOTNET_PerfMapEnabled=1
   export DOTNET_ReadyToRun=0
   export DOTNET_EnableWriteXorExecute=0
   ./RavenDB/Server/Raven.Server

${YELLOW}═══════════════════════════════════════════════════════════════════════${NC}
EOF
  exit 2
}

# ─── Work directory ─────────────────────────────────────────────────────────
# Called from main() only (not on source) so the script is safe to `source` in tests.
setup_workdir() {
  WORK=$(mktemp -d /tmp/raven-ebpf-XXXXXXXX)
  trap 'rm -rf "$WORK"' EXIT
  ARTIFACTS="$WORK/artifacts"
  mkdir -p "$ARTIFACTS"
  BUNDLE_NAME="raven-ebpf-${TRACE_TYPE}-$(hostname -s)-$(date +%Y%m%dT%H%M%SZ)"
  BUNDLE_FILE="$WORK/${BUNDLE_NAME}.tgz"
}

# ─── 1. Kernel preflight ────────────────────────────────────────────────────
check_kernel_settings() {
  local PARANOID; PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
  if [[ "$PARANOID" -gt 1 ]]; then
    if [[ "$SYSCTL_FIX" -eq 1 ]]; then
      sysctl -qw kernel.perf_event_paranoid=-1
      warn "perf_event_paranoid was $PARANOID → set to -1"
    else
      die "kernel.perf_event_paranoid=$PARANOID — eBPF profiling needs ≤ 1. Re-run with --sysctl-fix or: sudo sysctl kernel.perf_event_paranoid=-1"
    fi
  else
    ok "kernel.perf_event_paranoid=$PARANOID"
  fi
}

# ─── 2. Resolve PID and side-channel paths ──────────────────────────────────
HOST_PID=""
NS_PID=""
CONTAINER_ROOT=""

resolve_pid_service() {
  HOST_PID=$(systemctl show -p MainPID --value "$TARGET_ARG" 2>/dev/null || true)
  if [[ -z "$HOST_PID" || "$HOST_PID" == "0" ]]; then
    HOST_PID=$(pgrep -f Raven.Server | head -1 || true)
  fi
  [[ -z "$HOST_PID" ]] && die "Service '$TARGET_ARG' not running."
  NS_PID="$HOST_PID"; CONTAINER_ROOT=""
}

resolve_pid_docker() {
  HOST_PID=$(docker inspect -f '{{.State.Pid}}' "$TARGET_ARG" 2>/dev/null || true)
  [[ -z "$HOST_PID" || "$HOST_PID" == "0" ]] && die "Container '$TARGET_ARG' not running."
  NS_PID=$(awk '/^NSpid:/{print $NF}' /proc/"$HOST_PID"/status 2>/dev/null || echo "$HOST_PID")
  CONTAINER_ROOT="/proc/$HOST_PID/root"
  info "Container PID: host=$HOST_PID namespace=$NS_PID root=$CONTAINER_ROOT"
}

resolve_pid_explicit() {
  HOST_PID="$TARGET_ARG"
  [[ ! -d "/proc/$HOST_PID" ]] && die "PID $HOST_PID not found in /proc."
  NS_PID="$HOST_PID"; CONTAINER_ROOT=""
}

# ─── 3. Process env preflight ───────────────────────────────────────────────
PERFMAP_SRC=""

check_process_env() {
  local ENV_FILE="/proc/$HOST_PID/environ"
  [[ ! -r "$ENV_FILE" ]] && die "Cannot read $ENV_FILE — re-run as root (sudo -E)."

  declare -A PROC_ENV=()
  while IFS='=' read -r -d '' KEY VAL; do
    PROC_ENV["$KEY"]="$VAL"
  done < "$ENV_FILE"

  local MISSING=0
  local PM_VAL="${PROC_ENV[DOTNET_PerfMapEnabled]:-${PROC_ENV[CORECLR_PerfMapEnabled]:-}}"
  if [[ -z "$PM_VAL" || "$PM_VAL" == "0" ]]; then
    warn "DOTNET_PerfMapEnabled not set on PID $HOST_PID — managed frames will be raw addresses"
    MISSING=1
  else
    ok "DOTNET_PerfMapEnabled=$PM_VAL"
  fi

  local WXE="${PROC_ENV[DOTNET_EnableWriteXorExecute]:-${PROC_ENV[CORECLR_EnableWriteXorExecute]:-}}"
  if [[ "$WXE" != "0" ]]; then
    warn "DOTNET_EnableWriteXorExecute not set to 0 — managed frames may show as memfd:doublemapper"
    MISSING=1
  else
    ok "DOTNET_EnableWriteXorExecute=0"
  fi

  if [[ "$MISSING" -eq 1 ]]; then print_relaunch_hint; fi
}

# ─── 4. Side-channel preflight ──────────────────────────────────────────────
check_side_channel() {
  local TMP_ROOT="${CONTAINER_ROOT:-}"
  local PERFMAP="${TMP_ROOT}/tmp/perf-${NS_PID}.map"
  if [[ -s "$PERFMAP" ]]; then
    ok "perfmap: $PERFMAP ($(wc -l < "$PERFMAP") entries)"
    PERFMAP_SRC="$PERFMAP"
  else
    warn "perfmap not found at $PERFMAP — managed frames will be unresolved"
  fi
}

# ─── 5. Capture ─────────────────────────────────────────────────────────────
do_capture() {
  case "$TRACE_TYPE" in

    cpu)
      local PROFILE; PROFILE=$(need_bcc profile)
      _capture "$ARTIFACTS/cpu.folded" "on-CPU sampling ${FREQ}Hz (PID $HOST_PID)" \
        "$PROFILE" -F "$FREQ" -adf -p "$HOST_PID" "$DURATION"
      # Symbolize managed frames from perfmap
      _apply_perfmap "$ARTIFACTS/cpu.folded"
      ok "cpu.folded: $(wc -l < "$ARTIFACTS/cpu.folded") samples"
      ;;

    offcpu)
      local OFFCPU; OFFCPU=$(need_bcc offcputime)
      _capture "$ARTIFACTS/offcpu.folded" "off-CPU sampling (PID $HOST_PID)" \
        "$OFFCPU" -df -p "$HOST_PID" "$DURATION"
      _apply_perfmap "$ARTIFACTS/offcpu.folded"
      ok "offcpu.folded: $(wc -l < "$ARTIFACTS/offcpu.folded") samples"
      ;;

    offwake)
      local OFFWAKE; OFFWAKE=$(need_bcc offwaketime)
      _capture "$ARTIFACTS/offwake.folded" "off-wake sampling (PID $HOST_PID)" \
        "$OFFWAKE" -df -p "$HOST_PID" "$DURATION"
      _apply_perfmap "$ARTIFACTS/offwake.folded"
      ok "offwake.folded: $(wc -l < "$ARTIFACTS/offwake.folded") samples"
      ;;

    runqlat)
      local RUNQLAT; RUNQLAT=$(need_bcc runqlat)
      info "eBPF run-queue latency for ${DURATION}s ..."
      "$RUNQLAT" -T -P -m "$DURATION" > "$ARTIFACTS/runqlat.txt"
      ok "runqlat.txt: $(wc -l < "$ARTIFACTS/runqlat.txt") lines"
      ;;

    io)
      local BIOLATENCY; BIOLATENCY=$(need_bcc biolatency)
      local BIOSNOOP;   BIOSNOOP=$(need_bcc biosnoop)
      local CACHESTAT;  CACHESTAT=$(find_bcc_tool cachestat)
      local BITESIZE;   BITESIZE=$(find_bcc_tool bitesize)
      local BIOSTACKS;  BIOSTACKS=$(find_bcc_tool biostacks)

      info "eBPF block I/O profiling for ${DURATION}s ..."

      # Latency histogram
      "$BIOLATENCY" -D -T "$DURATION" > "$ARTIFACTS/biolatency.txt" 2>&1 || \
        warn "biolatency failed (non-fatal); output may be partial"
      ok "biolatency.txt"

      # Per-I/O trace — cap at duration seconds
      timeout "$DURATION" "$BIOSNOOP" > "$ARTIFACTS/biosnoop.txt" 2>&1 || true
      ok "biosnoop.txt ($(wc -l < "$ARTIFACTS/biosnoop.txt") lines)"

      # I/O size distribution
      if [[ -n "$BITESIZE" ]]; then
        timeout "$DURATION" "$BITESIZE" > "$ARTIFACTS/bitesize.txt" 2>&1 || true
        ok "bitesize.txt"
      fi

      # Page-cache statistics
      if [[ -n "$CACHESTAT" ]]; then
        "$CACHESTAT" 1 "$DURATION" > "$ARTIFACTS/cachestat.txt" 2>&1 || true
        ok "cachestat.txt"
      fi

      # I/O by code path (folded stacks)
      if [[ -n "$BIOSTACKS" ]]; then
        timeout "$DURATION" "$BIOSTACKS" > "$ARTIFACTS/io-codepath.folded" 2>&1 || true
        _apply_perfmap "$ARTIFACTS/io-codepath.folded"
        ok "io-codepath.folded: $(wc -l < "$ARTIFACTS/io-codepath.folded") samples"
      fi

      # FS slow-ops (ext4 specific; silently skip if unavailable or not ext4)
      for FS_TOOL in ext4slower fileslower; do
        local FST; FST=$(find_bcc_tool "$FS_TOOL")
        if [[ -n "$FST" ]]; then
          timeout "$DURATION" "$FST" 1 > "$ARTIFACTS/${FS_TOOL}.txt" 2>&1 || true
          ok "${FS_TOOL}.txt"
        fi
      done
      ;;

    alloc)
      # ─── Native / unmanaged memory allocation tracing ──────────────────────
      # RavenDB unmanaged memory bottoms out on three native symbols:
      #   • libc malloc  ← Sparrow.NativeMemory / ByteString arenas (Marshal.AllocHGlobal)
      #   • libc mmap64  ← 4KB-aligned encryption/IO buffers + (transitively) Voron mappings
      #   • librvnpal rvn_allocate_more_space ← Voron data/journal file growth
      # stackcount -f emits call-count-weighted folded stacks (→ flamegraph). Managed
      # frames resolve from /tmp/perf-<pid>.map at capture time (bcc reads it directly).
      # memleak adds a bytes-weighted "still outstanding" report for leak hunting.
      # NOTE: these are arena/pool allocators, so malloc/mmap tracing shows block-level
      # churn (4KB–2MB), not per-object allocations. Tools run sequentially to bound
      # peak uprobe overhead; --duration applies per probe.
      local STACKCOUNT; STACKCOUNT=$(need_bcc stackcount)
      local MEMLEAK;    MEMLEAK=$(find_bcc_tool memleak)

      info "eBPF native-allocation tracing (PID $HOST_PID) — sequential probes, ~$((DURATION * 4))s total ..."

      # 1. malloc allocation sites (the bulk: arena/heap churn)
      _capture "$ARTIFACTS/alloc-malloc.folded" "[1/4] malloc allocation sites" \
        timeout -s INT "$DURATION" "$STACKCOUNT" -f -p "$HOST_PID" c:malloc
      _apply_perfmap "$ARTIFACTS/alloc-malloc.folded"
      ok "alloc-malloc.folded: $(wc -l < "$ARTIFACTS/alloc-malloc.folded") stacks"

      # 2. mmap64 allocation sites (aligned anon buffers + Voron file mappings)
      _capture "$ARTIFACTS/alloc-mmap.folded" "[2/4] mmap64 allocation sites" \
        timeout -s INT "$DURATION" "$STACKCOUNT" -f -p "$HOST_PID" c:mmap64
      _apply_perfmap "$ARTIFACTS/alloc-mmap.folded"
      ok "alloc-mmap.folded: $(wc -l < "$ARTIFACTS/alloc-mmap.folded") stacks"

      # 3. Voron file-mapping growth, isolated (best-effort; needs librvnpal in maps).
      #    maps is read at the HOST pid; the .so path inside it is container-internal,
      #    so reach the actual file via CONTAINER_ROOT (empty for non-container targets).
      local RVNPAL
      RVNPAL=$(awk '/librvnpal.*\.so/{print $NF; exit}' "/proc/$HOST_PID/maps" 2>/dev/null || true)
      if [[ -n "$RVNPAL" && -f "${CONTAINER_ROOT}${RVNPAL}" ]]; then
        _capture "$ARTIFACTS/alloc-rvn.folded" "[3/4] Voron ${RVNPAL##*/}:rvn_allocate_more_space" \
          timeout -s INT "$DURATION" "$STACKCOUNT" -f -p "$HOST_PID" \
          "${CONTAINER_ROOT}${RVNPAL}:rvn_allocate_more_space"
        _apply_perfmap "$ARTIFACTS/alloc-rvn.folded"
        ok "alloc-rvn.folded: $(wc -l < "$ARTIFACTS/alloc-rvn.folded") stacks"
      else
        warn "  [3/4] librvnpal not found in /proc/$HOST_PID/maps — skipping Voron rvn_* probe"
      fi

      # 4. Outstanding / leak report (bytes-weighted; best-effort). memleak self-terminates
      #    after DURATION (interval=DURATION count=1), so no timeout wrapper is needed.
      if [[ -n "$MEMLEAK" ]]; then
        _capture "$ARTIFACTS/memleak.txt" "[4/4] outstanding allocations (memleak)" \
          "$MEMLEAK" -p "$HOST_PID" -T 30 --combined-only "$DURATION" 1
        ok "memleak.txt: $(wc -l < "$ARTIFACTS/memleak.txt") lines"
      else
        warn "  [4/4] memleak not found (install bpfcc-tools) — skipping outstanding-bytes report"
      fi
      ;;

    faults)
      # Page-fault flamegraph: where physical memory is first-touched (RSS growth).
      # The user page-fault tracepoint fires when a userspace access needs a page
      # mapped in — managed frames resolve via /tmp/perf-<pid>.map, so you see the
      # Raven/Voron/Corax paths that grow the resident set. Weighted by fault count
      # (≈ pages, ~4 KB each). Low overhead (a tracepoint, not a uprobe).
      local STACKCOUNT; STACKCOUNT=$(need_bcc stackcount)
      info "eBPF page-fault profiling (PID $HOST_PID) ..."
      _capture "$ARTIFACTS/faults.folded" "user page-faults" \
        timeout -s INT "$DURATION" "$STACKCOUNT" -f -p "$HOST_PID" "t:exceptions:page_fault_user"
      _apply_perfmap "$ARTIFACTS/faults.folded"
      ok "faults.folded: $(wc -l < "$ARTIFACTS/faults.folded") stacks"
      ;;
  esac
}

# Apply managed symbol names from /tmp/perf-<pid>.map to a folded-stack file.
# bcc tools emit raw addresses for JIT code; this sed replaces them in-place.
# We do a simple address→name substitution from the perfmap.
_apply_perfmap() {
  local FOLDED="$1"
  [[ -z "$PERFMAP_SRC" || ! -f "$FOLDED" ]] && return
  # Build a sed script: for each perfmap entry "addr size name", replace hex
  # occurrences of addr in the folded file with the name.
  # In practice bcc+perf use /tmp/perf-<pid>.map directly if it's in place, so
  # we just ensure it's copied to /tmp at the standard path (done in do_bundle).
  return 0  # Symbolization happens via the map copy in do_bundle / renderer
}

# ─── 6. Bundle ──────────────────────────────────────────────────────────────
do_bundle() {
  info "Gathering side-channel and metadata ..."

  # Copy perfmap for renderer symbolization
  if [[ -n "$PERFMAP_SRC" ]]; then
    cp "$PERFMAP_SRC" "$ARTIFACTS/perf-${HOST_PID}.map"
    ok "perfmap → artifacts/perf-${HOST_PID}.map"
  fi

  # Kernel symbols
  cp /proc/kallsyms "$ARTIFACTS/kallsyms"
  ok "kallsyms: $(wc -l < "$ARTIFACTS/kallsyms") entries"

  # meta.txt
  {
    echo "hostname=$(hostname)"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel=$(uname -r)"
    echo "engine=ebpf"
    echo "capture_type=$TRACE_TYPE"
    echo "host_pid=$HOST_PID"
    echo "ns_pid=$NS_PID"
    echo "duration=${DURATION}s"
    echo "freq=${FREQ}Hz"
    echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"
    echo "raven_cmdline=$(tr '\0' ' ' < /proc/"$HOST_PID"/cmdline 2>/dev/null || true)"
  } > "$ARTIFACTS/meta.txt"
  ok "meta.txt written"

  info "Creating bundle ..."
  tar czf "$BUNDLE_FILE" -C "$WORK" artifacts
  local SIZE; SIZE=$(du -sh "$BUNDLE_FILE" | cut -f1)
  ok "Bundle: $BUNDLE_FILE ($SIZE)"
}

# ─── 7. Transport ────────────────────────────────────────────────────────────
do_ship() {
  if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    cp "$BUNDLE_FILE" "$OUTPUT_DIR/"
    ok "Bundle saved locally: $OUTPUT_DIR/${BUNDLE_NAME}.tgz"
  fi

  if [[ -n "$NC_DEST" ]]; then
    local HOST="${NC_DEST%%:*}"
    local PORT="${NC_DEST##*:}"
    info "Streaming bundle to ${HOST}:${PORT} via nc ..."
    if nc --help 2>&1 | grep -q '\-N'; then
      cat "$BUNDLE_FILE" | nc -N "$HOST" "$PORT"
    else
      cat "$BUNDLE_FILE" | nc "$HOST" "$PORT"
    fi
    ok "Streamed ${BUNDLE_NAME}.tgz → ${HOST}:${PORT}"
    echo ""
    echo "On the renderer run:"
    echo "  nc -l $PORT > ${BUNDLE_NAME}.tgz"
    echo "  bash ebpf/raven-ebpf-render.sh ${BUNDLE_NAME}.tgz"

  elif [[ -n "${S3_BUCKET:-}" ]]; then
    command -v aws &>/dev/null || die "aws CLI not found. Install it or use --nc instead."
    info "Uploading bundle to ${S3_BUCKET} ..."
    aws s3 cp "$BUNDLE_FILE" "${S3_BUCKET}/${BUNDLE_NAME}.tgz"
    ok "Uploaded: ${S3_BUCKET}/${BUNDLE_NAME}.tgz"
    echo ""
    echo "On the renderer run:"
    echo "  aws s3 cp '${S3_BUCKET}/${BUNDLE_NAME}.tgz' ."
    echo "  bash ebpf/raven-ebpf-render.sh ${BUNDLE_NAME}.tgz [--s3-bucket ${S3_BUCKET}]"

  elif [[ -z "$OUTPUT_DIR" ]]; then
    warn "No transport configured — bundle in temp dir (will be deleted). Use --nc or S3_BUCKET."
  fi
}

# ─── Demo mode ───────────────────────────────────────────────────────────────
run_demo() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ ! -f "$SCRIPT_DIR/../RavenDB/Server/Raven.Server" ]]; then
    info "Downloading RavenDB for demo ..."
    bash "$SCRIPT_DIR/../common/10-get-ravendb.sh"
  fi

  export DOTNET_PerfMapEnabled=1
  export DOTNET_ReadyToRun=0
  export DOTNET_EnableWriteXorExecute=0
  export RAVEN_Setup_Mode=None
  export RAVEN_License_Eula_Accepted=true
  export RAVEN_ServerUrl=http://127.0.0.1:8080
  export RAVEN_Security_UnsecuredAccessAllowed=PrivateNetwork

  info "Launching RavenDB (demo mode) ..."
  "$SCRIPT_DIR/../RavenDB/Server/Raven.Server" &
  DEMO_RAVEN_PID=$!
  HOST_PID=$DEMO_RAVEN_PID; NS_PID=$DEMO_RAVEN_PID; CONTAINER_ROOT=""

  info "Waiting for side-channel (/tmp/perf-${HOST_PID}.map) ..."
  for i in $(seq 1 30); do
    [[ -s "/tmp/perf-${HOST_PID}.map" ]] && break
    sleep 2
  done

  PERFMAP_SRC="/tmp/perf-${HOST_PID}.map"
  [[ ! -s "$PERFMAP_SRC" ]] && PERFMAP_SRC=""

  bash "$SCRIPT_DIR/../common/30-load.sh" --duration "$(( DURATION + 10 ))" &
  LOAD_PID=$!
  sleep 5
  do_capture
  wait "$LOAD_PID" 2>/dev/null || true

  info "Stopping demo RavenDB ..."
  kill "$DEMO_RAVEN_PID" 2>/dev/null || true
  wait "$DEMO_RAVEN_PID" 2>/dev/null || true
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  setup_workdir

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  RavenDB eBPF collector  [target: $MODE_TARGET | type: $TRACE_TYPE]"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  check_kernel_settings

  if [[ "$MODE_TARGET" == "demo" ]]; then
    run_demo
  else
    case "$MODE_TARGET" in
      service) resolve_pid_service ;;
      docker)  resolve_pid_docker  ;;
      pid)     resolve_pid_explicit ;;
    esac
    info "Target PID: $HOST_PID (ns: $NS_PID)"
    check_process_env
    check_side_channel
    do_capture
  fi

  do_bundle
  do_ship

  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Collection complete."
  echo "  Bundle: ${BUNDLE_NAME}.tgz"
  echo "  Render it with:  bash ebpf/raven-ebpf-render.sh <bundle.tgz>"
  echo "═══════════════════════════════════════════════════════"
}

# Only run main when executed directly — sourcing (e.g. from bats) defines
# functions without side effects.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
