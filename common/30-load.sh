#!/usr/bin/env bash
# 30-load.sh — Create Demo database, load Northwind sample data, drive CPU load.
#
# Usage: bash 30-load.sh [--url http://127.0.0.1:8080] [--duration 60] [--concurrency 4]
set -euo pipefail

RAVEN_URL="http://127.0.0.1:8080"
DURATION=60
CONCURRENCY=4

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)         RAVEN_URL="$2"; shift 2 ;;
    --duration)    DURATION="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

DB="Demo"

wait_raven() {
  echo "Waiting for RavenDB at $RAVEN_URL ..."
  for i in $(seq 1 30); do
    # Use /databases endpoint — returns 200 when the server is ready for requests
    CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$RAVEN_URL/databases" 2>/dev/null || echo "err")
    if [[ "$CODE" == "200" ]]; then
      echo "RavenDB is up (HTTP $CODE)."
      return
    fi
    sleep 2
  done
  echo "ERROR: RavenDB did not respond at $RAVEN_URL after 60s"
  exit 1
}

create_db() {
  echo "Creating database '$DB' ..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "$RAVEN_URL/admin/databases" \
    -H 'Content-Type: application/json' \
    -d "{\"DatabaseName\":\"$DB\",\"Settings\":{},\"Disabled\":false,\"Encrypted\":false,\"Replication\":{\"Factor\":1,\"Members\":[{\"Url\":\"$RAVEN_URL\",\"Database\":\"$DB\"}]}}")
  if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
    echo "Database '$DB' created (HTTP $HTTP_CODE)."
  elif [[ "$HTTP_CODE" == "409" ]]; then
    echo "Database '$DB' already exists."
  else
    echo "WARNING: Unexpected HTTP $HTTP_CODE when creating database."
  fi
}

load_sample_data() {
  echo "Loading Northwind sample data ..."
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$RAVEN_URL/databases/$DB/studio/sample-data" \
    -H 'Content-Length: 0')
  echo "Sample data load: HTTP $HTTP_CODE"
  # Give RavenDB a moment to index the imported data
  sleep 3
}

drive_load() {
  echo ""
  echo "=== Driving CPU load for ${DURATION}s with concurrency=${CONCURRENCY} ==="
  echo "(Run 'perf record' now in another terminal)"
  echo ""

  DEADLINE=$(( $(date +%s) + DURATION ))

  # Worker function: alternate queries and bulk writes in a tight loop
  worker() {
    local WORKER_ID=$1
    local DOC_SEQ=0
    while [[ $(date +%s) -lt $DEADLINE ]]; do
      # Query: order by companyName, vary the offset to defeat caching
      OFFSET=$(( (DOC_SEQ * WORKER_ID * 7) % 200 ))
      curl -sf -X POST \
        "$RAVEN_URL/databases/$DB/queries" \
        -H 'Content-Type: application/json' \
        -d "{\"Query\":\"from Orders where Company != null order by OrderedAt desc limit 50 offset $OFFSET\"}" \
        -o /dev/null

      # Write: a small document batch
      DOC_ID="Perf/Worker-${WORKER_ID}-Doc-${DOC_SEQ}"
      curl -sf -X POST \
        "$RAVEN_URL/databases/$DB/bulk_docs" \
        -H 'Content-Type: application/json' \
        -d "{\"Commands\":[{\"Type\":\"PUT\",\"Id\":\"$DOC_ID\",\"Document\":{\"WorkerId\":$WORKER_ID,\"Seq\":$DOC_SEQ,\"@metadata\":{\"@collection\":\"PerfLoad\"}}}]}" \
        -o /dev/null

      DOC_SEQ=$(( DOC_SEQ + 1 ))
    done
  }

  # Launch workers in background
  PIDS=()
  for i in $(seq 1 "$CONCURRENCY"); do
    worker "$i" &
    PIDS+=($!)
  done

  # Progress indicator
  ELAPSED=0
  while [[ $(date +%s) -lt $DEADLINE ]]; do
    REMAINING=$(( DEADLINE - $(date +%s) ))
    printf "\r  %3ds remaining ..." "$REMAINING"
    sleep 2
    ELAPSED=$(( ELAPSED + 2 ))
  done
  echo ""

  # Wait for workers
  for PID in "${PIDS[@]}"; do wait "$PID" 2>/dev/null || true; done

  echo "Load generation complete."
}

wait_raven
create_db
load_sample_data
drive_load
