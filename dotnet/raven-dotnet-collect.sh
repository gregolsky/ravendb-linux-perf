#!/usr/bin/env bash
# raven-dotnet-collect.sh — EventPipe (dotnet-trace) collector for RavenDB.
#
# Captures MANAGED (.NET GC heap) allocations via the runtime's EventPipe — a
# different engine from perf/eBPF. Managed allocations come from the GC's
# bump-pointer heap, not libc malloc, so eBPF uprobes can't attribute them by
# type; EventPipe can. No DOTNET_* symbol knobs and no root are required — the
# runtime exposes a diagnostics IPC socket (/tmp/dotnet-diagnostic-<pid>-*.socket).
#
# Output is a .nettrace bundle; render it off-box with dotnet/raven-dotnet-render.sh,
# which converts the allocation stacks into a byte-weighted flamegraph.
#
# ─── One-liner usage ─────────────────────────────────────────────────────────
#
#   sudo -u ravendb bash raven-dotnet-collect.sh --service ravendb --duration 30 --output /tmp/out
#
# ─── Flags ───────────────────────────────────────────────────────────────────
#   Target (pick one):
#     --service <unit>   systemd service (default: ravendb)
#     --pid <n>          explicit PID
#     --docker <name>    docker container (runs dotnet-trace via `docker exec`)
#   Options:
#     --duration <s>     capture length (default: 30)
#     --sampled          use GCSampledObjectAllocation (finer per-object, higher cost)
#                        instead of the default GCAllocationTick (~every 100 KB)
#     --nc <host:port>   stream bundle to renderer via netcat
#     --output <dir>     save bundle locally
#     S3_BUCKET env      upload bundle to S3
#
set -euo pipefail
umask 077

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ─── Defaults ─────────────────────────────────────────────────────────────────
MODE_TARGET=""
TARGET_ARG=""
DURATION=30
SAMPLED=0
NC_DEST=""
OUTPUT_DIR=""
TRACE_TYPE="managed-alloc"

# GC keyword (0x1) at Verbose (5) → GCAllocationTick_V4 with type + stacks.
# --sampled swaps in the GCSampledObjectAllocation keyword (0x200000).
GC_PROVIDER="Microsoft-Windows-DotNETRuntime:0x1:5"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --service)  MODE_TARGET=service; TARGET_ARG="${2:-ravendb}"; shift ;;
      --pid)      MODE_TARGET=pid;     TARGET_ARG="${2:?--pid needs a number}"; shift ;;
      --docker)   MODE_TARGET=docker;  TARGET_ARG="${2:?--docker needs a container}"; shift ;;
      --duration) DURATION="${2:?}"; shift ;;
      --sampled)  SAMPLED=1 ;;
      --nc)       NC_DEST="${2:?--nc needs host:port}"; shift ;;
      --output)   OUTPUT_DIR="${2:?}"; shift ;;
      *) die "Unknown flag: $1" ;;
    esac
    shift
  done
  if [[ -z "$MODE_TARGET" ]]; then
    die "Specify a target: --service <unit> | --pid <n> | --docker <name>"
  fi
  if [[ "$SAMPLED" -eq 1 ]]; then
    GC_PROVIDER="Microsoft-Windows-DotNETRuntime:0x200000:5"
  fi
}

# ─── dotnet-trace resolver ────────────────────────────────────────────────────
# Prefer an installed dotnet-trace; otherwise download the self-contained
# single-file build (no SDK needed).
DOTNET_TRACE=""
resolve_dotnet_trace() {
  if command -v dotnet-trace &>/dev/null; then
    DOTNET_TRACE="dotnet-trace"; ok "dotnet-trace: $(command -v dotnet-trace)"; return
  fi
  if [[ -x "$HOME/.dotnet/tools/dotnet-trace" ]]; then
    DOTNET_TRACE="$HOME/.dotnet/tools/dotnet-trace"; ok "dotnet-trace: $DOTNET_TRACE"; return
  fi
  local CACHE="${TMPDIR:-/tmp}/dotnet-trace"
  if [[ -x "$CACHE" ]]; then
    DOTNET_TRACE="$CACHE"; ok "dotnet-trace (cached): $CACHE"; return
  fi
  info "dotnet-trace not found — downloading single-file build from aka.ms ..."
  if curl -fsSL "https://aka.ms/dotnet-trace/linux-x64" -o "$CACHE"; then
    chmod +x "$CACHE"; DOTNET_TRACE="$CACHE"; ok "dotnet-trace downloaded → $CACHE"
  else
    die "Could not obtain dotnet-trace. Install it (dotnet tool install -g dotnet-trace) or pre-place it at $CACHE."
  fi
}

WORK=""
ARTIFACTS=""
HOST_PID=""
NETTRACE=""
setup_workdir() {
  WORK=$(mktemp -d /tmp/raven-dotnet-XXXXXXXX)
  trap 'rm -rf "$WORK"' EXIT
  ARTIFACTS="$WORK/artifacts"
  mkdir -p "$ARTIFACTS"
  NETTRACE="$ARTIFACTS/managed-alloc.nettrace"
  BUNDLE_NAME="raven-dotnet-${TRACE_TYPE}-$(hostname -s)-$(date +%Y%m%dT%H%M%SZ)"
  BUNDLE_FILE="$WORK/${BUNDLE_NAME}.tgz"
}

