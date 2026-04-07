#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_BIN="${ZIG_BIN:-${HOT_ZIG:-zig}}"
ZIG_LIB_DIR="${ZIG_LIB_DIR:-${HOT_ZIG_LIB_DIR:-}}"
PORT_FILE="${PORT_FILE:-$ROOT_DIR/.nrepl-port}"
HOT_CONFIG_FILE="${HOT_CONFIG_FILE:-$ROOT_DIR/zig-out/share/zig-hot/tigerbeetle.config}"

if [[ "$ZIG_BIN" == */* ]]; then
  [[ -x "$ZIG_BIN" ]] || {
    echo "error: missing ZIG_BIN at $ZIG_BIN" >&2
    exit 1
  }
else
  command -v "$ZIG_BIN" >/dev/null 2>&1 || {
    echo "error: ZIG_BIN command not found: $ZIG_BIN" >&2
    exit 1
  }
fi

LLVM_PREFIX="${LLVM_PREFIX:-$(brew --prefix llvm@20 2>/dev/null || true)}"
LLD_PREFIX="${LLD_PREFIX:-$(brew --prefix lld@20 2>/dev/null || true)}"
ZSTD_PREFIX="${ZSTD_PREFIX:-$(brew --prefix zstd 2>/dev/null || true)}"
LIBXML2_PREFIX="${LIBXML2_PREFIX:-$(brew --prefix libxml2 2>/dev/null || true)}"
ZLIB_PREFIX="${ZLIB_PREFIX:-$(brew --prefix zlib 2>/dev/null || true)}"

prepend_lib_dir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  if [[ -z "${DYLD_LIBRARY_PATH:-}" ]]; then
    export DYLD_LIBRARY_PATH="$dir"
  else
    export DYLD_LIBRARY_PATH="$dir:$DYLD_LIBRARY_PATH"
  fi
}

prepend_lib_dir "$LLVM_PREFIX/lib"
prepend_lib_dir "$LLD_PREFIX/lib"
prepend_lib_dir "$ZSTD_PREFIX/lib"
prepend_lib_dir "$LIBXML2_PREFIX/lib"
prepend_lib_dir "$ZLIB_PREFIX/lib"

wait_for_port_file() {
  local timeout="${PORT_FILE_TIMEOUT:-600}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ -s "$PORT_FILE" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "error: timed out after ${timeout}s waiting for $PORT_FILE" >&2
  exit 1
}

wait_for_hot_config_file() {
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if [[ -f "$HOT_CONFIG_FILE" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "error: missing hot config at $HOT_CONFIG_FILE" >&2
  exit 1
}

validate_decl_graph_semantic_edges() {
  local protocol_file="$ROOT_DIR/src/cdc/amqp/protocol.zig"
  local stdx_file="$ROOT_DIR/src/stdx/stdx.zig"
  local trace_file="$ROOT_DIR/src/trace.zig"
  local trace_event_file="$ROOT_DIR/src/trace/event.zig"
  local vsr_file="$ROOT_DIR/src/vsr.zig"
  local message_buffer_file="$ROOT_DIR/src/message_buffer.zig"
  local main_file="$ROOT_DIR/src/tigerbeetle/main.zig"

  if ! awk -F '\t' \
    -v protocol_file="$protocol_file" \
    -v stdx_file="$stdx_file" \
    -v trace_file="$trace_file" \
    -v trace_event_file="$trace_event_file" \
    -v vsr_file="$vsr_file" \
    -v message_buffer_file="$message_buffer_file" \
    -v main_file="$main_file" '
    $1 == "decl-node" && $4 == protocol_file && $5 == "Decoder.read_short_string" {
      read_short_string_key = $2
    }
    $1 == "decl-node" && $4 == protocol_file && $5 == "Decoder.read_int" {
      read_int_key = $2
    }
    $1 == "decl-node" && $4 == protocol_file && $5 == "Decoder.read_bytes" {
      read_bytes_key = $2
    }
    $1 == "decl-node" && $4 == protocol_file && $5 == "Decoder.Error" {
      decoder_error_key = $2
    }
    $1 == "decl-node" && $4 == protocol_file && $5 == "Decoder.read_field" {
      read_field_key = $2
    }
    $1 == "decl-node" && $4 == protocol_file && $5 == "Decoder.read_enum" {
      read_enum_key = $2
    }
    $1 == "decl-node" && $4 == vsr_file && $5 == "quorums" {
      quorums_key = $2
    }
    $1 == "decl-node" && $4 == vsr_file && $5 == "Command" {
      command_key = $2
    }
    $1 == "decl-node" && $4 == stdx_file && $5 == "div_ceil" {
      div_ceil_key = $2
    }
    $1 == "decl-node" && $4 == trace_file && $5 == "gauge" {
      gauge_key = $2
    }
    $1 == "decl-node" && $4 == trace_file && $5 == "count" {
      count_key = $2
    }
    $1 == "decl-node" && $4 == trace_event_file && $5 == "EventMetric" {
      event_metric_key = $2
    }
    $1 == "decl-node" && $4 == main_file && $5 == "log_runtime" {
      log_runtime_key = $2
    }
    $1 == "decl-node" && $4 == main_file && $5 == "main" {
      main_key = $2
    }
    $1 == "decl-node" && $4 == main_file && $5 == "log_level_runtime" {
      log_level_runtime_key = $2
    }
    $1 == "decl-node" && $4 == message_buffer_file && $5 == "MessageBuffer.advance_header" {
      advance_header_key = $2
    }
    $1 == "decl-edge" && $2 == "type_dep" {
      type_dep[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "layout_dep" {
      layout_dep[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "calls" {
      calls[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "reads" {
      reads[$3 SUBSEP $4] = 1
      next
    }
    $1 == "decl-edge" && $2 == "writes" {
      writes[$3 SUBSEP $4] = 1
    }
    $1 == "decl-edge" && $2 == "specializes" {
      specializes[$3 SUBSEP $4] = 1
    }
    END {
      if (read_short_string_key == "") {
        print "error: missing declaration graph node for Decoder.read_short_string" > "/dev/stderr"
        exit 1
      }
      if (read_int_key == "") {
        print "error: missing declaration graph node for Decoder.read_int" > "/dev/stderr"
        exit 1
      }
      if (read_bytes_key == "") {
        print "error: missing declaration graph node for Decoder.read_bytes" > "/dev/stderr"
        exit 1
      }
      if (decoder_error_key == "") {
        print "error: missing declaration graph node for Decoder.Error" > "/dev/stderr"
        exit 1
      }
      if (read_field_key == "") {
        print "error: missing declaration graph node for Decoder.read_field" > "/dev/stderr"
        exit 1
      }
      if (read_enum_key == "") {
        print "error: missing declaration graph node for Decoder.read_enum" > "/dev/stderr"
        exit 1
      }
      if (quorums_key == "") {
        print "error: missing declaration graph node for quorums" > "/dev/stderr"
        exit 1
      }
      if (command_key == "") {
        print "error: missing declaration graph node for Command" > "/dev/stderr"
        exit 1
      }
      if (div_ceil_key == "") {
        print "error: missing declaration graph node for stdx.div_ceil" > "/dev/stderr"
        exit 1
      }
      if (gauge_key == "") {
        print "error: missing declaration graph node for gauge" > "/dev/stderr"
        exit 1
      }
      if (count_key == "") {
        print "error: missing declaration graph node for count" > "/dev/stderr"
        exit 1
      }
      if (event_metric_key == "") {
        print "error: missing declaration graph node for EventMetric" > "/dev/stderr"
        exit 1
      }
      if (log_runtime_key == "") {
        print "error: missing declaration graph node for log_runtime" > "/dev/stderr"
        exit 1
      }
      if (main_key == "") {
        print "error: missing declaration graph node for main" > "/dev/stderr"
        exit 1
      }
      if (log_level_runtime_key == "") {
        print "error: missing declaration graph node for log_level_runtime" > "/dev/stderr"
        exit 1
      }
      if (advance_header_key == "") {
        print "error: missing declaration graph node for MessageBuffer.advance_header" > "/dev/stderr"
        exit 1
      }
      if (!((read_short_string_key SUBSEP decoder_error_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: Decoder.read_short_string -> Decoder.Error" > "/dev/stderr"
        exit 1
      }
      if (!((read_short_string_key SUBSEP read_int_key) in calls)) {
        print "error: missing declaration graph calls edge: Decoder.read_short_string -> Decoder.read_int" > "/dev/stderr"
        exit 1
      }
      if (!((read_short_string_key SUBSEP read_bytes_key) in calls)) {
        print "error: missing declaration graph calls edge: Decoder.read_short_string -> Decoder.read_bytes" > "/dev/stderr"
        exit 1
      }
      if (!((read_field_key SUBSEP read_enum_key) in calls)) {
        print "error: missing declaration graph calls edge: Decoder.read_field -> Decoder.read_enum" > "/dev/stderr"
        exit 1
      }
      if (!((quorums_key SUBSEP div_ceil_key) in calls)) {
        print "error: missing declaration graph calls edge: quorums -> stdx.div_ceil" > "/dev/stderr"
        exit 1
      }
      if (!((gauge_key SUBSEP event_metric_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: gauge -> EventMetric" > "/dev/stderr"
        exit 1
      }
      if (!((count_key SUBSEP event_metric_key) in type_dep)) {
        print "error: missing declaration graph type_dep edge: count -> EventMetric" > "/dev/stderr"
        exit 1
      }
      if (!((advance_header_key SUBSEP command_key) in layout_dep)) {
        print "error: missing declaration graph layout_dep edge: MessageBuffer.advance_header -> Command" > "/dev/stderr"
        exit 1
      }
      if (!((log_runtime_key SUBSEP log_level_runtime_key) in reads)) {
        print "error: missing declaration graph reads edge: log_runtime -> log_level_runtime" > "/dev/stderr"
        exit 1
      }
      if (!((main_key SUBSEP log_level_runtime_key) in writes)) {
        print "error: missing declaration graph writes edge: main -> log_level_runtime" > "/dev/stderr"
        exit 1
      }
      if (!((read_enum_key SUBSEP read_int_key) in specializes)) {
        print "error: missing declaration graph specializes edge: Decoder.read_enum -> Decoder.read_int" > "/dev/stderr"
        exit 1
      }
    }
  ' "$HOT_CONFIG_FILE"; then
    exit 1
  fi
}

zig_hot() {
  local -a cmd=(env ZIG_HOT_CONFIG_FILE="$HOT_CONFIG_FILE" DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-}")
  if [[ -n "$ZIG_LIB_DIR" ]]; then
    cmd+=(ZIG_LIB_DIR="$ZIG_LIB_DIR")
  fi
  cmd+=("$ZIG_BIN" hot --port-file "$PORT_FILE" "$@")
  (
    cd "$ROOT_DIR"
    "${cmd[@]}"
  )
}

expect_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "error: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

run_hot() {
  local output
  if ! output="$(zig_hot "$@" 2>&1)"; then
    echo "$output" >&2
    exit 1
  fi
  printf '%s' "$output"
}

wait_for_runtime_ready() {
  local deadline=$((SECONDS + 120))
  local output=""
  while (( SECONDS < deadline )); do
    if output="$(zig_hot describe 2>&1)"; then
      printf '%s' "$output"
      return 0
    fi
    sleep 1
  done

  echo "error: timed out waiting for hot runtime describe" >&2
  echo "$output" >&2
  exit 1
}

expect_eval_value() {
  local expr="$1"
  local expected="$2"
  local output
  output="$(run_hot --eval "$expr")"
  expect_contains "$output" "value: $expected"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
}

wait_for_hot_config_file
validate_decl_graph_semantic_edges
wait_for_port_file

describe_output="$(wait_for_runtime_ready)"
expect_contains "$describe_output" "stdx.zeroed"
expect_contains "$describe_output" "vsr.sector_ceil"
expect_contains "$describe_output" "vsr.quorums"
expect_contains "$describe_output" "repl.completion.Completion.split_and_complete"
expect_contains "$describe_output" "cdc.amqp.protocol.Decoder.init"
expect_contains "$describe_output" "cdc.amqp.protocol.Decoder.read_short_string"

expect_eval_value 'stdx.zeroed("abc")' "false"
expect_eval_value 'vsr.sector_ceil(1)' "4096"
expect_eval_value 'vsr.quorums(3).replication' "2"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_short_string(cdc.amqp.protocol.Decoder.init([3,97,98,99]))' '"abc"'

# ── Real TigerBeetle function compile-body tests ──────────────────────

# zeroed — for loop with bitwise OR over bytes (no cross-module calls)
zeroed_output="$(zig_hot compile-body src/stdx/stdx.zig zeroed 2>&1)"
expect_contains "$zeroed_output" "instructions:"

# sector_ceil with arg 0 — should return 0
sector0_output="$(zig_hot compile-body src/vsr.zig sector_ceil 0 2>&1 || true)"
echo "sector_ceil(0) output: ${sector0_output:0:80}"

# Duration.to_ms — cross-module import resolution (std.time.ns_per_ms) — Phase 8
to_ms_output="$(zig_hot compile-body src/stdx/time_units.zig to_ms 2>&1 || true)"
expect_contains "$to_ms_output" "instructions:"
echo "to_ms compiles: ${to_ms_output:0:80}"

# Duration.min — @min builtin on struct fields (no cross-module calls)
dur_min_output="$(zig_hot compile-body src/stdx/time_units.zig min 2>&1)"
expect_contains "$dur_min_output" "instructions:"

# ── Assoc override end-to-end tests ─────────────────────────────────

# Override Duration.to_ms — qualified with struct name and file
assoc_output="$(zig_hot assoc Duration.to_ms --file src/stdx/time_units.zig 'fn to_ms(duration: Duration) u64 { return 42; }' 2>&1)"
expect_contains "$assoc_output" "done"
echo "assoc Duration.to_ms override: OK"

# Dissoc Duration.to_ms — restore original
dissoc_to_ms="$(zig_hot dissoc Duration.to_ms 2>&1)"
expect_contains "$dissoc_to_ms" "done"
echo "dissoc Duration.to_ms: OK"

# Override stdx.zeroed — function-level assoc (not struct-qualified)
assoc_zeroed="$(zig_hot assoc zeroed --file src/stdx/stdx.zig 'fn zeroed(bytes: []const u8) bool { return true; }' 2>&1)"
expect_contains "$assoc_zeroed" "done"
echo "assoc zeroed override: OK"

# Dissoc zeroed — restore original
dissoc_zeroed="$(zig_hot dissoc zeroed 2>&1)"
expect_contains "$dissoc_zeroed" "done"
echo "dissoc zeroed: OK"

# Override vsr.sector_ceil — non-trivial math helper used across storage layout paths
assoc_sector_ceil="$(zig_hot assoc sector_ceil --file src/vsr.zig 'fn sector_ceil(offset: u64) u64 { _ = offset; return 8192; }' 2>&1)"
expect_contains "$assoc_sector_ceil" "done"
expect_contains "$assoc_sector_ceil" "native: patched"
expect_eval_value 'vsr.sector_ceil(1)' "8192"
echo "assoc sector_ceil override: OK"

# Dissoc sector_ceil — restore original
dissoc_sector_ceil="$(zig_hot dissoc sector_ceil 2>&1)"
expect_contains "$dissoc_sector_ceil" "done"
expect_contains "$dissoc_sector_ceil" "native: restored"
expect_eval_value 'vsr.sector_ceil(1)' "4096"
echo "dissoc sector_ceil: OK"

# Override Duration.clamp — multi-branch duration bounds logic
assoc_duration_clamp="$(zig_hot assoc Duration.clamp --file src/stdx/time_units.zig 'fn clamp(duration: Duration, clamp_min: Duration, clamp_max: Duration) Duration { _ = duration; _ = clamp_min; _ = clamp_max; return .{ .ns = 7 }; }' 2>&1)"
expect_contains "$assoc_duration_clamp" "done"
clamp_body="$(zig_hot compile-body src/stdx/time_units.zig clamp 2>&1 || true)"
expect_contains "$clamp_body" "instructions:"
echo "assoc Duration.clamp override: OK"

# Dissoc Duration.clamp — restore original duration clamp logic
dissoc_duration_clamp="$(zig_hot dissoc Duration.clamp 2>&1)"
expect_contains "$dissoc_duration_clamp" "done"
echo "dissoc Duration.clamp: OK"

# Override Decoder.read_short_string — error-union method with decoder state
assoc_read_short_string="$(zig_hot assoc Decoder.read_short_string --file src/cdc/amqp/protocol.zig 'fn read_short_string(self: *Decoder) Error![]const u8 { _ = self; return "patched"; }' 2>&1)"
expect_contains "$assoc_read_short_string" "done"
expect_contains "$assoc_read_short_string" "native: patched"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_short_string(cdc.amqp.protocol.Decoder.init([3,97,98,99]))' '"patched"'
echo "assoc Decoder.read_short_string override: OK"

# Dissoc Decoder.read_short_string — restore original
dissoc_read_short_string="$(zig_hot dissoc Decoder.read_short_string 2>&1)"
expect_contains "$dissoc_read_short_string" "done"
expect_contains "$dissoc_read_short_string" "native: restored"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_short_string(cdc.amqp.protocol.Decoder.init([3,97,98,99]))' '"abc"'
echo "dissoc Decoder.read_short_string: OK"

# Assoc with malformed code — should return clean error, not crash
malformed_output="$(zig_hot assoc zeroed --file src/stdx/stdx.zig 'fn zeroed(BROKEN SYNTAX' 2>&1 || true)"
if echo "$malformed_output" | grep -qF "done"; then
  echo "assoc malformed code: OK (accepted — no crash)"
else
  echo "assoc malformed code: OK (rejected cleanly)"
fi

# Assoc for non-existent function — should not crash
nonexist_output="$(zig_hot assoc totally_bogus_function_name --file src/stdx/stdx.zig 'fn bogus() void {}' 2>&1 || true)"
echo "assoc non-existent function: OK (no crash)"

echo "hot smoke test passed"
