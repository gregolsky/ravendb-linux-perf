#!/usr/bin/env bash
# 10-get-ravendb.sh — Download and extract the latest stable RavenDB release (POC only).
# In production, RavenDB is installed as a systemd service or run via docker ravendb/ravendb.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAVENDB_DIR="$SCRIPT_DIR/RavenDB"
TARBALL="$SCRIPT_DIR/ravendb.tar.bz2"

if [[ -f "$RAVENDB_DIR/Server/Raven.Server" ]]; then
  echo "RavenDB already extracted at $RAVENDB_DIR"
  exit 0
fi

echo "=== Downloading RavenDB for Linux x64 (latest stable) ==="
wget --progress=bar:force \
     -O "$TARBALL" \
     "https://hibernatingrhinos.com/downloads/RavenDB%20for%20Linux%20x64/latest"

echo ""
echo "=== Extracting ... ==="
mkdir -p "$RAVENDB_DIR"
tar xjf "$TARBALL" --strip-components=1 -C "$RAVENDB_DIR"
rm -f "$TARBALL"

RAVEN_BIN="$RAVENDB_DIR/Server/Raven.Server"
if [[ ! -f "$RAVEN_BIN" ]]; then
  echo "ERROR: Extraction failed — $RAVEN_BIN not found."
  exit 1
fi

# Print the bundled .NET version
DOTNET_VER=$("$RAVENDB_DIR/Server/Raven.Server" --version 2>&1 | head -2 || true)
echo ""
echo "RavenDB extracted to: $RAVENDB_DIR"
echo "$DOTNET_VER"
echo ""
echo "Next: bash 20-run-ravendb-profiled.sh"
