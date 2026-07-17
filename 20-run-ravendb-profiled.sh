#!/usr/bin/env bash
# 20-run-ravendb-profiled.sh — Launch the downloaded RavenDB with perf/jitdump knobs.
# POC convenience: for production see README.md (systemd drop-in or docker -e flags).
#
# Usage: bash 20-run-ravendb-profiled.sh [--fp | --dwarf | --both]
#   --fp      Set DOTNET_PerfMapEnabled=3 (perfmap only; frame-pointer capture)  [default]
#   --dwarf   Set DOTNET_PerfMapEnabled=2 (jitdump only; dwarf+inject capture)
#   --both    Set DOTNET_PerfMapEnabled=1 (both; most permissive for experimentation)
#
# This script launches Raven.Server in the foreground.
# Run it in a separate terminal / screen / tmux pane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAVEN_BIN="$SCRIPT_DIR/RavenDB/Server/Raven.Server"

if [[ ! -f "$RAVEN_BIN" ]]; then
  echo "ERROR: $RAVEN_BIN not found — run 10-get-ravendb.sh first."
  exit 1
fi

MODE="${1:---fp}"
case "$MODE" in
  --fp)    PERF_MAP_ENABLED=3 ;;   # perfmap only  → /tmp/perf-$PID.map
  --dwarf) PERF_MAP_ENABLED=2 ;;   # jitdump only  → /tmp/jit-$PID.dump
  --both)  PERF_MAP_ENABLED=1 ;;   # both
  *) echo "Unknown mode $MODE (use --fp / --dwarf / --both)"; exit 1 ;;
esac

# Patch settings.json for headless unsecured mode (RavenDB 7.x)
SETTINGS="$SCRIPT_DIR/RavenDB/Server/settings.json"
if [[ -f "$SETTINGS" ]]; then
  # Rewrite — overrides setup wizard / security block
  cat > "$SETTINGS" << 'SETTINGS_EOF'
{
    "ServerUrl": "http://127.0.0.1:8080",
    "Setup.Mode": "None",
    "Security.UnsecuredAccessAllowed": "PublicNetwork",
    "License.Eula.Accepted": true,
    "DataDir": "RavenData"
}
SETTINGS_EOF
  echo "settings.json patched for headless unsecured mode"
fi

echo "=== Launching RavenDB with profiling knobs (mode: $MODE) ==="
echo "    DOTNET_PerfMapEnabled=$PERF_MAP_ENABLED"
echo "    DOTNET_ReadyToRun=0  (force-JIT framework code for full symbols)"
echo "    DOTNET_EnableWriteXorExecute=0  (prevent memfd:doublemapper frames)"
echo ""
echo "NOTE: /tmp/perf-\$PID.map and/or /tmp/jit-\$PID.dump will appear seconds"
echo "      after startup as the JIT compiles hot paths."
echo ""

# --- DOTNET runtime knobs ---
export DOTNET_PerfMapEnabled=$PERF_MAP_ENABLED
export DOTNET_ReadyToRun=0
export DOTNET_EnableWriteXorExecute=0
export DOTNET_PerfMapShowOptimizationTiers=1   # optional: tag tier0/tier1 in symbol names

# --- RavenDB headless/unsecured on loopback (POC only) ---
export RAVEN_Setup_Mode=None
export RAVEN_License_Eula_Accepted=true
export RAVEN_ServerUrl=http://127.0.0.1:8080
export RAVEN_Security_UnsecuredAccessAllowed=PrivateNetwork

exec "$RAVEN_BIN"
