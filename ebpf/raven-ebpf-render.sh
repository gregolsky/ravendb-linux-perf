#!/usr/bin/env bash
# raven-ebpf-render.sh — Off-box renderer for RavenDB eBPF profiling bundles.
#
# Receives a bundle produced by raven-ebpf-collect.sh, runs flamegraph.pl on
# folded-stack outputs, passes text artifacts through, and publishes to S3 or
# saves locally.
#
# ─── Usage ──────────────────────────────────────────────────────────────────
#
#   # Accept bundle from nc:
#   nc -l 9000 > bundle.tgz
#   bash ebpf/raven-ebpf-render.sh bundle.tgz
#
#   # Download from S3 and render:
#   aws s3 cp s3://debug-greg/perf-artifacts/raven-ebpf-offcpu-*.tgz .
#   bash ebpf/raven-ebpf-render.sh raven-ebpf-offcpu-*.tgz --s3-bucket s3://debug-greg/perf-artifacts
#
#   # In Docker (uses shared perf/Dockerfile.renderer image):
#   docker run --rm -v "$(pwd)":/data gregolsky/raven-perf-renderer \
#     --renderer ebpf bundle.tgz
#
# ─── Flags ──────────────────────────────────────────────────────────────────
#   <bundle.tgz>              Path to the bundle file (required)
#   --s3-bucket <s3://...>    Publish SVG(s) to this S3 bucket
#   --output-dir <dir>        Save output locally (default: current dir)
#   --title <string>          Flamegraph title prefix
#   --open                    Open SVG in browser after rendering
#
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

BUNDLE_FILE=""
S3_BUCKET="${S3_BUCKET:-}"
OUTPUT_DIR="$(pwd)"
FG_TITLE=""
OPEN_SVG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --s3-bucket)  S3_BUCKET="${2:?}"; shift ;;
    --output-dir) OUTPUT_DIR="${2:?}"; shift ;;
    --title)      FG_TITLE="${2:?}"; shift ;;
    --open)       OPEN_SVG=1 ;;
    -*)           die "Unknown flag: $1" ;;
    *)            BUNDLE_FILE="$1" ;;
  esac
  shift
done

[[ -z "$BUNDLE_FILE" ]] && die "Usage: $0 <bundle.tgz> [flags]"
[[ -f "$BUNDLE_FILE" ]] || die "Bundle not found: $BUNDLE_FILE"

need() { command -v "$1" &>/dev/null || die "Required tool not found: $1"; }
need perl

# Find FlameGraph (repo-root, Docker path, or clone)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FG_DIR="$SCRIPT_DIR/../FlameGraph"
if [[ ! -f "$FG_DIR/flamegraph.pl" ]]; then
  for TRY in /opt/FlameGraph /usr/local/FlameGraph; do
    [[ -f "$TRY/flamegraph.pl" ]] && FG_DIR="$TRY" && break
  done
fi
if [[ ! -f "$FG_DIR/flamegraph.pl" ]]; then
  info "Cloning brendangregg/FlameGraph ..."
  git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FG_DIR"
fi
ok "FlameGraph: $FG_DIR"

# Extract bundle
WORK=$(mktemp -d /tmp/raven-ebpf-render-XXXXXXXX)
trap 'rm -rf "$WORK"' EXIT
info "Extracting bundle ..."
tar xzf "$BUNDLE_FILE" -C "$WORK"
ARTIFACTS="$WORK/artifacts"
[[ -d "$ARTIFACTS" ]] || die "Bundle missing artifacts/ directory"

# Read metadata
META="$ARTIFACTS/meta.txt"
get_meta() { grep "^${1}=" "$META" 2>/dev/null | cut -d= -f2- || echo "unknown"; }
BUNDLE_HOST=$(get_meta hostname)
BUNDLE_DATE=$(get_meta date)
CAPTURE_TYPE=$(get_meta capture_type)
HOST_PID=$(get_meta host_pid)

[[ -z "$FG_TITLE" ]] && FG_TITLE="RavenDB ${CAPTURE_TYPE} – ${BUNDLE_HOST} ${BUNDLE_DATE}"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  RavenDB eBPF renderer"
echo "  Bundle: $BUNDLE_FILE"
echo "  Host: $BUNDLE_HOST  Date: $BUNDLE_DATE"
echo "  Type: $CAPTURE_TYPE  PID: $HOST_PID"
echo "═══════════════════════════════════════════════════════"
echo ""

# Restore perfmap for renderer-side symbolization
PERFMAP="$ARTIFACTS/perf-${HOST_PID}.map"
if [[ -f "$PERFMAP" ]]; then
  cp "$PERFMAP" "/tmp/perf-${HOST_PID}.map"
  ok "perfmap → /tmp/perf-${HOST_PID}.map ($(wc -l < "$PERFMAP") entries)"
