#!/usr/bin/env bash
# raven-perf-collect.sh — Thin on-box collector for RavenDB perf flamegraph captures.
#
# Designed to run on resource-constrained RavenDB servers.  Does ONLY:
#   1. Preflight: kernel settings, process env, side-channel files
#   2. Light perf record (frame-pointer by default)
#   3. Bundle: perf.data + symbol side-channel + kallsyms + meta
#   4. Ship: to a renderer via nc OR to S3
#
# Heavy work (perf inject, DWARF unwind, stackcollapse, SVG render) is done
# off-box by raven-perf-render.sh / the renderer Docker image.
#
# ─── One-liner usage (run as root / sudo -E) ────────────────────────────────
#
#   # systemd service, send to renderer over nc:
#   curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/perf/raven-perf-collect.sh | \
#     sudo bash -s -- --service ravendb --type cpu --duration 20 --nc renderer:9000
#
#   # Docker container, send to S3:
#   curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/perf/raven-perf-collect.sh | \
#     sudo -E S3_BUCKET=s3://debug-greg/perf-artifacts bash -s -- --docker ravendb --type offcpu
#
#   # Explicit PID (POC / dev):
#   sudo bash perf/raven-perf-collect.sh --pid 12345 --type cpu --nc renderer:9000
#
# ─── Flags ──────────────────────────────────────────────────────────────────
#
#   Target (pick one):
#     --service <unit>     systemd service name (default: ravendb)
#     --docker <name>      Docker container name or ID
#     --pid <n>            Explicit host PID
#     --demo               Download + launch RavenDB, load Northwind, then capture
#                          (dev/POC only; needs wget + internet access)
#
#   Trace type (pick one):
#     --type cpu           On-CPU flamegraph (default)
#     --type offcpu        Blocked-time flamegraph (time-weighted, needs schedstats)
#     --type io            Block I/O by code path (use eBPF engine for latency/biosnoop)
#
#   Capture mode (pick one — applies to cpu type):
#     --fp                 Frame-pointer unwinding — small perf.data, DEFAULT
#     --dwarf              DWARF unwinding — larger, richer inlined frames
#                          (requires DOTNET_PerfMapEnabled=1 or 2 on target)
#
#   Transport (pick one — required unless --demo):
#     --nc <host:port>     Stream bundle to renderer via netcat
#     S3_BUCKET env var    Upload bundle to S3 (needs aws CLI + creds)
#
#   Other:
#     --duration <s>       Capture length in seconds (default: 20)
#     --freq <hz>          Sampling frequency (default: 99; use 499 for richer data)
#     --output <dir>       Save bundle locally to <dir> instead of / in addition to transport
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
MODE_TARGET=""      # --service / --docker / --pid / --demo
TARGET_ARG=""
CAPTURE_MODE="fp"   # fp | dwarf
TRACE_TYPE="cpu"    # cpu | offcpu | io
DURATION=20
FREQ=99
NC_DEST=""
OUTPUT_DIR=""
SYSCTL_FIX=0

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)   MODE_TARGET=service; TARGET_ARG="${2:-ravendb}"; shift ;;
    --docker)    MODE_TARGET=docker;  TARGET_ARG="${2:?--docker needs container name}"; shift ;;
    --pid)       MODE_TARGET=pid;     TARGET_ARG="${2:?--pid needs a number}"; shift ;;
    --demo)      MODE_TARGET=demo ;;
    --type)      TRACE_TYPE="${2:?--type needs cpu|offcpu|io}"; shift ;;
    --fp)        CAPTURE_MODE=fp  ;;
    --dwarf)     CAPTURE_MODE=dwarf ;;
    --duration)  DURATION="${2:?}"; shift ;;
    --freq)      FREQ="${2:?}"; shift ;;
    --nc)        NC_DEST="${2:?--nc needs host:port}"; shift ;;
    --output)    OUTPUT_DIR="${2:?}"; shift ;;
    --sysctl-fix) SYSCTL_FIX=1 ;;
    *) die "Unknown flag: $1" ;;
  esac
  shift
done

[[ -z "$MODE_TARGET" ]] && die "Specify a target: --service <unit> | --docker <name> | --pid <n> | --demo"

# Validate trace type; reject eBPF-only types with a helpful redirect
case "$TRACE_TYPE" in
  cpu|offcpu|io) ;;
  runqlat|offwake|alloc)
    die "--type $TRACE_TYPE is eBPF-only. Use the eBPF collector instead:\n  curl -fsSL https://raw.githubusercontent.com/gregolsky/ravendb-linux-perf/main/ebpf/raven-ebpf-collect.sh | sudo bash -s -- --type $TRACE_TYPE ..." ;;
  *) die "Unknown --type '$TRACE_TYPE'. Valid: cpu, offcpu, io  (for runqlat/offwake/alloc use the eBPF collector)" ;;
