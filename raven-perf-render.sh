#!/usr/bin/env bash
# raven-perf-render.sh — Off-box renderer for RavenDB perf flamegraph bundles.
#
# Receives a bundle produced by raven-perf-collect.sh, does all the heavy work
# (perf inject --jit, DWARF unwinding, stackcollapse, SVG render), then publishes
# the flamegraph SVG to S3 or stdout.
#
# Run this on your workstation, a Docker container, or an EC2 instance — NOT on
# the RavenDB server (the render work is deliberately off-box).
#
# ─── Usage ──────────────────────────────────────────────────────────────────
#
#   # Accept bundle from nc:
#   nc -l 9000 > bundle.tgz
#   bash raven-perf-render.sh bundle.tgz
#
#   # Download from S3 and render:
#   aws s3 cp s3://debug-greg/perf-artifacts/raven-perf-host-*.tgz .
#   bash raven-perf-render.sh raven-perf-host-*.tgz --s3-bucket s3://debug-greg/perf-artifacts
#
#   # In Docker (self-contained renderer):
#   docker run --rm -v "$(pwd)":/data gregolsky/raven-perf-renderer bundle.tgz
#
# ─── Flags ──────────────────────────────────────────────────────────────────
#   <bundle.tgz>              Path to the bundle file (required)
#   --s3-bucket <s3://...>    Publish SVG to this S3 bucket (also uses S3_BUCKET env var)
#   --output-dir <dir>        Save SVG + folded stacks locally (default: current dir)
#   --title <string>          Flamegraph title (default: "RavenDB perf – <hostname> <date>")
#   --no-inject               Skip perf inject even for jitdump bundles (use perfmap only)
#   --open                    Open the SVG in the default browser after rendering (local only)
#
set -euo pipefail

# ─── Colour helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ─── Defaults ───────────────────────────────────────────────────────────────
BUNDLE_FILE=""
S3_BUCKET="${S3_BUCKET:-}"
OUTPUT_DIR="$(pwd)"
FG_TITLE=""
NO_INJECT=0
OPEN_SVG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --s3-bucket)  S3_BUCKET="${2:?}"; shift ;;
    --output-dir) OUTPUT_DIR="${2:?}"; shift ;;
    --title)      FG_TITLE="${2:?}"; shift ;;
    --no-inject)  NO_INJECT=1 ;;
    --open)       OPEN_SVG=1 ;;
    -*)           die "Unknown flag: $1" ;;
    *)            BUNDLE_FILE="$1" ;;
  esac
  shift
done

[[ -z "$BUNDLE_FILE" ]] && die "Usage: $0 <bundle.tgz> [flags]"
[[ -f "$BUNDLE_FILE" ]] || die "Bundle not found: $BUNDLE_FILE"

# ─── Check tools ─────────────────────────────────────────────────────────────
need() { command -v "$1" &>/dev/null || die "Required tool not found: $1. Install it first."; }
need perf
need perl

# FlameGraph scripts
FG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/FlameGraph"
if [[ ! -f "$FG_DIR/flamegraph.pl" ]]; then
  # Also try /opt/FlameGraph or /usr/local/FlameGraph (Docker image path)
  for TRY in /opt/FlameGraph /usr/local/FlameGraph; do
    [[ -f "$TRY/flamegraph.pl" ]] && FG_DIR="$TRY" && break
  done
fi
if [[ ! -f "$FG_DIR/flamegraph.pl" ]]; then
  info "Cloning brendangregg/FlameGraph ..."
  git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FG_DIR"
fi
ok "FlameGraph: $FG_DIR"

# ─── Extract bundle ─────────────────────────────────────────────────────────
WORK=$(mktemp -d /tmp/raven-render-XXXXXXXX)
trap 'rm -rf "$WORK"' EXIT
info "Extracting bundle ..."
tar xzf "$BUNDLE_FILE" -C "$WORK"

