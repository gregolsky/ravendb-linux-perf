#!/usr/bin/env bats
# Black-box renderer tests: hand-built fixture bundles + a stubbed flamegraph.pl.
# No perf.data / real FlameGraph needed for the eBPF renderer (perl only).

load helpers

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/artifacts" "$TMP/out"
  # Provide a stub flamegraph.pl at the location the renderer looks first
  # ($SCRIPT_DIR/../FlameGraph), unless a real clone is already there.
  FG_DIR="$REPO_ROOT/FlameGraph"
  FG_STUBBED=0
  if [[ ! -f "$FG_DIR/flamegraph.pl" ]]; then
    mkdir -p "$FG_DIR"
    cat > "$FG_DIR/flamegraph.pl" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: consume folded stdin, emit a fake SVG.
cat > /dev/null
echo '<svg xmlns="http://www.w3.org/2000/svg"><!-- stub flamegraph --></svg>'
STUB
    chmod +x "$FG_DIR/flamegraph.pl"
    FG_STUBBED=1
  fi
}

teardown() {
  rm -rf "$TMP"
  if [[ "${FG_STUBBED:-0}" -eq 1 ]]; then
    rm -f "$REPO_ROOT/FlameGraph/flamegraph.pl"
    rmdir "$REPO_ROOT/FlameGraph" 2>/dev/null || true
  fi
}

_write_meta() {
  cat > "$TMP/artifacts/meta.txt"
}

@test "ebpf render: no bundle arg → usage error" {
  run bash "$EBPF_RENDER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "ebpf render: nonexistent bundle → error" {
  run bash "$EBPF_RENDER" /no/such/bundle.tgz
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "ebpf render: cpu bundle → cpu SVG" {
  command -v perl >/dev/null || skip "requires perl"
  _write_meta <<EOF
hostname=testhost
date=2026-01-01T00:00:00Z
engine=ebpf
capture_type=cpu
host_pid=123
EOF
  printf 'Raven.Server;Foo;Bar 10\nVoron.Trees;Baz 5\n' > "$TMP/artifacts/cpu.folded"
  tar czf "$TMP/bundle.tgz" -C "$TMP" artifacts
  run bash "$EBPF_RENDER" "$TMP/bundle.tgz" --output-dir "$TMP/out"
  [ "$status" -eq 0 ]
  ls "$TMP/out"/*-cpu-flame.svg
}

@test "ebpf render: alloc bundle → malloc flame + memleak passthrough" {
  command -v perl >/dev/null || skip "requires perl"
  _write_meta <<EOF
hostname=testhost
date=2026-01-01T00:00:00Z
engine=ebpf
capture_type=alloc
host_pid=123
EOF
  printf 'Raven.Server;Sparrow.ByteString;malloc 3\n' > "$TMP/artifacts/alloc-malloc.folded"
  printf 'Top outstanding allocations:\n  1568 bytes ... CRYPTO_zalloc\n' > "$TMP/artifacts/memleak.txt"
  tar czf "$TMP/bundle.tgz" -C "$TMP" artifacts
  run bash "$EBPF_RENDER" "$TMP/bundle.tgz" --output-dir "$TMP/out"
  [ "$status" -eq 0 ]
  ls "$TMP/out"/*alloc-malloc-flame.svg
  [[ "$output" == *"outstanding"* ]]   # memleak.txt head printed
}

@test "ebpf render: alloc bundle → byte-weighted outstanding flame from memleak" {
  command -v perl >/dev/null || skip "requires perl"
  _write_meta <<EOF
engine=ebpf
capture_type=alloc
host_pid=123
hostname=h
date=d
EOF
  # memleak-style block: one stack, leaf-first, with a byte count
  cat > "$TMP/artifacts/memleak.txt" <<'ML'
[00:00:00] Top 1 stacks with outstanding allocations:
	4096 bytes in 2 allocations from stack
		malloc+0x1 [libc.so.6]
		[unknown] [libc.so.6]
		instance void [Raven.Server] Raven.Server.Foo::Bar()[OptimizedTier1]+0x1 [perf-123.map]
ML
  tar czf "$TMP/bundle.tgz" -C "$TMP" artifacts
  run bash "$EBPF_RENDER" "$TMP/bundle.tgz" --output-dir "$TMP/out"
  [ "$status" -eq 0 ]
  ls "$TMP/out"/*alloc-outstanding-bytes-flame.svg
  # folded should be byte-weighted (4096) and root-first (Raven … ; [native] ; malloc)
  grep -q 'Raven.Server.Foo::Bar' "$TMP/out"/*alloc-outstanding-bytes.folded
  grep -q ' 4096$' "$TMP/out"/*alloc-outstanding-bytes.folded
}

@test "ebpf render: faults bundle → faults flame" {
  command -v perl >/dev/null || skip "requires perl"
  _write_meta <<EOF
engine=ebpf
capture_type=faults
host_pid=123
hostname=h
date=d
EOF
  printf 'Raven.Server;Voron.Impl;[unknown];[unknown] 42\n' > "$TMP/artifacts/faults.folded"
  tar czf "$TMP/bundle.tgz" -C "$TMP" artifacts
  run bash "$EBPF_RENDER" "$TMP/bundle.tgz" --output-dir "$TMP/out"
  [ "$status" -eq 0 ]
  ls "$TMP/out"/*-faults-flame.svg
  # consecutive [unknown] collapse to a single [native]
  grep -q ';\[native\] 42$' "$TMP/out"/*faults.folded
}

@test "ebpf render: unknown capture_type → error" {
  command -v perl >/dev/null || skip "requires perl"
  _write_meta <<EOF
engine=ebpf
capture_type=bogus
host_pid=1
hostname=h
date=d
EOF
  : > "$TMP/artifacts/x"
  tar czf "$TMP/bundle.tgz" -C "$TMP" artifacts
  run bash "$EBPF_RENDER" "$TMP/bundle.tgz" --output-dir "$TMP/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown capture_type"* ]]
}