esac

# ─── Relaunch-hint block (printed when knobs are missing) ───────────────────
print_relaunch_hint() {
  local PID_NS_LABEL="$1"
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
WORK=$(mktemp -d /tmp/raven-perf-XXXXXXXX)
trap 'rm -rf "$WORK"' EXIT
ARTIFACTS="$WORK/artifacts"
mkdir -p "$ARTIFACTS"

# ─── 1. Kernel preflight ────────────────────────────────────────────────────
check_kernel_settings() {
  local PARANOID; PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
  local KPTR;    KPTR=$(cat /proc/sys/kernel/kptr_restrict)

  if [[ "$PARANOID" -gt 1 ]]; then
    if [[ "$SYSCTL_FIX" -eq 1 ]]; then
      sysctl -qw kernel.perf_event_paranoid=-1
      warn "perf_event_paranoid was $PARANOID → set to -1"
    else
      die "kernel.perf_event_paranoid=$PARANOID — profiling blocked. Re-run with --sysctl-fix or: sudo sysctl kernel.perf_event_paranoid=-1"
    fi
  else
    ok "kernel.perf_event_paranoid=$PARANOID"
  fi

  if [[ "$KPTR" -gt 0 ]]; then
    if [[ "$SYSCTL_FIX" -eq 1 ]]; then
      sysctl -qw kernel.kptr_restrict=0
      warn "kptr_restrict was $KPTR → set to 0"
    else
      warn "kernel.kptr_restrict=$KPTR — kernel symbols will be hidden. Re-run with --sysctl-fix to fix."
    fi
  else
    ok "kernel.kptr_restrict=$KPTR"
  fi
}

# ─── 1b. schedstats preflight (needed for off-CPU time-weighted capture) ────
check_schedstats() {
  local SCHED; SCHED=$(cat /proc/sys/kernel/sched_schedstats 2>/dev/null || echo "missing")
  if [[ "$SCHED" != "1" ]]; then
    if [[ "$SYSCTL_FIX" -eq 1 ]]; then
      sysctl -qw kernel.sched_schedstats=1 || \
        die "Cannot enable sched_schedstats — kernel may not have CONFIG_SCHEDSTATS. Off-CPU capture will be count-based, not time-weighted."
      warn "kernel.sched_schedstats was $SCHED → set to 1 (time-weighted off-CPU)"
    else
      die "kernel.sched_schedstats=$SCHED — off-CPU capture needs this for time-weighted stacks.\nRe-run with --sysctl-fix or: sudo sysctl kernel.sched_schedstats=1"
    fi
  else
    ok "kernel.sched_schedstats=1 (time-weighted off-CPU enabled)"
  fi
}

# ─── 2. Resolve PID and side-channel paths ──────────────────────────────────
HOST_PID=""
NS_PID=""       # container-namespaced PID (same as HOST_PID for non-container)
CONTAINER_ROOT=""  # /proc/<pid>/root for docker mode

resolve_pid_service() {
  HOST_PID=$(systemctl show -p MainPID --value "$TARGET_ARG" 2>/dev/null || true)
  if [[ -z "$HOST_PID" || "$HOST_PID" == "0" ]]; then
    HOST_PID=$(pgrep -f Raven.Server | head -1 || true)
  fi
  [[ -z "$HOST_PID" ]] && die "Service '$TARGET_ARG' not running (or Raven.Server not found)."
  NS_PID="$HOST_PID"
  CONTAINER_ROOT=""
}

resolve_pid_docker() {
  HOST_PID=$(docker inspect -f '{{.State.Pid}}' "$TARGET_ARG" 2>/dev/null || true)
  [[ -z "$HOST_PID" || "$HOST_PID" == "0" ]] && \
    die "Container '$TARGET_ARG' not running (docker inspect returned empty PID)."
  # Container-namespaced PID (what .NET uses for /tmp/perf-<nspid>.map filenames)
  NS_PID=$(awk '/^NSpid:/{print $NF}' /proc/"$HOST_PID"/status 2>/dev/null || echo "$HOST_PID")
  CONTAINER_ROOT="/proc/$HOST_PID/root"
  info "Container PID: host=$HOST_PID namespace=$NS_PID root=$CONTAINER_ROOT"
}

resolve_pid_explicit() {
  HOST_PID="$TARGET_ARG"
  [[ ! -d "/proc/$HOST_PID" ]] && die "PID $HOST_PID not found in /proc."
  NS_PID="$HOST_PID"
  CONTAINER_ROOT=""
}

# ─── 3. Process env preflight ───────────────────────────────────────────────
check_process_env() {
  local ENV_FILE="/proc/$HOST_PID/environ"
  [[ ! -r "$ENV_FILE" ]] && die "Cannot read $ENV_FILE — re-run as root (sudo -E)."

  # Parse process env (null-separated)
  declare -A PROC_ENV=()
  while IFS='=' read -r -d '' KEY VAL; do
    PROC_ENV["$KEY"]="$VAL"
  done < "$ENV_FILE"

  local MISSING=0

  # DOTNET_PerfMapEnabled (accept CORECLR_ prefix for .NET 11+)
  local PM_VAL="${PROC_ENV[DOTNET_PerfMapEnabled]:-${PROC_ENV[CORECLR_PerfMapEnabled]:-}}"
  if [[ -z "$PM_VAL" || "$PM_VAL" == "0" ]]; then
    warn "DOTNET_PerfMapEnabled not set (or =0) on PID $HOST_PID"
    MISSING=1
  else
    # Mode-specific check
    if [[ "$CAPTURE_MODE" == "fp" && "$PM_VAL" != "1" && "$PM_VAL" != "3" ]]; then
      warn "DOTNET_PerfMapEnabled=$PM_VAL — FP capture needs value 1 (both) or 3 (perfmap only)"
      MISSING=1
    elif [[ "$CAPTURE_MODE" == "dwarf" && "$PM_VAL" != "1" && "$PM_VAL" != "2" ]]; then
      warn "DOTNET_PerfMapEnabled=$PM_VAL — DWARF capture needs value 1 (both) or 2 (jitdump only)"
      MISSING=1
    else
      ok "DOTNET_PerfMapEnabled=$PM_VAL"
    fi
  fi

  # DOTNET_EnableWriteXorExecute
  local WXE="${PROC_ENV[DOTNET_EnableWriteXorExecute]:-${PROC_ENV[CORECLR_EnableWriteXorExecute]:-}}"
  if [[ "$WXE" != "0" ]]; then
    warn "DOTNET_EnableWriteXorExecute not set to 0 (is: '${WXE:-<unset>}') — managed frames may resolve to memfd:doublemapper noise"
    MISSING=1
  else
    ok "DOTNET_EnableWriteXorExecute=0"
  fi

  # DOTNET_ReadyToRun (soft warning — managed still resolves, just not framework)
  local R2R="${PROC_ENV[DOTNET_ReadyToRun]:-${PROC_ENV[CORECLR_ReadyToRun]:-}}"
  if [[ "$R2R" != "0" ]]; then
    warn "DOTNET_ReadyToRun not set to 0 (is: '${R2R:-<unset>}') — framework/R2R symbols may be missing from flamegraph"
  else
    ok "DOTNET_ReadyToRun=0"
  fi

  [[ "$MISSING" -eq 1 ]] && print_relaunch_hint "$HOST_PID"
}

# ─── 4. Side-channel preflight ──────────────────────────────────────────────
PERFMAP_SRC=""
JITDUMP_SRC=""

check_side_channel() {
  local TMP_ROOT="${CONTAINER_ROOT:-}"
  local PERFMAP="${TMP_ROOT}/tmp/perf-${NS_PID}.map"
  local JITDUMP="${TMP_ROOT}/tmp/jit-${NS_PID}.dump"

  if [[ "$CAPTURE_MODE" == "fp" ]]; then
    if [[ ! -s "$PERFMAP" ]]; then
      warn "Side-channel file not found or empty: $PERFMAP"
      print_relaunch_hint "$HOST_PID"
    fi
    ok "perfmap: $PERFMAP ($(wc -l < "$PERFMAP") entries)"
    PERFMAP_SRC="$PERFMAP"
  else
    if [[ ! -s "$JITDUMP" ]]; then
      warn "Side-channel file not found or empty: $JITDUMP"
      print_relaunch_hint "$HOST_PID"
    fi
    ok "jitdump: $JITDUMP ($(stat -c%s "$JITDUMP") bytes)"
    JITDUMP_SRC="$JITDUMP"
    # Also grab perfmap if available (for extra fallback symbol coverage)
    [[ -s "$PERFMAP" ]] && PERFMAP_SRC="$PERFMAP"
  fi
}

# ─── 5. Capture ─────────────────────────────────────────────────────────────
PERF_DATA="$WORK/perf.data"

do_capture() {
  case "$TRACE_TYPE" in
    cpu)
      info "Recording on-CPU for ${DURATION}s at ${FREQ}Hz targeting PID $HOST_PID ..."
      if [[ "$CAPTURE_MODE" == "fp" ]]; then
        perf record -F "$FREQ" -g -p "$HOST_PID" -o "$PERF_DATA" -- sleep "$DURATION"
      else
        # DWARF: -k CLOCK_MONOTONIC is MANDATORY — must match jitdump timestamps
        perf record -k CLOCK_MONOTONIC --call-graph "dwarf,65528" \
          -F "$FREQ" -p "$HOST_PID" -o "$PERF_DATA" -- sleep "$DURATION"
      fi
      ;;
    offcpu)
      info "Recording off-CPU (sched switch) for ${DURATION}s targeting PID $HOST_PID ..."
      # -e sched:sched_stat_sleep carries the sleep time in ns as sample period;
      # perf inject -s will use that to produce time-weighted stacks.
      # System-wide (-a) needed; filter to target with --pid where possible.
      perf record \
        -e sched:sched_switch \
        -e sched:sched_stat_sleep \
        -e sched:sched_stat_blocked \
        -a -g \
        --pid "$HOST_PID" \
        -o "$PERF_DATA" \
        -- sleep "$DURATION"
      ;;
    io)
      info "Recording block I/O events for ${DURATION}s (system-wide) ..."
      # Tip: for latency histograms and per-I/O traces use the eBPF collector.
      perf record \
        -e block:block_rq_issue \
        -e block:block_rq_complete \
        -a -g \
        -o "$PERF_DATA" \
        -- sleep "$DURATION"
      ;;
  esac
  ok "perf.data: $(du -sh "$PERF_DATA" | cut -f1)"
}

