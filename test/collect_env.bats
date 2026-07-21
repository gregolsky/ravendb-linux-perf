#!/usr/bin/env bats
# Regression tests for the `set -e` silent-death bug: check_process_env ended
# with `[[ MISSING -eq 1 ]] && print_relaunch_hint`, which returned 1 when the
# knobs WERE set, killing the script under `set -e`. These spawn a real helper
# process carrying (or lacking) the knobs in its /proc/<pid>/environ.

load helpers

@test "ebpf check_process_env: returns 0 when knobs are set (set -e regression)" {
  require_proc
  load_collector "$EBPF_COLLECT"
  env DOTNET_PerfMapEnabled=1 DOTNET_EnableWriteXorExecute=0 sleep 30 &
  local pid=$!
  HOST_PID=$pid
  run check_process_env
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOTNET_PerfMapEnabled=1"* ]]
  [[ "$output" == *"DOTNET_EnableWriteXorExecute=0"* ]]
}

@test "ebpf check_process_env: relaunch hint (exit 2) when knobs missing" {
  require_proc
  load_collector "$EBPF_COLLECT"
  env -i sleep 30 &
  local pid=$!
  HOST_PID=$pid
  run check_process_env
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 2 ]
  [[ "$output" == *"required profiling knobs"* ]]
}

@test "ebpf check_process_env: accepts CORECLR_ prefix (net 11+) too" {
  require_proc
  load_collector "$EBPF_COLLECT"
  env CORECLR_PerfMapEnabled=1 CORECLR_EnableWriteXorExecute=0 sleep 30 &
  local pid=$!
  HOST_PID=$pid
  run check_process_env
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "perf check_process_env: returns 0 when knobs set for fp capture (set -e regression)" {
  require_proc
  load_collector "$PERF_COLLECT"
  CAPTURE_MODE=fp
  env DOTNET_PerfMapEnabled=1 DOTNET_EnableWriteXorExecute=0 sleep 30 &
  local pid=$!
  HOST_PID=$pid
  run check_process_env
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOTNET_PerfMapEnabled=1"* ]]
}
