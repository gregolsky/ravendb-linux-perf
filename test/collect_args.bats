#!/usr/bin/env bats
# Argument-parser unit tests for both collectors (source parse_args, call it).
# These need no perf/eBPF/RavenDB — pure exit-code + variable assertions.

load helpers

# ─── eBPF collector ──────────────────────────────────────────────────────────

@test "ebpf parse_args: --service … --type alloc parses (regression: shift over-shift)" {
  # Pre-fix, the target arms did `shift 2` + a trailing `shift`, eating --type
  # and failing with 'Unknown flag: alloc'. This asserts correct parsing.
  load_collector "$EBPF_COLLECT"
  parse_args --service ravendb --type alloc --duration 15 --output /tmp/x
  [ "$MODE_TARGET" = "service" ]
  [ "$TARGET_ARG" = "ravendb" ]
  [ "$TRACE_TYPE" = "alloc" ]
  [ "$DURATION" = "15" ]
  [ "$OUTPUT_DIR" = "/tmp/x" ]
}

@test "ebpf parse_args: --pid before other flags keeps them (over-shift regression)" {
  load_collector "$EBPF_COLLECT"
  parse_args --pid 123 --type cpu --nc host:9000
  [ "$MODE_TARGET" = "pid" ]
  [ "$TARGET_ARG" = "123" ]
  [ "$TRACE_TYPE" = "cpu" ]
  [ "$NC_DEST" = "host:9000" ]
}

@test "ebpf parse_args: all valid types accepted" {
  load_collector "$EBPF_COLLECT"
  for t in cpu offcpu offwake io runqlat alloc faults; do
    parse_args --pid 1 --type "$t"
    [ "$TRACE_TYPE" = "$t" ]
  done
}

@test "ebpf: runs from stdin (curl|bash) without unbound-variable (main-guard regression)" {
  # Reproduces `curl … | bash -s -- …`: piping the script to bash leaves
  # BASH_SOURCE unset. Pre-fix the guard `${BASH_SOURCE[0]}` tripped `set -u`.
  run bash -s -- --type cpu < "$EBPF_COLLECT"
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"Specify a target"* ]]   # main ran → parse_args reached
}

@test "perf: runs from stdin (curl|bash) without unbound-variable (main-guard regression)" {
  run bash -s -- --type cpu < "$PERF_COLLECT"
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"Specify a target"* ]]
}

@test "ebpf parse_args: missing target → error" {
  load_collector "$EBPF_COLLECT"
  run parse_args --type cpu
  [ "$status" -ne 0 ]
  [[ "$output" == *"Specify a target"* ]]
}

@test "ebpf parse_args: unknown flag → error" {
  load_collector "$EBPF_COLLECT"
  run parse_args --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag"* ]]
}

@test "ebpf parse_args: unknown --type → error" {
  load_collector "$EBPF_COLLECT"
  run parse_args --pid 1 --type nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown --type"* ]]
}

# ─── perf collector ──────────────────────────────────────────────────────────

@test "perf parse_args: --service … --type cpu parses (over-shift regression)" {
  load_collector "$PERF_COLLECT"
  parse_args --service ravendb --type cpu --duration 20 --dwarf
  [ "$MODE_TARGET" = "service" ]
  [ "$TARGET_ARG" = "ravendb" ]
  [ "$TRACE_TYPE" = "cpu" ]
  [ "$CAPTURE_MODE" = "dwarf" ]
}

@test "perf parse_args: eBPF-only --type alloc is rejected with a redirect" {
  load_collector "$PERF_COLLECT"
  run parse_args --pid 1 --type alloc
  [ "$status" -ne 0 ]
  [[ "$output" == *"eBPF-only"* ]]
}

@test "perf parse_args: eBPF-only --type runqlat is rejected with a redirect" {
  load_collector "$PERF_COLLECT"
  run parse_args --pid 1 --type runqlat
  [ "$status" -ne 0 ]
  [[ "$output" == *"eBPF-only"* ]]
}