# ─── 6. Bundle ──────────────────────────────────────────────────────────────
BUNDLE_NAME="raven-perf-${TRACE_TYPE}-$(hostname -s)-$(date +%Y%m%dT%H%M%SZ)"
BUNDLE_FILE="$WORK/${BUNDLE_NAME}.tgz"

do_bundle() {
  info "Gathering side-channel and metadata ..."

  # Copy side-channel files into artifacts/ with names perf expects on the renderer
  # FP: rename to host PID so 'perf script' finds it (perf matches by the PID it recorded)
  if [[ -n "$PERFMAP_SRC" ]]; then
    cp "$PERFMAP_SRC" "$ARTIFACTS/perf-${HOST_PID}.map"
    ok "perfmap → artifacts/perf-${HOST_PID}.map"
  fi
  # DWARF jitdump: keep the namespaced PID (perf inject matches the MMAP path in perf.data)
  if [[ -n "$JITDUMP_SRC" ]]; then
    cp "$JITDUMP_SRC" "$ARTIFACTS/jit-${NS_PID}.dump"
    ok "jitdump → artifacts/jit-${NS_PID}.dump"
  fi

  # /proc/kallsyms — kernel symbols must be captured on this box/kernel
  cp /proc/kallsyms "$ARTIFACTS/kallsyms"
  ok "kallsyms: $(wc -l < "$ARTIFACTS/kallsyms") entries"

  # meta.txt
  {
    echo "hostname=$(hostname)"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel=$(uname -r)"
    echo "engine=perf"
    echo "capture_type=$TRACE_TYPE"
    echo "capture_mode=$CAPTURE_MODE"
    echo "host_pid=$HOST_PID"
    echo "ns_pid=$NS_PID"
    echo "duration=${DURATION}s"
    echo "freq=${FREQ}Hz"
    echo "perf_version=$(perf --version 2>&1 | head -1)"
    echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"
    echo "kptr_restrict=$(cat /proc/sys/kernel/kptr_restrict)"
    echo "raven_cmdline=$(tr '\0' ' ' < /proc/"$HOST_PID"/cmdline 2>/dev/null || true)"
    # .NET / RavenDB version from the process env or binary
    local RAVEN_VER
    RAVEN_VER=$(tr '\0' '\n' < /proc/"$HOST_PID"/environ 2>/dev/null | grep -i RAVEN_VERSION || true)
    echo "raven_version=${RAVEN_VER:-unknown}"
  } > "$ARTIFACTS/meta.txt"
  ok "meta.txt written"

  # perf.data goes at bundle root (large; keep outside artifacts/ for easy stripping)
  cp "$PERF_DATA" "$WORK/perf.data"

  info "Creating bundle ..."
  tar czf "$BUNDLE_FILE" -C "$WORK" perf.data -C "$WORK" artifacts
  local SIZE; SIZE=$(du -sh "$BUNDLE_FILE" | cut -f1)
  ok "Bundle: $BUNDLE_FILE ($SIZE)"

  # Free the large perf.data from the constrained box ASAP
  rm -f "$PERF_DATA"
  info "Removed perf.data from box to reclaim disk."
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
    # nc -N closes after EOF (OpenBSD netcat); fall back without -N for other variants
    if nc --help 2>&1 | grep -q '\-N'; then
      cat "$BUNDLE_FILE" | nc -N "$HOST" "$PORT"
    else
      cat "$BUNDLE_FILE" | nc "$HOST" "$PORT"
    fi
    ok "Streamed ${BUNDLE_NAME}.tgz → ${HOST}:${PORT}"
    echo ""
    echo "On the renderer run:"
    echo "  nc -l $PORT > ${BUNDLE_NAME}.tgz"
    echo "  bash raven-perf-render.sh ${BUNDLE_NAME}.tgz"

  elif [[ -n "${S3_BUCKET:-}" ]]; then
    command -v aws &>/dev/null || die "aws CLI not found. Install it or use --nc instead."
    info "Uploading bundle to ${S3_BUCKET} ..."
    aws s3 cp "$BUNDLE_FILE" "${S3_BUCKET}/${BUNDLE_NAME}.tgz"
    ok "Uploaded: ${S3_BUCKET}/${BUNDLE_NAME}.tgz"
    echo ""
    echo "On the renderer run:"
    echo "  aws s3 cp '${S3_BUCKET}/${BUNDLE_NAME}.tgz' ."
    echo "  bash raven-perf-render.sh ${BUNDLE_NAME}.tgz [--s3-bucket ${S3_BUCKET}]"

  elif [[ -z "$OUTPUT_DIR" ]]; then
    warn "No transport configured — bundle saved only in temp dir (will be deleted)."
    warn "Use --nc host:port or set S3_BUCKET=, or use --output <dir>."
  fi
}

