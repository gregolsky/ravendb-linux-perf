#!/usr/bin/env bash
# raven-dotnet-render.sh — off-box renderer for dotnet (EventPipe) bundles.
#
# Converts a managed-allocation .nettrace into a byte-weighted flamegraph:
#   .nettrace → nettrace-to-folded (TraceEvent) → folded → flamegraph.pl → SVG
# plus a by-type allocation summary.
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#   nc -l 9000 > bundle.tgz
#   bash dotnet/raven-dotnet-render.sh bundle.tgz [--output-dir <dir>] [--title <s>] [--open] [--s3-bucket <s3://…>]
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
need dotnet

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# FlameGraph (repo-root, well-known paths, or clone)
FG_DIR="$SCRIPT_DIR/../FlameGraph"
if [[ ! -f "$FG_DIR/flamegraph.pl" ]]; then
  for TRY in /opt/FlameGraph /usr/local/FlameGraph; do
    [[ -f "$TRY/flamegraph.pl" ]] && FG_DIR="$TRY" && break
  done
fi
# Repair a partial checkout (e.g. flamegraph.pl missing from an existing clone).
if [[ ! -f "$FG_DIR/flamegraph.pl" && -d "$FG_DIR/.git" ]]; then
  info "FlameGraph checkout incomplete — restoring from git ..."
  git -C "$FG_DIR" checkout -- flamegraph.pl stackcollapse-perf.pl 2>/dev/null || true
fi
if [[ ! -f "$FG_DIR/flamegraph.pl" ]]; then
  # git clone refuses a non-empty target dir; fall back to a fresh temp dir.
  if [[ -d "$FG_DIR" && -n "$(ls -A "$FG_DIR" 2>/dev/null)" ]]; then
    FG_DIR="$(mktemp -d)/FlameGraph"
  fi
  info "Cloning brendangregg/FlameGraph → $FG_DIR ..."
  git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FG_DIR"
fi
[[ -f "$FG_DIR/flamegraph.pl" ]] || die "FlameGraph unavailable at $FG_DIR"
ok "FlameGraph: $FG_DIR"

# Build the nettrace→folded converter once (cached under bin/).
CONV_DIR="$SCRIPT_DIR/nettrace-to-folded"
CONV_DLL=$(ls "$CONV_DIR"/bin/Release/net*/nettrace-to-folded.dll 2>/dev/null | head -1 || true)
if [[ -z "$CONV_DLL" ]]; then
  info "Building nettrace-to-folded converter ..."
  dotnet build -c Release "$CONV_DIR" >/dev/null || die "Failed to build the converter (needs the .NET SDK)."
  CONV_DLL=$(ls "$CONV_DIR"/bin/Release/net*/nettrace-to-folded.dll 2>/dev/null | head -1 || true)
fi
[[ -n "$CONV_DLL" ]] || die "Converter dll not found after build."
ok "Converter: $CONV_DLL"

WORK=$(mktemp -d /tmp/raven-dotnet-render-XXXXXXXX)
trap 'rm -rf "$WORK"' EXIT
tar xzf "$BUNDLE_FILE" -C "$WORK"
ARTIFACTS="$WORK/artifacts"
[[ -d "$ARTIFACTS" ]] || die "Bundle missing artifacts/ directory"

META="$ARTIFACTS/meta.txt"
get_meta() { grep "^${1}=" "$META" 2>/dev/null | cut -d= -f2- || echo "unknown"; }
BUNDLE_HOST=$(get_meta hostname); BUNDLE_DATE=$(get_meta date); CAPTURE_TYPE=$(get_meta capture_type)
[[ -z "$FG_TITLE" ]] && FG_TITLE="RavenDB ${CAPTURE_TYPE} – ${BUNDLE_HOST} ${BUNDLE_DATE}"

NETTRACE="$ARTIFACTS/managed-alloc.nettrace"
[[ -s "$NETTRACE" ]] || die "Bundle missing managed-alloc.nettrace"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  RavenDB dotnet renderer  (managed allocations)"
echo "  Host: $BUNDLE_HOST  Date: $BUNDLE_DATE"
echo "═══════════════════════════════════════════════════════"
echo ""

mkdir -p "$OUTPUT_DIR"
BASENAME="${BUNDLE_FILE%.tgz}"; BASENAME="${BASENAME%.tar.gz}"; BASENAME="$(basename "$BASENAME")"
FOLDED="$OUTPUT_DIR/${BASENAME}-managed-alloc.folded"
SUMMARY="$OUTPUT_DIR/${BASENAME}-managed-alloc-bytype.txt"
SVG="$OUTPUT_DIR/${BASENAME}-managed-alloc-flame.svg"

info "Converting .nettrace → byte-weighted folded stacks ..."
dotnet "$CONV_DLL" "$NETTRACE" --summary "$SUMMARY" > "$FOLDED" || die "Converter failed."
ok "folded: $(wc -l < "$FOLDED") stacks; summary: $SUMMARY"

"$FG_DIR/flamegraph.pl" \
  --title "$FG_TITLE (managed alloc, bytes)" \
  --colors mem --countname bytes \
  --hash --width 1600 \
  "$FOLDED" > "$SVG"
ok "SVG: $SVG ($(du -sh "$SVG" | cut -f1))"

echo ""
echo "── Top managed allocations by type ─────────────────"
head -15 "$SUMMARY"

if [[ -n "$S3_BUCKET" ]]; then
  command -v aws &>/dev/null || die "aws CLI not found."
  S3_KEY="${S3_BUCKET%/}/$(basename "$SVG")"
  aws s3 cp "$SVG" "$S3_KEY" --content-type "image/svg+xml"
  PRESIGN=$(aws s3 presign "$S3_KEY" --expires-in 3600 2>/dev/null || true)
  [[ -n "$PRESIGN" ]] && echo "  Link (1h): $PRESIGN"
fi

if [[ "$OPEN_SVG" -eq 1 ]]; then
  if command -v xdg-open &>/dev/null; then xdg-open "$SVG"
  elif command -v open &>/dev/null;    then open "$SVG"; fi
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Render complete. Output dir: $OUTPUT_DIR"
echo "═══════════════════════════════════════════════════════"
