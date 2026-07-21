# Shared helpers for the bats suite.
#
# Tests are black-box where possible; a few source a collector to unit-test an
# individual function. The collectors are `set -euo pipefail` and have a
# `main`-guard, so sourcing defines their functions without running main.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
EBPF_COLLECT="$REPO_ROOT/ebpf/raven-ebpf-collect.sh"
PERF_COLLECT="$REPO_ROOT/perf/raven-perf-collect.sh"
EBPF_RENDER="$REPO_ROOT/ebpf/raven-ebpf-render.sh"
PERF_RENDER="$REPO_ROOT/perf/raven-perf-render.sh"

# Source a collector so its functions become callable in this test's subshell,
# then relax `set -eu` so a function returning non-zero doesn't abort the test
# (we assert on exit codes explicitly).
load_collector() {
  # shellcheck disable=SC1090
  source "$1"
  set +eu
}

# Skip the current test unless a real Linux /proc is available (needed by the
# tests that read /proc/<pid>/environ).
require_proc() {
  [[ -r /proc/self/environ ]] || skip "requires Linux /proc"
}
