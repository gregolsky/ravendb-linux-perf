#!/usr/bin/env bash
# 00-prereqs.sh — Check and configure prerequisites for RavenDB perf flamegraphs.
# Run as root or with sudo (perf needs elevated privileges).
# Usage: sudo bash 00-prereqs.sh [--persist]
#   --persist  Write sysctl settings to /etc/sysctl.d/99-perf.conf (survives reboot)
set -euo pipefail

PERSIST=0
for arg in "$@"; do [[ "$arg" == "--persist" ]] && PERSIST=1; done

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo "=== RavenDB perf flamegraph prerequisites ==="

# --- 1. perf ---
if ! command -v perf &>/dev/null; then
  warn "perf not found — installing linux-tools-generic ..."
  apt-get install -y linux-tools-generic linux-tools-"$(uname -r)" 2>/dev/null || \
    fail "Could not install perf. Run: apt-get install linux-tools-generic"
fi
PERF_VER=$(perf --version 2>&1 | head -1)
ok "perf: $PERF_VER"

# Verify perf inject --jit is available (some stripped builds lack it)
if ! perf inject --help 2>&1 | grep -q '\-\-jit'; then
  warn "This perf build may not support 'perf inject --jit'. Install a full linux-tools package."
else
  ok "perf inject --jit: available"
fi

# --- 2. kernel.perf_event_paranoid ---
CUR_PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
if [[ "$CUR_PARANOID" -gt 1 ]]; then
  warn "perf_event_paranoid=$CUR_PARANOID (> 1) — perf cannot sample. Lowering to -1 ..."
  sysctl -w kernel.perf_event_paranoid=-1
  ok "kernel.perf_event_paranoid set to -1"
else
  ok "kernel.perf_event_paranoid=$CUR_PARANOID (OK)"
fi

# --- 3. kernel.kptr_restrict ---
CUR_KPTR=$(cat /proc/sys/kernel/kptr_restrict)
if [[ "$CUR_KPTR" -gt 0 ]]; then
  warn "kptr_restrict=$CUR_KPTR — kernel symbols hidden. Lowering to 0 ..."
  sysctl -w kernel.kptr_restrict=0
  ok "kernel.kptr_restrict set to 0"
else
  ok "kernel.kptr_restrict=$CUR_KPTR (OK)"
fi

# --- 4. Persist (optional) ---
if [[ "$PERSIST" -eq 1 ]]; then
  cat > /etc/sysctl.d/99-perf.conf <<'EOF'
# Allow perf profiling and kernel symbol resolution.
# These are required for RavenDB perf flamegraph captures.
kernel.perf_event_paranoid = -1
kernel.kptr_restrict = 0
EOF
  ok "Settings persisted to /etc/sysctl.d/99-perf.conf"
else
  warn "Settings are NOT persisted and will revert after reboot. Use --persist to save them."
fi

# --- 5. kernel.sched_schedstats (off-CPU time-weighted capture) ---
CUR_SCHED=$(cat /proc/sys/kernel/sched_schedstats 2>/dev/null || echo "missing")
if [[ "$CUR_SCHED" == "missing" ]]; then
  warn "sched_schedstats not found — kernel may lack CONFIG_SCHEDSTATS. Off-CPU perf capture will be count-weighted only."
elif [[ "$CUR_SCHED" != "1" ]]; then
  warn "kernel.sched_schedstats=$CUR_SCHED — needed for time-weighted off-CPU. Enabling ..."
  sysctl -w kernel.sched_schedstats=1
  ok "kernel.sched_schedstats set to 1"
  if [[ "$PERSIST" -eq 1 ]]; then
    echo "kernel.sched_schedstats = 1" >> /etc/sysctl.d/99-perf.conf
  fi
else
  ok "kernel.sched_schedstats=1 (time-weighted off-CPU enabled)"
fi

# --- 6. eBPF tools (for off-CPU/IO/runqlat/offwake types) ---
BCC_FOUND=0
BPFTRACE_FOUND=0

