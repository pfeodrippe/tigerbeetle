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
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if [[ -s "$PORT_FILE" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "error: timed out waiting for $PORT_FILE" >&2
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
  local main_file="$ROOT_DIR/src/tigerbeetle/main.zig"

  if ! awk -F '\t' \
    -v protocol_file="$protocol_file" \
    -v stdx_file="$stdx_file" \
    -v trace_file="$trace_file" \
    -v trace_event_file="$trace_event_file" \
    -v vsr_file="$vsr_file" \
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
    $1 == "decl-edge" && $2 == "type_dep" {
      type_dep[$3 SUBSEP $4] = 1
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
      if (!((log_runtime_key SUBSEP log_level_runtime_key) in reads)) {
        print "error: missing declaration graph reads edge: log_runtime -> log_level_runtime" > "/dev/stderr"
        exit 1
      }
      if (!((main_key SUBSEP log_level_runtime_key) in writes)) {
        print "error: missing declaration graph writes edge: main -> log_level_runtime" > "/dev/stderr"
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

echo "hot smoke test passed"