# ─── Demo mode: download + launch RavenDB, load data, then capture ──────────
run_demo() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ ! -f "$SCRIPT_DIR/../RavenDB/Server/Raven.Server" ]]; then
    info "Downloading RavenDB for demo ..."
    bash "$SCRIPT_DIR/../common/10-get-ravendb.sh"
  fi

  # Launch RavenDB in background with profiling knobs
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
  # Expose for the rest of the script
  HOST_PID=$DEMO_RAVEN_PID
  NS_PID=$DEMO_RAVEN_PID
  CONTAINER_ROOT=""

  # Wait for side-channel to appear (JIT warms up)
  info "Waiting for side-channel (/tmp/perf-${HOST_PID}.map) to appear ..."
  for i in $(seq 1 30); do
    [[ -s "/tmp/perf-${HOST_PID}.map" || -s "/tmp/jit-${HOST_PID}.dump" ]] && break
    sleep 2
  done

  # Load demo data and run load loop in background
  bash "$SCRIPT_DIR/../common/30-load.sh" --duration "$(( DURATION + 10 ))" &
  LOAD_PID=$!

  sleep 5   # Let the load ramp before recording

  do_capture
  wait "$LOAD_PID" 2>/dev/null || true

  info "Stopping demo RavenDB ..."
  kill "$DEMO_RAVEN_PID" 2>/dev/null || true
  wait "$DEMO_RAVEN_PID" 2>/dev/null || true
}

# ─── Main ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  RavenDB perf collector  [target: $MODE_TARGET | type: $TRACE_TYPE | capture: $CAPTURE_MODE]"
echo "═══════════════════════════════════════════════════════"
echo ""

check_kernel_settings
[[ "$TRACE_TYPE" == "offcpu" ]] && check_schedstats

if [[ "$MODE_TARGET" == "demo" ]]; then
  # Demo skips preflight (we set the knobs ourselves)
  run_demo
  PERFMAP_SRC="/tmp/perf-${HOST_PID}.map"
  JITDUMP_SRC="/tmp/jit-${HOST_PID}.dump"
  [[ ! -s "$PERFMAP_SRC" ]] && PERFMAP_SRC=""
  [[ ! -s "$JITDUMP_SRC" ]] && JITDUMP_SRC=""
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
echo "  Render it with:  bash raven-perf-render.sh <bundle.tgz>"
echo "═══════════════════════════════════════════════════════"