PERF_DATA="$WORK/perf.data"
ARTIFACTS="$WORK/artifacts"
[[ -f "$PERF_DATA" ]]  || die "Bundle missing perf.data"
[[ -d "$ARTIFACTS" ]]  || die "Bundle missing artifacts/ directory"

# ─── Read metadata ──────────────────────────────────────────────────────────
META="$ARTIFACTS/meta.txt"
get_meta() { grep "^${1}=" "$META" 2>/dev/null | cut -d= -f2- || echo "unknown"; }

BUNDLE_HOST=$(get_meta hostname)
BUNDLE_DATE=$(get_meta date)
CAPTURE_MODE=$(get_meta capture_mode)
HOST_PID=$(get_meta host_pid)
NS_PID=$(get_meta ns_pid)

[[ -z "$FG_TITLE" ]] && FG_TITLE="RavenDB perf – ${BUNDLE_HOST} ${BUNDLE_DATE}"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  RavenDB perf renderer"
echo "  Bundle: $BUNDLE_FILE"
echo "  Host: $BUNDLE_HOST  Date: $BUNDLE_DATE"
echo "  Capture mode: $CAPTURE_MODE  PID: $HOST_PID (ns: $NS_PID)"
echo "═══════════════════════════════════════════════════════"
echo ""

# ─── Recreate side-channel paths perf expects ───────────────────────────────
KALLSYMS="$ARTIFACTS/kallsyms"
[[ -f "$KALLSYMS" ]] && ok "kallsyms: $(wc -l < "$KALLSYMS") entries" \
                      || warn "kallsyms not in bundle — kernel frames may be unresolved"

# perfmap: perf script matches by host PID recorded in perf.data
PERFMAP_FILE="$ARTIFACTS/perf-${HOST_PID}.map"
JITDUMP_FILE="$ARTIFACTS/jit-${NS_PID}.dump"

if [[ -f "$PERFMAP_FILE" ]]; then
  # Place where perf script looks for it
  cp "$PERFMAP_FILE" "/tmp/perf-${HOST_PID}.map"
  ok "perfmap → /tmp/perf-${HOST_PID}.map ($(wc -l < "$PERFMAP_FILE") entries)"
fi
if [[ -f "$JITDUMP_FILE" ]]; then
  # perf inject --jit matches the MMAP path embedded in perf.data (uses ns_pid)
  cp "$JITDUMP_FILE" "/tmp/jit-${NS_PID}.dump"
  ok "jitdump → /tmp/jit-${NS_PID}.dump"
fi

# ─── perf inject (DWARF / jitdump path) ─────────────────────────────────────
PERF_IN="$PERF_DATA"

if [[ "$CAPTURE_MODE" == "dwarf" && "$NO_INJECT" -eq 0 ]]; then
  if [[ -f "/tmp/jit-${NS_PID}.dump" ]]; then
    info "Running perf inject --jit ..."
    HOME="${HOME:-/root}"    # perf inject writes per-method ELF into ~/.debug/jit/
    mkdir -p "$HOME/.debug"
    PERF_JIT="$WORK/perf.jit.data"
    perf inject --jit --input "$PERF_DATA" --output "$PERF_JIT"
    PERF_IN="$PERF_JIT"
    ok "perf inject done → $(du -sh "$PERF_JIT" | cut -f1)"
  else
    warn "jitdump not in bundle — skipping perf inject (managed frames from perfmap only)"
  fi
fi

# ─── perf script → stackcollapse → flamegraph ───────────────────────────────
BASENAME="${BUNDLE_FILE%.tgz}"; BASENAME="${BASENAME%.tar.gz}"; BASENAME="$(basename "$BASENAME")"
FOLDED_FILE="$WORK/${BASENAME}.folded"
SVG_FILE="$OUTPUT_DIR/${BASENAME}-flame.svg"
mkdir -p "$OUTPUT_DIR"

info "Running perf script ..."
KALLSYMS_ARG=()
[[ -f "$KALLSYMS" ]] && KALLSYMS_ARG=(--kallsyms="$KALLSYMS")