fi

BASENAME="${BUNDLE_FILE%.tgz}"; BASENAME="${BASENAME%.tar.gz}"; BASENAME="$(basename "$BASENAME")"
mkdir -p "$OUTPUT_DIR"

_render_flame() {
  local FOLDED="$1" SUFFIX="$2" COLORS="${3:-java}" COUNTNAME="${4:-samples}"
  local SVG="$OUTPUT_DIR/${BASENAME}-${SUFFIX}-flame.svg"
  "$FG_DIR/flamegraph.pl" \
    --title "$FG_TITLE" \
    --colors "$COLORS" \
    --countname "$COUNTNAME" \
    --hash --width 1600 \
    "$FOLDED" > "$SVG"
  ok "SVG: $SVG ($(du -sh "$SVG" | cut -f1))"
  cp "$FOLDED" "$OUTPUT_DIR/${BASENAME}-${SUFFIX}.folded"
  echo "$SVG"
}

_copy_text() {
  local SRC="$1"
  [[ ! -f "$SRC" ]] && return
  local DEST="$OUTPUT_DIR/$(basename "$SRC")"
  cp "$SRC" "$DEST"
  ok "Text: $DEST ($(wc -l < "$DEST") lines)"
}

SVGS=()

case "$CAPTURE_TYPE" in
  cpu)
    [[ -f "$ARTIFACTS/cpu.folded" ]] || die "Bundle missing cpu.folded"
    SVGS+=( "$(_render_flame "$ARTIFACTS/cpu.folded" cpu java samples)" )
    ;;

  offcpu)
    [[ -f "$ARTIFACTS/offcpu.folded" ]] || die "Bundle missing offcpu.folded"
    SVGS+=( "$(_render_flame "$ARTIFACTS/offcpu.folded" offcpu io us)" )
    ;;

  offwake)
    [[ -f "$ARTIFACTS/offwake.folded" ]] || die "Bundle missing offwake.folded"
    SVGS+=( "$(_render_flame "$ARTIFACTS/offwake.folded" offwake io us)" )
    ;;

  runqlat)
    _copy_text "$ARTIFACTS/runqlat.txt"
    echo ""
    echo "── Run-queue latency histogram ─────────────────────"
    cat "$ARTIFACTS/runqlat.txt"
    ;;

  io)
    [[ -f "$ARTIFACTS/io-codepath.folded" ]] && \
      SVGS+=( "$(_render_flame "$ARTIFACTS/io-codepath.folded" io-codepath io samples)" )
    _copy_text "$ARTIFACTS/biolatency.txt"
    _copy_text "$ARTIFACTS/biosnoop.txt"
    _copy_text "$ARTIFACTS/bitesize.txt"
    _copy_text "$ARTIFACTS/cachestat.txt"
    _copy_text "$ARTIFACTS/ext4slower.txt"
    _copy_text "$ARTIFACTS/fileslower.txt"
    echo ""
    echo "── Block I/O latency ───────────────────────────────"
    [[ -f "$ARTIFACTS/biolatency.txt" ]] && head -40 "$ARTIFACTS/biolatency.txt"
    echo ""
    echo "── Page cache ──────────────────────────────────────"
    [[ -f "$ARTIFACTS/cachestat.txt" ]] && head -10 "$ARTIFACTS/cachestat.txt" || true
    ;;

  *)
    die "Unknown capture_type '$CAPTURE_TYPE' in bundle meta.txt" ;;
esac

# Upload to S3
if [[ -n "$S3_BUCKET" ]]; then
  command -v aws &>/dev/null || die "aws CLI not found."
  for SVG in "${SVGS[@]:-}"; do
    [[ -f "$SVG" ]] || continue
    S3_KEY="${S3_BUCKET%/}/$(basename "$SVG")"
    info "Uploading $SVG → $S3_KEY ..."
    aws s3 cp "$SVG" "$S3_KEY" --content-type "image/svg+xml"
    PRESIGN=$(aws s3 presign "$S3_KEY" --expires-in 3600 2>/dev/null || true)
    [[ -n "$PRESIGN" ]] && echo "  Link (1h): $PRESIGN"
  done
fi

# Open in browser
if [[ "$OPEN_SVG" -eq 1 && "${#SVGS[@]}" -gt 0 ]]; then
  FIRST_SVG="${SVGS[0]}"
  if command -v xdg-open &>/dev/null; then xdg-open "$FIRST_SVG"
  elif command -v open &>/dev/null;    then open "$FIRST_SVG"
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Render complete."
echo "  Output dir: $OUTPUT_DIR"
echo "═══════════════════════════════════════════════════════"