resolve_pid() {
  case "$MODE_TARGET" in
    service)
      HOST_PID=$(systemctl show -p MainPID --value "$TARGET_ARG" 2>/dev/null || true)
      [[ -z "$HOST_PID" || "$HOST_PID" == "0" ]] && HOST_PID=$(pgrep -f Raven.Server | head -1 || true)
      [[ -z "$HOST_PID" ]] && die "Service '$TARGET_ARG' not running."
      ;;
    pid)
      HOST_PID="$TARGET_ARG"
      [[ -d "/proc/$HOST_PID" ]] || die "PID $HOST_PID not found."
      ;;
    docker) ;;  # handled in do_capture (runs inside the container)
  esac
}

do_capture() {
  if [[ "$MODE_TARGET" == "docker" ]]; then
    # The diagnostics socket lives in the container's /tmp, so dotnet-trace must
    # run inside the container's namespaces. Requires dotnet-trace present there.
    info "Capturing managed allocations inside container '$TARGET_ARG' for ${DURATION}s ..."
    local NSPID
    NSPID=$(docker exec "$TARGET_ARG" sh -c 'pgrep -f Raven.Server | head -1' 2>/dev/null || echo 1)
    docker exec "$TARGET_ARG" dotnet-trace collect \
      --process-id "$NSPID" \
      --providers "$GC_PROVIDER" \
      --duration "00:00:$(printf '%02d' "$DURATION")" \
      --output /tmp/managed-alloc.nettrace \
      || die "dotnet-trace failed inside the container (is it installed there? try a sidecar sharing the PID namespace)."
    docker cp "$TARGET_ARG:/tmp/managed-alloc.nettrace" "$NETTRACE"
  else
    info "Capturing managed allocations for ${DURATION}s (PID $HOST_PID, provider $GC_PROVIDER) ..."
    "$DOTNET_TRACE" collect \
      --process-id "$HOST_PID" \
      --providers "$GC_PROVIDER" \
      --duration "00:00:$(printf '%02d' "$DURATION")" \
      --output "$NETTRACE" \
      || die "dotnet-trace failed. Ensure you run as the same user as RavenDB (e.g. sudo -u ravendb) or as root, and that diagnostics are enabled (DOTNET_EnableDiagnostics not 0)."
  fi
  [[ -s "$NETTRACE" ]] || die "No .nettrace produced."
  ok "managed-alloc.nettrace: $(du -sh "$NETTRACE" | cut -f1)"
}

do_bundle() {
  {
    echo "hostname=$(hostname)"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "engine=dotnet"
    echo "capture_type=$TRACE_TYPE"
    echo "host_pid=${HOST_PID:-container}"
    echo "duration=${DURATION}s"
    echo "provider=$GC_PROVIDER"
    echo "sampled=$SAMPLED"
  } > "$ARTIFACTS/meta.txt"
  tar czf "$BUNDLE_FILE" -C "$WORK" artifacts
  ok "Bundle: $BUNDLE_FILE ($(du -sh "$BUNDLE_FILE" | cut -f1))"
}

do_ship() {
  if [[ -n "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"; cp "$BUNDLE_FILE" "$OUTPUT_DIR/"
    ok "Saved: $OUTPUT_DIR/${BUNDLE_NAME}.tgz"
  fi
  if [[ -n "$NC_DEST" ]]; then
    local H="${NC_DEST%%:*}" P="${NC_DEST##*:}"
    info "Streaming to ${H}:${P} ..."
    if nc --help 2>&1 | grep -q '\-N'; then cat "$BUNDLE_FILE" | nc -N "$H" "$P"; else cat "$BUNDLE_FILE" | nc "$H" "$P"; fi
    ok "Streamed ${BUNDLE_NAME}.tgz → ${H}:${P}"
    echo "On the renderer:  nc -l $P > ${BUNDLE_NAME}.tgz && bash dotnet/raven-dotnet-render.sh ${BUNDLE_NAME}.tgz"
  elif [[ -n "${S3_BUCKET:-}" ]]; then
    command -v aws &>/dev/null || die "aws CLI not found."
    aws s3 cp "$BUNDLE_FILE" "${S3_BUCKET}/${BUNDLE_NAME}.tgz"
    ok "Uploaded: ${S3_BUCKET}/${BUNDLE_NAME}.tgz"
  elif [[ -z "$OUTPUT_DIR" ]]; then
    warn "No transport configured — bundle is in a temp dir (will be deleted). Use --nc / --output / S3_BUCKET."
  fi
}

main() {
  parse_args "$@"
  setup_workdir
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  RavenDB dotnet (EventPipe) collector  [managed-alloc]"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  [[ "$MODE_TARGET" != "docker" ]] && resolve_dotnet_trace
  resolve_pid
  do_capture
  do_bundle
  do_ship
  echo ""
  echo "  Render with:  bash dotnet/raven-dotnet-render.sh ${BUNDLE_NAME}.tgz"
}

# `:-$0` default so `curl … | bash -s -- …` (BASH_SOURCE unset) still runs main
# under `set -u`, while sourcing in tests does not.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