perf script -i "$PERF_IN" "${KALLSYMS_ARG[@]}" \
  | "$FG_DIR/stackcollapse-perf.pl" \
  > "$FOLDED_FILE"
ok "Folded stacks: $FOLDED_FILE ($(wc -l < "$FOLDED_FILE") samples)"

info "Rendering flamegraph ..."
"$FG_DIR/flamegraph.pl" \
  --title "$FG_TITLE" \
  --colors java \
  --hash \
  --width 1600 \
  "$FOLDED_FILE" \
  > "$SVG_FILE"
ok "SVG: $SVG_FILE ($(du -sh "$SVG_FILE" | cut -f1))"

# Save folded stacks alongside SVG
cp "$FOLDED_FILE" "$OUTPUT_DIR/${BASENAME}.folded"

# ─── Sanity check: look for the three expected frame layers ──────────────────
echo ""
echo "── Quick sanity check ────────────────────────────────"
FP_RAVEN=$(grep -c 'Raven\.\|Voron\.' "$FOLDED_FILE" || true)
FP_CORECLR=$(grep -c 'libcoreclr\|coreclr!\|GarbageCollect\|JIT_\|clrjit' "$FOLDED_FILE" || true)
FP_KERNEL=$(grep -c 'entry_SYSCALL\|__x64_sys\|do_syscall\|futex\|schedule' "$FOLDED_FILE" || true)
# Note: '/* MT: 0x... */' in names like 'dynamicClass::IL_STUB_PInvoke' is NORMAL —
# it's the method-table pointer embedded by the runtime in stub names, not unresolved.
FP_UNKNOWN=$(grep -c 'memfd:doublemapper' "$FOLDED_FILE" || true)

echo "  RavenDB managed frames (Raven.* / Voron.*) : $FP_RAVEN"
echo "  .NET runtime frames (coreclr / JIT / GC)   : $FP_CORECLR"
echo "  Kernel frames (entry_SYSCALL / futex / etc) : $FP_KERNEL"
[[ "$FP_UNKNOWN" -gt 0 ]] && \
  warn "Unresolved JIT frames (memfd:doublemapper): $FP_UNKNOWN — DOTNET_EnableWriteXorExecute=0 not set on target"

if [[ "$FP_RAVEN" -eq 0 && "$FP_CORECLR" -eq 0 ]]; then
  warn "No managed frames found! Verify that RavenDB was running with DOTNET_PerfMapEnabled and the side-channel is in the bundle."
fi

# ─── Upload SVG to S3 ────────────────────────────────────────────────────────
if [[ -n "$S3_BUCKET" ]]; then
  command -v aws &>/dev/null || die "aws CLI not found."
  S3_KEY="${S3_BUCKET%/}/${BASENAME}-flame.svg"
  info "Uploading SVG to $S3_KEY ..."
  aws s3 cp "$SVG_FILE" "$S3_KEY" --content-type "image/svg+xml"
  ok "Published: $S3_KEY"

  # Presigned URL (valid 1 hour) for easy sharing
  PRESIGN=$(aws s3 presign "$S3_KEY" --expires-in 3600 2>/dev/null || true)
  if [[ -n "$PRESIGN" ]]; then
    echo ""
    echo "  Direct browser link (1h):"
    echo "  $PRESIGN"
  fi

  # Also upload the folded stacks (useful for grep/diff)
  aws s3 cp "$OUTPUT_DIR/${BASENAME}.folded" "${S3_BUCKET%/}/${BASENAME}.folded" \
    --content-type "text/plain" &>/dev/null && ok "Folded stacks uploaded"
fi

# ─── Open in browser (local) ─────────────────────────────────────────────────
if [[ "$OPEN_SVG" -eq 1 ]]; then
  if command -v xdg-open &>/dev/null; then xdg-open "$SVG_FILE"
  elif command -v open &>/dev/null; then open "$SVG_FILE"
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Render complete."
echo "  SVG:    $SVG_FILE"
echo "  Folded: $OUTPUT_DIR/${BASENAME}.folded"
echo "═══════════════════════════════════════════════════════"