# Try bcc-tools (Ubuntu: bpfcc-tools)
for CMD in offcputime-bpfcc offcputime; do
  if command -v "$CMD" &>/dev/null || [[ -x "/usr/share/bcc/tools/offcputime" ]]; then
    BCC_FOUND=1; break
  fi
done

if command -v bpftrace &>/dev/null; then
  BPFTRACE_FOUND=1
fi

if [[ "$BCC_FOUND" -eq 0 && "$BPFTRACE_FOUND" -eq 0 ]]; then
  warn "Neither bcc-tools nor bpftrace found — eBPF collector (ebpf/raven-ebpf-collect.sh) will not work."
  warn "Install: apt-get install bpfcc-tools  OR  apt-get install bpftrace"
else
  [[ "$BCC_FOUND"      -eq 1 ]] && ok "bcc-tools: available (offcputime / biolatency / runqlat / …)"
  [[ "$BPFTRACE_FOUND" -eq 1 ]] && ok "bpftrace: $(bpftrace --version 2>&1 | head -1)"
fi

# Allocation tracing (--type alloc) needs stackcount; memleak is used for the leak report.
for CMD in stackcount-bpfcc stackcount; do
  if command -v "$CMD" &>/dev/null || [[ -x "/usr/share/bcc/tools/stackcount" ]]; then
    ok "stackcount: available (--type alloc allocation-site flamegraphs)"; break
  fi
done
for CMD in memleak-bpfcc memleak; do
  if command -v "$CMD" &>/dev/null || [[ -x "/usr/share/bcc/tools/memleak" ]]; then
    ok "memleak: available (--type alloc outstanding/leak report)"; break
  fi
done

# BTF (needed by newer bcc/bpftrace)
if [[ -f "/sys/kernel/btf/vmlinux" ]]; then
  ok "BTF: /sys/kernel/btf/vmlinux present"
else
  warn "BTF not found (/sys/kernel/btf/vmlinux) — some eBPF tools may fall back to kheaders or fail."
fi

# --- 7. FlameGraph scripts ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FG_DIR="$SCRIPT_DIR/../FlameGraph"
if [[ -f "$FG_DIR/flamegraph.pl" && -f "$FG_DIR/stackcollapse-perf.pl" ]]; then
  ok "FlameGraph scripts: $FG_DIR"
else
  echo "Cloning brendangregg/FlameGraph into $FG_DIR ..."
  git clone --depth 1 https://github.com/brendangregg/FlameGraph "$FG_DIR"
  ok "FlameGraph scripts cloned"
fi

# --- 8. Perl (needed by FlameGraph scripts) ---
if ! command -v perl &>/dev/null; then
  warn "perl not found — installing ..."
  apt-get install -y perl
fi
ok "perl: $(perl --version 2>&1 | head -1)"

# --- 9. Optional: aws CLI ---
if command -v aws &>/dev/null; then
  ok "aws CLI: $(aws --version 2>&1 | head -1)"
else
  warn "aws CLI not found — S3 upload transport will not be available. Install via: snap install aws-cli --classic"
fi

# --- 10. Optional: nc (netcat) ---
if command -v nc &>/dev/null; then
  ok "nc (netcat): $(nc --version 2>&1 | head -1)"
else
  warn "nc not found — nc transport will not be available. Install via: apt-get install netcat-openbsd"
fi

# --- 11. ~/.debug writable (perf inject writes per-method ELF objects there) ---
DEBUG_DIR="${HOME}/.debug"
mkdir -p "$DEBUG_DIR"
ok "~/.debug: $DEBUG_DIR"

echo ""
echo "=== Prerequisites check complete ==="
echo ""
echo "Next steps:"
echo "  bash common/10-get-ravendb.sh                           # Download RavenDB (POC only)"
echo "  bash common/20-run-ravendb-profiled.sh                  # Launch with profiling knobs"
echo "  bash common/30-load.sh                                  # Generate load"
echo "  sudo bash perf/raven-perf-collect.sh --pid \$(pgrep -f Raven.Server | head -1) --type cpu --nc localhost:9000"
echo "  sudo bash ebpf/raven-ebpf-collect.sh --pid \$(pgrep -f Raven.Server | head -1) --type offcpu --nc localhost:9000"
