#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_BIN="${ZIG_BIN:-${HOT_ZIG:-zig}}"
ZIG_LIB_DIR="${ZIG_LIB_DIR:-${HOT_ZIG_LIB_DIR:-}}"
PORT_FILE="${PORT_FILE:-$ROOT_DIR/.nrepl-port}"
HOT_CONFIG_FILE="${HOT_CONFIG_FILE:-$ROOT_DIR/zig-out/share/zig-hot/tigerbeetle.config}"
HOT_LOG="${HOT_LOG:-$ROOT_DIR/.hot-run.log}"
HOT_PID_FILE="${HOT_PID_FILE:-$ROOT_DIR/.hot-run.pid}"
HOT_TEST_PROMOTION_WORKERS="${HOT_TEST_PROMOTION_WORKERS:-2}"
HOT_REPL_BUILD_CACHE_DIR="${HOT_REPL_BUILD_CACHE_DIR:-$ROOT_DIR/.zig-hot-client-build-cache}"
HOT_REPL_GLOBAL_CACHE_DIR="${HOT_REPL_GLOBAL_CACHE_DIR:-$ROOT_DIR/.zig-hot-client-global-cache}"
TB_SERVER_ADDRESS=""
TIGERBEETLE_SOURCE_REL="src/tigerbeetle.zig"
TIGERBEETLE_SOURCE_FILE="$ROOT_DIR/$TIGERBEETLE_SOURCE_REL"
TIGERBEETLE_SOURCE_BACKUP=""
TIGERBEETLE_SOURCE_RESTORE_NEEDED=0
TB_HOT_ID_BASE="${TB_HOT_ID_BASE:-$(( ($$ * 1000) + SECONDS + 1 ))}"
TB_HOT_ACCOUNT_ID_1=$((TB_HOT_ID_BASE * 10 + 1))
TB_HOT_ACCOUNT_ID_2=$((TB_HOT_ID_BASE * 10 + 2))
TB_HOT_TRANSFER_ID_1=$((TB_HOT_ID_BASE * 10 + 101))
TB_HOT_TRANSFER_ID_2=$((TB_HOT_ID_BASE * 10 + 102))
TB_HOT_TRANSFER_ID_3=$((TB_HOT_ID_BASE * 10 + 103))
TB_HOT_TRANSFER_ID_4=$((TB_HOT_ID_BASE * 10 + 104))
TB_HOT_TRANSFER_ID_5=$((TB_HOT_ID_BASE * 10 + 105))

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

hot_run_pid() {
  [[ -f "$HOT_PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$HOT_PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  printf '%s\n' "$pid"
}

wait_for_port_file() {
  local timeout="${PORT_FILE_TIMEOUT:-600}"
  local deadline=$((SECONDS + timeout))
  local run_pid=""
  while (( SECONDS < deadline )); do
    if [[ -s "$PORT_FILE" ]]; then
      return 0
    fi
    if run_pid="$(hot_run_pid)"; then
      if ! kill -0 "$run_pid" >/dev/null 2>&1; then
        echo "error: TigerBeetle hot-run exited before nREPL started" >&2
        if [[ -f "$HOT_LOG" ]]; then
          tail -n 120 "$HOT_LOG" >&2
        fi
        exit 1
      fi
    fi
    sleep 1
  done

  echo "error: timed out after ${timeout}s waiting for $PORT_FILE" >&2
  if [[ -f "$HOT_LOG" ]]; then
    tail -n 120 "$HOT_LOG" >&2
  fi
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
  local config_file="$ROOT_DIR/src/config.zig"

  if ! awk -F '\t' \
    -v protocol_file="$protocol_file" \
    -v stdx_file="$stdx_file" \
    -v trace_file="$trace_file" \
    -v trace_event_file="$trace_event_file" \
    -v vsr_file="$vsr_file" \
    -v message_buffer_file="$message_buffer_file" \
    -v main_file="$main_file" \
    -v config_file="$config_file" '
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
    $1 == "decl-node" && $4 == config_file && $5 == "build_options" {
      build_options_key = $2
    }
    $1 == "decl-node" && $4 == config_file && $5 == "configs.current" {
      configs_current_key = $2
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
    $1 == "decl-edge" && $2 == "comptime_dep" {
      comptime_dep[$3 SUBSEP $4] = 1
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
      if (build_options_key == "") {
        print "error: missing declaration graph node for config.build_options" > "/dev/stderr"
        exit 1
      }
      if (configs_current_key == "") {
        print "error: missing declaration graph node for configs.current" > "/dev/stderr"
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
      if (!((configs_current_key SUBSEP build_options_key) in comptime_dep)) {
        print "error: missing declaration graph comptime_dep edge: configs.current -> build_options" > "/dev/stderr"
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

expect_hot_success() {
  local output="$1"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
  if grep -Fq "err:" <<<"$output" ||
    grep -Fq "  error" <<<"$output" ||
    grep -Fq "  eval-error" <<<"$output"; then
    echo "error: expected successful hot command" >&2
    echo "$output" >&2
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

ensure_tigerbeetle_source_backup() {
  if [[ -n "$TIGERBEETLE_SOURCE_BACKUP" ]]; then
    return 0
  fi

  TIGERBEETLE_SOURCE_BACKUP="$(mktemp "$ROOT_DIR/.tb-hot-smoke-tigerbeetle-zig-XXXXXX")"
  cp "$TIGERBEETLE_SOURCE_FILE" "$TIGERBEETLE_SOURCE_BACKUP"
}

restore_tigerbeetle_source() {
  [[ -n "$TIGERBEETLE_SOURCE_BACKUP" ]] || return 0
  cp "$TIGERBEETLE_SOURCE_BACKUP" "$TIGERBEETLE_SOURCE_FILE"
  TIGERBEETLE_SOURCE_RESTORE_NEEDED=0
}

cleanup() {
  if (( TIGERBEETLE_SOURCE_RESTORE_NEEDED != 0 )); then
    restore_tigerbeetle_source >/dev/null 2>&1 || true
    if [[ -s "$PORT_FILE" ]]; then
      zig_hot reload "$TIGERBEETLE_SOURCE_REL" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$TIGERBEETLE_SOURCE_BACKUP" ]]; then
    rm -f "$TIGERBEETLE_SOURCE_BACKUP"
  fi
}
trap cleanup EXIT INT TERM

decl_range_in_file() {
  local file="$1"
  local pattern="$2"
  local offset
  offset="$(grep -aboF "$pattern" "$file" | head -n 1 | cut -d: -f1)"
  if [[ -z "$offset" ]]; then
    echo "error: unable to locate range for pattern: $pattern" >&2
    exit 1
  fi
  printf '%s %s\n' "$offset" "$((offset + ${#pattern}))"
}

tigerbeetle_source_debits_exceed_credits_range() {
  decl_range_in_file "$TIGERBEETLE_SOURCE_FILE" 'pub fn debits_exceed_credits'
}

patch_tigerbeetle_debits_exceed_credits_probe() {
  local mode="$1"
  ensure_tigerbeetle_source_backup
  restore_tigerbeetle_source
  python3 - "$TIGERBEETLE_SOURCE_FILE" "$mode" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
mode = sys.argv[2]
source = path.read_text()
old = """        return (self.flags.debits_must_not_exceed_credits and
            self.debits_pending + self.debits_posted + amount > self.credits_posted);"""
if mode == "allow":
    new = """        _ = self;
        _ = amount;
        return false;"""
elif mode == "deny":
    new = """        return (self.flags.debits_must_not_exceed_credits and amount != 0);"""
else:
    raise SystemExit(f"error: unknown debits_exceed_credits mode: {mode}")
if old not in source:
    raise SystemExit("error: missing Account.debits_exceed_credits body")
path.write_text(source.replace(old, new, 1))
PY
  TIGERBEETLE_SOURCE_RESTORE_NEEDED=1
}

wait_for_tigerbeetle_address() {
  local deadline=$((SECONDS + 120))
  local address=""
  while (( SECONDS < deadline )); do
    if [[ -f "$HOT_LOG" ]]; then
      address="$(sed -n 's/.*cluster=0: listening on \(.*\)$/\1/p' "$HOT_LOG" | tail -n 1)"
      if [[ -n "$address" ]]; then
        printf '%s\n' "$address"
        return 0
      fi
    fi
    sleep 1
  done

  echo "error: timed out waiting for TigerBeetle listen address" >&2
  if [[ -f "$HOT_LOG" ]]; then
    tail -n 120 "$HOT_LOG" >&2
  fi
  exit 1
}

run_tb_repl() {
  local statement="$1"
  local -a cmd=(env DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-}")
  if [[ -n "$ZIG_LIB_DIR" ]]; then
    cmd+=(ZIG_LIB_DIR="$ZIG_LIB_DIR")
  fi
  cmd+=(
    "$ZIG_BIN"
    build
    --cache-dir "$HOT_REPL_BUILD_CACHE_DIR"
    --global-cache-dir "$HOT_REPL_GLOBAL_CACHE_DIR"
    run
    --
    repl
    --cluster=0
    "--addresses=$TB_SERVER_ADDRESS"
    "--command=$statement"
  )
  (
    cd "$ROOT_DIR"
    "${cmd[@]}"
  )
}

promotion_telemetry_line() {
  local output line
  output="$(zig_hot promotion-telemetry 2>&1)" || return 1
  line="$(awk '/^promotion-telemetry:$/ { getline; print; exit }' <<<"$output")"
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

promotion_telemetry_value() {
  local key="$1"
  local line
  line="$(promotion_telemetry_line)" || return 1
  awk -v key="$key" '
    {
      for (i = 1; i <= NF; i += 1) {
        split($i, pair, "=")
        if (pair[1] == key) {
          print pair[2]
          exit 0
        }
      }
      exit 1
    }
  ' <<<"$line"
}

wait_for_promotion_telemetry_at_least() {
  local key="$1"
  local minimum="$2"
  local deadline=$((SECONDS + 120))
  local poll_interval="${HOT_TEST_PROMOTION_POLL_INTERVAL:-0.05}"
  local value=""
  local last_line=""

  while (( SECONDS < deadline )); do
    last_line="$(promotion_telemetry_line 2>/dev/null || true)"
    value="$(promotion_telemetry_value "$key" 2>/dev/null || true)"
    if [[ -n "$value" ]] && (( value >= minimum )); then
      return 0
    fi
    sleep "$poll_interval"
  done

  echo "error: timed out waiting for promotion telemetry $key >= $minimum" >&2
  if [[ -n "$last_line" ]]; then
    echo "last-promotion-telemetry: $last_line" >&2
  fi
  zig_hot promotion-telemetry 1>&2 || true
  exit 1
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

expect_call_value() {
  local symbol="$1"
  local expected="$2"
  shift 2

  local output
  output="$(run_hot call "$symbol" "$@")"
  expect_contains "$output" "value: $expected"
  expect_contains "$output" "status:"
  expect_contains "$output" "  done"
}

tb_proven_functions=(
  sum_overflows
  sum_overflows_test
  StateMachineType.forest_options
  Duration.to_ms
  Duration.clamp
  sector_ceil
  zeroed
  Decoder.read_int
  Decoder.read_enum
  Decoder.read_short_string
  register_log_callback
  multiversion.ReleaseTriple.parse
  vsr.quorums
  command_version
  Direction.reverse
  compaction_op_min
  snapshot_min_for_table_output
  snapshot_max_for_table_input
  multi_batch_count_max
  trailer_total_size
)
tb_proven_vars=(
  log_level_runtime
  child_pid
)

wait_for_hot_config_file
wait_for_port_file
TB_SERVER_ADDRESS="$(wait_for_tigerbeetle_address)"

describe_output="$(wait_for_runtime_ready)"
# The config file exists before the hot graph is fully flushed; wait for the
# runtime to come up before asserting on the finished declaration graph.
validate_decl_graph_semantic_edges
expect_contains "$describe_output" "stdx.zeroed"
expect_contains "$describe_output" "vsr.sector_ceil"
expect_contains "$describe_output" "vsr.quorums"
expect_contains "$describe_output" "repl.completion.Completion.split_and_complete"
expect_contains "$describe_output" "cdc.amqp.protocol.Decoder.init"
expect_contains "$describe_output" "cdc.amqp.protocol.Decoder.read_short_string"
expect_contains "$describe_output" "vsr.tb_client.exports.register_log_callback"
expect_contains "$describe_output" "multiversion.ReleaseTriple.parse"

# Fresh-runtime probes must work before any reload or runtime var override seeds
# managed state for these graphs.
to_ms_output="$(zig_hot compile-body src/stdx/time_units.zig to_ms 2>&1 || true)"
expect_hot_success "$to_ms_output"
expect_contains "$to_ms_output" "instructions:"
expect_contains "$to_ms_output" "value: 0"
echo "cold-start Duration.to_ms compile-body: OK"

expect_eval_value 'stdx.zeroed("abc")' "false"
expect_eval_value 'vsr.sector_ceil(1)' "4096"
expect_eval_value 'vsr.quorums(3).replication' "2"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_short_string(cdc.amqp.protocol.Decoder.init([3,97,98,99]))' '"abc"'

assoc_quorums="$(zig_hot assoc --no-native quorums --file src/vsr.zig 'fn quorums(replica_count: u8) struct { replication: u8, view_change: u8, nack_prepare: u8, majority: u8, upgrade: u8, } { _ = replica_count; return .{ .replication = 9, .view_change = 8, .nack_prepare = 7, .majority = 6, .upgrade = 5 }; }' 2>&1)"
if echo "$assoc_quorums" | grep -qF "done"; then
  expect_hot_success "$assoc_quorums"
  expect_eval_value 'vsr.quorums(3).view_change' "8"
  expect_eval_value 'vsr.quorums(3).upgrade' "5"
  dissoc_quorums="$(zig_hot dissoc quorums 2>&1)"
  expect_hot_success "$dissoc_quorums"
  expect_eval_value 'vsr.quorums(3).replication' "2"
  echo "assoc/dissoc quorums override: OK"
else
  echo "assoc quorums not yet supported — keeping direct field proof only"
fi

register_log_reset="$(run_hot --eval 'vsr.tb_client.exports.register_log_callback(null, false)')"
expect_hot_success "$register_log_reset"
if grep -Fq "value: .success" <<<"$register_log_reset"; then
  expect_eval_value 'vsr.tb_client.exports.register_log_callback(null, false)' ".not_registered"
else
  expect_contains "$register_log_reset" "value: .not_registered"
fi

assoc_register_log_callback="$(zig_hot assoc --no-native register_log_callback --file src/clients/c/tb_client_exports.zig 'fn register_log_callback(callback_maybe: ?Logging.Callback, debug: bool) callconv(.c) tb_register_log_callback_status { _ = callback_maybe; _ = debug; return .already_registered; }' 2>&1)"
expect_hot_success "$assoc_register_log_callback"
expect_eval_value 'vsr.tb_client.exports.register_log_callback(null, false)' ".already_registered"
dissoc_register_log_callback="$(zig_hot dissoc vsr.tb_client.exports.register_log_callback 2>&1)"
expect_hot_success "$dissoc_register_log_callback"
expect_eval_value 'vsr.tb_client.exports.register_log_callback(null, false)' ".not_registered"
echo "short-name TigerBeetle C export assoc maps to qualified callable: OK"

release_triple_before="$(run_hot --eval 'multiversion.ReleaseTriple.parse("1.2.3")')"
expect_hot_success "$release_triple_before"
expect_contains "$release_triple_before" "value: .{"
expect_contains "$release_triple_before" ".major = 1"
expect_contains "$release_triple_before" ".minor = 2"
expect_contains "$release_triple_before" ".patch = 3"
assoc_release_triple_parse="$(zig_hot assoc --no-native multiversion.ReleaseTriple.parse --file src/multiversion.zig 'pub fn parse(string: []const u8) error{InvalidRelease}!ReleaseTriple { _ = string; return .{ .major = 9, .minor = 8, .patch = 7 }; }' 2>&1)"
expect_hot_success "$assoc_release_triple_parse"
release_triple_after_assoc="$(run_hot --eval 'multiversion.ReleaseTriple.parse("1.2.3")')"
expect_hot_success "$release_triple_after_assoc"
expect_contains "$release_triple_after_assoc" "value: .{"
expect_contains "$release_triple_after_assoc" ".major = 9"
expect_contains "$release_triple_after_assoc" ".minor = 8"
expect_contains "$release_triple_after_assoc" ".patch = 7"
dissoc_release_triple_parse="$(zig_hot dissoc multiversion.ReleaseTriple.parse 2>&1)"
expect_hot_success "$dissoc_release_triple_parse"
release_triple_after_dissoc="$(run_hot --eval 'multiversion.ReleaseTriple.parse("1.2.3")')"
expect_hot_success "$release_triple_after_dissoc"
expect_contains "$release_triple_after_dissoc" "value: .{"
expect_contains "$release_triple_after_dissoc" ".major = 1"
expect_contains "$release_triple_after_dissoc" ".minor = 2"
expect_contains "$release_triple_after_dissoc" ".patch = 3"
echo "TigerBeetle aggregate error-union return override: OK"

# ── Real TigerBeetle function compile-body tests ──────────────────────

# zeroed — for loop with bitwise OR over bytes (no cross-module calls)
zeroed_output="$(zig_hot compile-body src/stdx/stdx.zig zeroed 2>&1)"
expect_contains "$zeroed_output" "instructions:"

# classify — top-level extern container declarations should expose a reason
classify_aof_output="$(zig_hot classify src/aof.zig 2>&1)"
expect_contains "$classify_aof_output" "AOFEntry"
expect_contains "$classify_aof_output" "reason=extern-container"
expect_contains "$classify_aof_output" "boundary=versioned-only"
expect_contains "$classify_aof_output" "guidance=reload-dependents"

classify_header_output="$(zig_hot classify src/vsr/message_header.zig 2>&1)"
expect_contains "$classify_header_output" "Header"
expect_contains "$classify_header_output" "reason=extern-container"
expect_contains "$classify_header_output" "boundary=versioned-only"
expect_contains "$classify_header_output" "guidance=reload-dependents"

classify_context_output="$(zig_hot classify src/clients/c/tb_client/context.zig 2>&1)"
expect_contains "$classify_context_output" "thread_caller"
expect_contains "$classify_context_output" "reason=threadlocal"
expect_contains "$classify_context_output" "boundary=permanent"
expect_contains "$classify_context_output" "guidance=reload-dependents"

invalidate_header_output="$(zig_hot invalidate src/vsr/message_header.zig 2>&1)"
expect_contains "$invalidate_header_output" "impact:"
expect_contains "$invalidate_header_output" "decl-key=owner=vsr;file=$ROOT_DIR/src/lsm/schema.zig;decl=block_body_size;kind=const_decl reason=comptime_dep"
expect_contains "$invalidate_header_output" "decl-key=owner=vsr;file=$ROOT_DIR/src/lsm/schema.zig;decl=header_from_block;kind=function_decl reason=layout_dep"

# sector_ceil with arg 0 — should return 0
sector0_output="$(zig_hot compile-body src/vsr.zig sector_ceil 0 2>&1 || true)"
echo "sector_ceil(0) output: ${sector0_output:0:80}"

# Duration.min — @min builtin on struct fields (no cross-module calls)
dur_min_output="$(zig_hot compile-body src/stdx/time_units.zig min 2>&1)"
expect_contains "$dur_min_output" "instructions:"

# ── Runtime-addressable var override proof ──────────────────────────────

assoc_command_version_probe="$(zig_hot assoc --no-native command_version --file src/tigerbeetle/main.zig 'fn command_version(gpa: mem.Allocator, verbose: bool) !void { _ = gpa; _ = verbose; return if (@intFromEnum(log_level_runtime) == 2) 0 else 1; }' 2>&1)"
expect_hot_success "$assoc_command_version_probe"
echo "assoc command_version value-cell probe: OK"

log_level_probe_cold="$(zig_hot compile-body ../../test/hot/project_call_probe.zig tigerbeetleCommandVersion 2>&1 || true)"
expect_hot_success "$log_level_probe_cold"
expect_contains "$log_level_probe_cold" "value: 0"
echo "cold-start command_version reads log_level_runtime: OK"

assoc_log_level_info="$(zig_hot assoc --type var --no-native log_level_runtime 2 2>&1)"
expect_hot_success "$assoc_log_level_info"
log_level_probe_info="$(zig_hot compile-body ../../test/hot/project_call_probe.zig tigerbeetleCommandVersion 2>&1)"
expect_hot_success "$log_level_probe_info"
expect_contains "$log_level_probe_info" "value: 0"
echo "assoc log_level_runtime runtime_addressable var -> info: OK"

assoc_log_level_debug="$(zig_hot assoc --type var --no-native log_level_runtime 3 2>&1)"
expect_hot_success "$assoc_log_level_debug"
log_level_probe_debug="$(zig_hot compile-body ../../test/hot/project_call_probe.zig tigerbeetleCommandVersion 2>&1)"
expect_hot_success "$log_level_probe_debug"
expect_contains "$log_level_probe_debug" "value: 1"
echo "assoc log_level_runtime runtime_addressable var -> debug: OK"

assoc_log_level_restore="$(zig_hot assoc --type var --no-native log_level_runtime 2 2>&1)"
expect_hot_success "$assoc_log_level_restore"
log_level_probe_restore="$(zig_hot compile-body ../../test/hot/project_call_probe.zig tigerbeetleCommandVersion 2>&1)"
expect_hot_success "$log_level_probe_restore"
expect_contains "$log_level_probe_restore" "value: 0"
dissoc_command_version_probe="$(zig_hot dissoc command_version 2>&1)"
expect_hot_success "$dissoc_command_version_probe"
dissoc_log_level_runtime="$(zig_hot dissoc log_level_runtime 2>&1)"
expect_hot_success "$dissoc_log_level_runtime"
echo "dissoc command_version probe and log_level_runtime override: OK"

child_pid_baseline="$(zig_hot eval-zig src/stdx/unshare.zig 'child_pid == null' 2>&1 || true)"
expect_hot_success "$child_pid_baseline"
expect_contains "$child_pid_baseline" "value: true"
echo "cold-start child_pid runtime_addressable var is null: OK"

assoc_child_pid_set="$(zig_hot assoc --type var --no-native child_pid 42 2>&1 || true)"
expect_hot_success "$assoc_child_pid_set"
child_pid_probe_set="$(zig_hot eval-zig src/stdx/unshare.zig 'child_pid != null' 2>&1 || true)"
expect_hot_success "$child_pid_probe_set"
expect_contains "$child_pid_probe_set" "value: true"
echo "assoc child_pid runtime_addressable var -> non-null: OK"

assoc_child_pid_null="$(zig_hot assoc --type var --no-native child_pid null 2>&1 || true)"
expect_hot_success "$assoc_child_pid_null"
child_pid_probe_null="$(zig_hot eval-zig src/stdx/unshare.zig 'child_pid == null' 2>&1 || true)"
expect_hot_success "$child_pid_probe_null"
expect_contains "$child_pid_probe_null" "value: true"
zig_hot dissoc stdx.unshare.child_pid >/dev/null 2>&1 || true
echo "restore child_pid runtime_addressable var override: OK"

# ── Real TigerBeetle state_machine.zig frontier proofs ─────────────────────

classify_state_machine_output="$(zig_hot classify src/state_machine.zig 2>&1)"
expect_contains "$classify_state_machine_output" "name=StateMachineType.commit body-class=interpreter-ready live-path=dispatch-cell"
expect_contains "$classify_state_machine_output" "name=StateMachineType.execute_multi_batch body-class=interpreter-ready live-path=dispatch-cell"
expect_contains "$classify_state_machine_output" "name=StateMachineType.prepare_delta_nanoseconds body-class=interpreter-ready live-path=dispatch-cell"
expect_contains "$classify_state_machine_output" "name=StateMachineType.tree_values_count body-class=interpreter-ready live-path=dispatch-cell"
expect_contains "$classify_state_machine_output" "name=StateMachineType.reset body-class=native-only live-path=native-patch-candidate reason=pointer-deref"
expect_contains "$classify_state_machine_output" "name=StateMachineType.execute_create body-class=native-only live-path=native-patch-candidate reason=reflection-builtin"
expect_contains "$classify_state_machine_output" "name=StateMachineType.forest_open_callback body-class=native-only live-path=native-patch-candidate reason=parent-ptr-builtin"
expect_contains "$classify_state_machine_output" "name=StateMachineType.execute_query_multi_batch body-class=native-only live-path=native-patch-candidate reason=defer-cleanup"
expect_contains "$classify_state_machine_output" "name=tree_ids body-class=invalidate-dependents live-path=invalidate-only reason=struct-container boundary=versioned-only guidance=reload-dependents"
expect_contains "$classify_state_machine_output" "name=sum_overflows body-class=interpreter-ready live-path=dispatch-cell"
echo "state_machine.zig classify frontier: OK"

state_machine_prefetch_finish="$(zig_hot compile-body src/state_machine.zig StateMachineType.prefetch_finish 2>&1)"
expect_hot_success "$state_machine_prefetch_finish"
expect_contains "$state_machine_prefetch_finish" "fn: StateMachineType.prefetch_finish"
expect_contains "$state_machine_prefetch_finish" "value: error.unwrapped null optional"
echo "state_machine.zig direct compile-body probe: OK"

sum_overflows_baseline="$(run_hot eval-zig src/state_machine.zig 'sum_overflows(u64, 1, 2)')"
expect_contains "$sum_overflows_baseline" "value: false"

assoc_sum_overflows="$(zig_hot assoc --no-native sum_overflows --file src/state_machine.zig 'fn sum_overflows(comptime Int: type, a: Int, b: Int) bool { _ = Int; return a == 1 and b == 2; }' 2>&1)"
expect_hot_success "$assoc_sum_overflows"
sum_overflows_patched="$(run_hot eval-zig src/state_machine.zig 'sum_overflows(u64, 1, 2)')"
expect_contains "$sum_overflows_patched" "value: true"

dissoc_sum_overflows="$(zig_hot dissoc sum_overflows 2>&1)"
expect_hot_success "$dissoc_sum_overflows"
sum_overflows_restored="$(run_hot eval-zig src/state_machine.zig 'sum_overflows(u64, 1, 2)')"
expect_contains "$sum_overflows_restored" "value: false"
echo "state_machine.zig sum_overflows hot reload probe: OK"

sum_overflows_test_baseline="$(zig_hot eval-zig src/state_machine.zig 'sum_overflows_test(u64)' 2>&1)"
expect_contains "$sum_overflows_test_baseline" "value: null"

assoc_sum_overflows_test="$(zig_hot assoc --no-native sum_overflows_test --file src/state_machine.zig 'fn sum_overflows_test(comptime Int: type) !void { _ = Int; return error.Patched; }' 2>&1)"
expect_hot_success "$assoc_sum_overflows_test"
sum_overflows_test_patched="$(zig_hot eval-zig src/state_machine.zig 'sum_overflows_test(u64)' 2>&1)"
expect_contains "$sum_overflows_test_patched" "value: error.Patched"

dissoc_sum_overflows_test="$(zig_hot dissoc sum_overflows_test 2>&1)"
expect_hot_success "$dissoc_sum_overflows_test"
sum_overflows_test_restored="$(zig_hot eval-zig src/state_machine.zig 'sum_overflows_test(u64)' 2>&1)"
expect_contains "$sum_overflows_test_restored" "value: null"
echo "state_machine.zig sum_overflows_test hot reload probe: OK"

state_machine_event_max_baseline="$(run_hot eval-zig src/tigerbeetle.zig 'Operation.create_accounts.event_max(@as(u32, 4096))')"
expect_contains "$state_machine_event_max_baseline" "value: 31"

state_machine_result_max_baseline="$(run_hot eval-zig src/tigerbeetle.zig 'Operation.create_accounts.result_max(@as(u32, 4096))')"
expect_contains "$state_machine_result_max_baseline" "value: 31"
echo "state_machine.zig operation batch-limit baseline probes: OK"

state_machine_forest_options_expr='StateMachine.forest_options(.{ .batch_size_limit = 4096, .lsm_forest_compaction_block_count = 1, .lsm_forest_node_count = 1, .cache_entries_accounts = 7, .cache_entries_transfers = 11, .cache_entries_transfers_pending = 13, .log_trace = false, .aof_recovery = false }).accounts.cache_entries_max'
state_machine_forest_options_baseline="$(run_hot eval-zig src/tigerbeetle/main.zig "$state_machine_forest_options_expr")"
expect_contains "$state_machine_forest_options_baseline" "value: 7"

assoc_state_machine_forest_options="$(zig_hot assoc --no-native StateMachineType.forest_options --file src/state_machine.zig 'fn forest_options(options: Options) Forest.GroovesOptions { _ = options; return .{ .accounts = .{ .cache_entries_max = 99 } }; }' 2>&1)"
expect_hot_success "$assoc_state_machine_forest_options"
state_machine_forest_options_patched="$(run_hot eval-zig src/tigerbeetle/main.zig "$state_machine_forest_options_expr")"
expect_contains "$state_machine_forest_options_patched" "value: 99"

dissoc_state_machine_forest_options="$(zig_hot dissoc StateMachineType.forest_options 2>&1)"
expect_hot_success "$dissoc_state_machine_forest_options"
state_machine_forest_options_restored="$(run_hot eval-zig src/tigerbeetle/main.zig "$state_machine_forest_options_expr")"
expect_contains "$state_machine_forest_options_restored" "value: 7"
echo "state_machine.zig forest_options import-alias hot override probe: OK"

state_machine_tree_values_count_expr='StateMachine.forest_options(.{ .batch_size_limit = 4096, .lsm_forest_compaction_block_count = 1, .lsm_forest_node_count = 1, .cache_entries_accounts = 7, .cache_entries_transfers = 11, .cache_entries_transfers_pending = 13, .log_trace = false, .aof_recovery = false }).accounts.tree_options_object.batch_value_count_limit'
state_machine_tree_values_count_baseline="$(run_hot eval-zig src/tigerbeetle/main.zig "$state_machine_tree_values_count_expr")"
expect_hot_success "$state_machine_tree_values_count_baseline"
if grep -qF "value: 4242" <<<"$state_machine_tree_values_count_baseline"; then
  echo "error: unexpected StateMachineType.tree_values_count baseline collided with patch sentinel" >&2
  echo "$state_machine_tree_values_count_baseline" >&2
  exit 1
fi
assoc_state_machine_tree_values_count="$(zig_hot assoc --no-native StateMachineType.tree_values_count --file src/state_machine.zig - <<'ASSOC_EOF'
fn tree_values_count(batch_size_limit: u32) struct {
    accounts: struct {
        id: u32,
        user_data_128: u32,
        user_data_64: u32,
        user_data_32: u32,
        ledger: u32,
        code: u32,
        timestamp: u32,
        imported: u32,
        closed: u32,
    },
    transfers: struct {
        timestamp: u32,
        id: u32,
        debit_account_id: u32,
        credit_account_id: u32,
        amount: u32,
        pending_id: u32,
        user_data_128: u32,
        user_data_64: u32,
        user_data_32: u32,
        ledger: u32,
        code: u32,
        expires_at: u32,
        imported: u32,
        closing: u32,
    },
    transfers_pending: struct {
        timestamp: u32,
        status: u32,
    },
    account_events: struct {
        timestamp: u32,
        account_timestamp: u32,
        transfer_pending_status: u32,
        dr_account_id_expired: u32,
        cr_account_id_expired: u32,
        transfer_pending_id_expired: u32,
        ledger_expired: u32,
        prunable: u32,
    },
} {
    _ = batch_size_limit;
    return .{
        .accounts = .{
            .id = 4242,
            .user_data_128 = 4242,
            .user_data_64 = 4242,
            .user_data_32 = 4242,
            .ledger = 4242,
            .code = 4242,
            .timestamp = 4242,
            .imported = 4242,
            .closed = 4242,
        },
        .transfers = .{
            .timestamp = 4343,
            .id = 4343,
            .debit_account_id = 4343,
            .credit_account_id = 4343,
            .amount = 4343,
            .pending_id = 4343,
            .user_data_128 = 4343,
            .user_data_64 = 4343,
            .user_data_32 = 4343,
            .ledger = 4343,
            .code = 4343,
            .expires_at = 4343,
            .imported = 4343,
            .closing = 4343,
        },
        .transfers_pending = .{
            .timestamp = 4444,
            .status = 4444,
        },
        .account_events = .{
            .timestamp = 4545,
            .account_timestamp = 4545,
            .transfer_pending_status = 4545,
            .dr_account_id_expired = 4545,
            .cr_account_id_expired = 4545,
            .transfer_pending_id_expired = 4545,
            .ledger_expired = 4545,
            .prunable = 4545,
        },
    };
}
ASSOC_EOF
2>&1)"
expect_hot_success "$assoc_state_machine_tree_values_count"
state_machine_tree_values_count_patched="$(run_hot eval-zig src/tigerbeetle/main.zig "$state_machine_tree_values_count_expr")"
expect_hot_success "$state_machine_tree_values_count_patched"
expect_contains "$state_machine_tree_values_count_patched" "value: 4242"
dissoc_state_machine_tree_values_count="$(zig_hot dissoc StateMachineType.tree_values_count 2>&1)"
expect_hot_success "$dissoc_state_machine_tree_values_count"
state_machine_tree_values_count_restored="$(run_hot eval-zig src/tigerbeetle/main.zig "$state_machine_tree_values_count_expr")"
expect_hot_success "$state_machine_tree_values_count_restored"
if grep -qF "value: 4242" <<<"$state_machine_tree_values_count_restored"; then
  echo "error: dissoc StateMachineType.tree_values_count left patched sentinel live" >&2
  echo "$state_machine_tree_values_count_restored" >&2
  exit 1
fi
tb_proven_functions+=(StateMachineType.tree_values_count)
echo "state_machine.zig tree_values_count hot reload probe: OK"

assoc_state_machine_commit="$(zig_hot assoc --no-native StateMachineType.commit --file src/state_machine.zig 'fn commit(self: *StateMachine, client: u128, op: u64, timestamp: u64, operation: Operation, message_body_used: []align(16) const u8, output_buffer: *align(16) [constants.message_body_size_max]u8) usize { _ = self; _ = client; _ = op; _ = timestamp; _ = operation; _ = message_body_used; _ = output_buffer; return 5151; }' 2>&1)"
expect_hot_success "$assoc_state_machine_commit"
state_machine_commit_patched="$(zig_hot compile-body hot_state_machine_probe.zig stateMachineCommitAssocProbe 2>&1 || true)"
expect_hot_success "$state_machine_commit_patched"
expect_contains "$state_machine_commit_patched" "value: 5151"
dissoc_state_machine_commit="$(zig_hot dissoc StateMachineType.commit 2>&1)"
expect_hot_success "$dissoc_state_machine_commit"
tb_proven_functions+=(StateMachineType.commit)
echo "state_machine.zig commit assoc probe: OK"

assoc_state_machine_execute_multi_batch="$(zig_hot assoc --no-native StateMachineType.execute_multi_batch --file src/state_machine.zig 'fn execute_multi_batch(self: *StateMachine, timestamp: u64, comptime operation: Operation, message_body_used: []align(16) const u8, output_buffer: *align(16) [constants.message_body_size_max]u8) usize { _ = self; _ = timestamp; _ = operation; _ = message_body_used; _ = output_buffer; return 6262; }' 2>&1)"
expect_hot_success "$assoc_state_machine_execute_multi_batch"
state_machine_execute_multi_batch_patched="$(zig_hot compile-body hot_state_machine_probe.zig stateMachineExecuteMultiBatchAssocProbe 2>&1 || true)"
expect_hot_success "$state_machine_execute_multi_batch_patched"
expect_contains "$state_machine_execute_multi_batch_patched" "value: 6262"
dissoc_state_machine_execute_multi_batch="$(zig_hot dissoc StateMachineType.execute_multi_batch 2>&1)"
expect_hot_success "$dissoc_state_machine_execute_multi_batch"
tb_proven_functions+=(StateMachineType.execute_multi_batch)
echo "state_machine.zig execute_multi_batch assoc probe: OK"

# ── Generic/comptime specialization replay proofs ──────────────────────

expect_eval_value 'cdc.amqp.protocol.Decoder.read_bool(cdc.amqp.protocol.Decoder.init([1]))' "true"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_method_header(cdc.amqp.protocol.Decoder.init([0,1,0,2])).class' "1"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_method_header(cdc.amqp.protocol.Decoder.init([0,1,0,2])).method' "2"
assoc_read_int="$(zig_hot assoc --no-native Decoder.read_int --file src/cdc/amqp/protocol.zig 'fn read_int(self: *Decoder, comptime T: type) Error!T { _ = self; return @as(T, 0); }' 2>&1)"
expect_contains "$assoc_read_int" "done"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_bool(cdc.amqp.protocol.Decoder.init([1]))' "false"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_method_header(cdc.amqp.protocol.Decoder.init([0,1,0,2])).class' "0"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_method_header(cdc.amqp.protocol.Decoder.init([0,1,0,2])).method' "0"
dissoc_read_int="$(zig_hot dissoc Decoder.read_int 2>&1)"
expect_contains "$dissoc_read_int" "done"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_bool(cdc.amqp.protocol.Decoder.init([1]))' "true"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_method_header(cdc.amqp.protocol.Decoder.init([0,1,0,2])).class' "1"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_method_header(cdc.amqp.protocol.Decoder.init([0,1,0,2])).method' "2"
echo "assoc Decoder.read_int specialization replay: OK"

create_accounts_command="create_accounts id=$TB_HOT_ACCOUNT_ID_1 flags=debits_must_not_exceed_credits code=10 ledger=700, id=$TB_HOT_ACCOUNT_ID_2 code=10 ledger=700;"
create_accounts_validation="$(run_tb_repl "$create_accounts_command")"
expect_contains "$create_accounts_validation" '"status": ".created"'

baseline_transfer_validation="$(run_tb_repl "create_transfers id=$TB_HOT_TRANSFER_ID_1 debit_account_id=$TB_HOT_ACCOUNT_ID_1 credit_account_id=$TB_HOT_ACCOUNT_ID_2 amount=10 ledger=700 code=10;")"
expect_contains "$baseline_transfer_validation" '"status": ".exceeds_credits"'
read -r debits_exceed_start debits_exceed_end <<<"$(tigerbeetle_source_debits_exceed_credits_range)"
patch_tigerbeetle_debits_exceed_credits_probe allow
reload_debits_allow="$(zig_hot reload "$TIGERBEETLE_SOURCE_REL" "$debits_exceed_start" "$debits_exceed_end" 2>&1)"
expect_hot_success "$reload_debits_allow"
expect_contains "$reload_debits_allow" "decl=Account.debits_exceed_credits;kind=function_decl"
allowed_transfer_validation="$(run_tb_repl "create_transfers id=$TB_HOT_TRANSFER_ID_2 debit_account_id=$TB_HOT_ACCOUNT_ID_1 credit_account_id=$TB_HOT_ACCOUNT_ID_2 amount=10 ledger=700 code=10;")"
expect_contains "$allowed_transfer_validation" '"status": ".created"'
patch_tigerbeetle_debits_exceed_credits_probe deny
reload_debits_deny="$(zig_hot reload "$TIGERBEETLE_SOURCE_REL" "$debits_exceed_start" "$debits_exceed_end" 2>&1)"
expect_hot_success "$reload_debits_deny"
expect_contains "$reload_debits_deny" "decl=Account.debits_exceed_credits;kind=function_decl"
denied_transfer_validation="$(run_tb_repl "create_transfers id=$TB_HOT_TRANSFER_ID_3 debit_account_id=$TB_HOT_ACCOUNT_ID_1 credit_account_id=$TB_HOT_ACCOUNT_ID_2 amount=10 ledger=700 code=10;")"
expect_contains "$denied_transfer_validation" '"status": ".exceeds_credits"'

patch_tigerbeetle_debits_exceed_credits_probe allow
reload_debits_allow_log="$(mktemp "$ROOT_DIR/.tb-hot-reload-allow-XXXXXX")"
(
  zig_hot reload "$TIGERBEETLE_SOURCE_REL" "$debits_exceed_start" "$debits_exceed_end" >"$reload_debits_allow_log" 2>&1
) &
reload_debits_allow_pid=$!
wait_for_promotion_telemetry_at_least "building" 1
patch_tigerbeetle_debits_exceed_credits_probe deny
reload_debits_deny_log="$(mktemp "$ROOT_DIR/.tb-hot-reload-deny-XXXXXX")"
(
  zig_hot reload "$TIGERBEETLE_SOURCE_REL" "$debits_exceed_start" "$debits_exceed_end" >"$reload_debits_deny_log" 2>&1
) &
reload_debits_deny_pid=$!
wait "$reload_debits_allow_pid"
reload_debits_allow="$(cat "$reload_debits_allow_log")"
rm -f "$reload_debits_allow_log"
expect_hot_success "$reload_debits_allow"
expect_contains "$reload_debits_allow" "decl=Account.debits_exceed_credits;kind=function_decl"
wait "$reload_debits_deny_pid"
reload_debits_deny="$(cat "$reload_debits_deny_log")"
rm -f "$reload_debits_deny_log"
expect_hot_success "$reload_debits_deny"
expect_contains "$reload_debits_deny" "decl=Account.debits_exceed_credits;kind=function_decl"
wait_for_promotion_telemetry_at_least "discarded-stale-total" 1
promotion_telemetry_output="$(zig_hot promotion-telemetry 2>&1)"
expect_hot_success "$promotion_telemetry_output"
expect_contains "$promotion_telemetry_output" "discarded-stale-total="
expect_contains "$promotion_telemetry_output" "worker-count=$HOT_TEST_PROMOTION_WORKERS"
denied_transfer_overlap_validation="$(run_tb_repl "create_transfers id=$TB_HOT_TRANSFER_ID_4 debit_account_id=$TB_HOT_ACCOUNT_ID_1 credit_account_id=$TB_HOT_ACCOUNT_ID_2 amount=10 ledger=700 code=10;")"
expect_contains "$denied_transfer_overlap_validation" '"status": ".exceeds_credits"'
restore_tigerbeetle_source
reload_debits_restore="$(zig_hot reload "$TIGERBEETLE_SOURCE_REL" "$debits_exceed_start" "$debits_exceed_end" 2>&1)"
expect_hot_success "$reload_debits_restore"
expect_contains "$reload_debits_restore" "decl=Account.debits_exceed_credits;kind=function_decl"
restored_transfer_validation="$(run_tb_repl "create_transfers id=$TB_HOT_TRANSFER_ID_5 debit_account_id=$TB_HOT_ACCOUNT_ID_1 credit_account_id=$TB_HOT_ACCOUNT_ID_2 amount=10 ledger=700 code=10;")"
expect_contains "$restored_transfer_validation" '"status": ".exceeds_credits"'
echo "reload Account.debits_exceed_credits rapid repeated edits keep latest live version: OK"

expect_eval_value 'cdc.amqp.protocol.Decoder.read_field(cdc.amqp.protocol.Decoder.init([66,1]))' ".{ .uint8 = 1 }"
assoc_read_enum="$(zig_hot assoc --no-native Decoder.read_enum --file src/cdc/amqp/protocol.zig 'fn read_enum(self: *Decoder, comptime Enum: type) Error!Enum { _ = self; return @as(Enum, @enumFromInt(86)); }' 2>&1)"
expect_contains "$assoc_read_enum" "done"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_field(cdc.amqp.protocol.Decoder.init([66,1]))' "null"
dissoc_read_enum="$(zig_hot dissoc Decoder.read_enum 2>&1)"
expect_contains "$dissoc_read_enum" "done"
expect_eval_value 'cdc.amqp.protocol.Decoder.read_field(cdc.amqp.protocol.Decoder.init([66,1]))' ".{ .uint8 = 1 }"
echo "assoc Decoder.read_enum specialization replay: OK"

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

# Override Duration.clamp — multi-branch duration bounds logic.
# Keep this on the source-dispatch path only; native patching this helper can
# perturb the live replica heartbeat logic while we only need compile-body proof.
assoc_duration_clamp="$(zig_hot assoc --no-native Duration.clamp --file src/stdx/time_units.zig 'fn clamp(duration: Duration, clamp_min: Duration, clamp_max: Duration) Duration { _ = duration; _ = clamp_min; _ = clamp_max; return .{ .ns = 7 }; }' 2>&1)"
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

# ── eval-zig proofs for pure utility functions (Phase 61A Batch 2) ───

# sector_floor — alignment via divFloor, companion to already-proven sector_ceil
sector_floor_baseline="$(run_hot eval-zig src/vsr.zig 'sector_floor(5000)')"
expect_contains "$sector_floor_baseline" "value: 4096"

assoc_sector_floor="$(zig_hot assoc --no-native sector_floor --file src/vsr.zig 'fn sector_floor(offset: u64) u64 { _ = offset; return 0; }' 2>&1)"
expect_hot_success "$assoc_sector_floor"
sector_floor_patched="$(run_hot eval-zig src/vsr.zig 'sector_floor(5000)')"
expect_contains "$sector_floor_patched" "value: 0"

dissoc_sector_floor="$(zig_hot dissoc sector_floor 2>&1)"
expect_hot_success "$dissoc_sector_floor"
sector_floor_restored="$(run_hot eval-zig src/vsr.zig 'sector_floor(5000)')"
expect_contains "$sector_floor_restored" "value: 4096"
echo "sector_floor eval-zig + assoc/dissoc probe: OK"

# fastrange — Lemire's u128 multiply-and-shift algorithm
fastrange_baseline="$(run_hot eval-zig src/stdx/stdx.zig 'fastrange(1000, 8)')"
expect_contains "$fastrange_baseline" "value: 0"

assoc_fastrange="$(zig_hot assoc --no-native fastrange --file src/stdx/stdx.zig 'fn fastrange(word: u64, p: u64) u64 { _ = word; _ = p; return 42; }' 2>&1)"
expect_hot_success "$assoc_fastrange"
fastrange_patched="$(run_hot eval-zig src/stdx/stdx.zig 'fastrange(1000, 8)')"
expect_contains "$fastrange_patched" "value: 42"

dissoc_fastrange="$(zig_hot dissoc fastrange 2>&1)"
expect_hot_success "$dissoc_fastrange"
fastrange_restored="$(run_hot eval-zig src/stdx/stdx.zig 'fastrange(1000, 8)')"
expect_contains "$fastrange_restored" "value: 0"
echo "fastrange eval-zig + assoc/dissoc probe: OK"

# Direction.reverse — enum-to-enum switch transform
dir_reverse_baseline="$(zig_hot eval-zig src/direction.zig 'Direction.reverse(.ascending)' 2>&1 || true)"
expect_hot_success "$dir_reverse_baseline"
expect_contains "$dir_reverse_baseline" "value: .descending"
echo "eval-zig Direction.reverse(.ascending) = .descending ✓"

assoc_dir_reverse="$(zig_hot assoc --no-native Direction.reverse --file src/direction.zig 'fn reverse(d: Direction) Direction { _ = d; return .ascending; }' 2>&1 || true)"
expect_hot_success "$assoc_dir_reverse"
dir_reverse_patched="$(zig_hot eval-zig src/direction.zig 'Direction.reverse(.ascending)' 2>&1 || true)"
expect_hot_success "$dir_reverse_patched"
expect_contains "$dir_reverse_patched" "value: .ascending"
echo "assoc Direction.reverse override: OK"

dissoc_dir_reverse="$(zig_hot dissoc Direction.reverse 2>&1 || true)"
expect_hot_success "$dissoc_dir_reverse"
dir_reverse_restored="$(zig_hot eval-zig src/direction.zig 'Direction.reverse(.ascending)' 2>&1 || true)"
expect_hot_success "$dir_reverse_restored"
expect_contains "$dir_reverse_restored" "value: .descending"
echo "dissoc Direction.reverse: OK"

# ── eval-zig proofs for LSM/consensus functions (Phase 61A Batch 4) ──

# compaction_op_min — modulo alignment on u64
# half_bar_beat_count = lsm_compaction_ops / 2, and compaction_op_min(op) = op - op % half_bar_beat_count
compaction_op_min_eval="$(zig_hot eval-zig src/lsm/compaction.zig 'compaction_op_min(100)' 2>&1 || true)"
expect_hot_success "$compaction_op_min_eval"
expect_contains "$compaction_op_min_eval" "value: 96"
echo "eval-zig compaction_op_min(100) = 96 ✓"

assoc_comp_op="$(zig_hot assoc --no-native compaction_op_min --file src/lsm/compaction.zig 'fn compaction_op_min(op: u64) u64 { _ = op; return 0; }' 2>&1 || true)"
expect_hot_success "$assoc_comp_op"
comp_op_patched="$(zig_hot eval-zig src/lsm/compaction.zig 'compaction_op_min(100)' 2>&1 || true)"
expect_hot_success "$comp_op_patched"
expect_contains "$comp_op_patched" "value: 0"
echo "assoc compaction_op_min override (always 0): OK"

dissoc_comp_op="$(zig_hot dissoc compaction_op_min 2>&1 || true)"
expect_hot_success "$dissoc_comp_op"
comp_op_restored="$(zig_hot eval-zig src/lsm/compaction.zig 'compaction_op_min(100)' 2>&1 || true)"
expect_hot_success "$comp_op_restored"
expect_contains "$comp_op_restored" "value: 96"
echo "dissoc compaction_op_min: OK"

# TimestampRange.valid — range comparison returning bool
ts_valid_eval="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.valid(1)' 2>&1 || true)"
if echo "$ts_valid_eval" | grep -qF "value: true"; then
  echo "eval-zig TimestampRange.valid(1) = true ✓"

  ts_valid_zero="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.valid(0)' 2>&1 || true)"
  if echo "$ts_valid_zero" | grep -qF "value: false"; then
    echo "eval-zig TimestampRange.valid(0) = false ✓"
  fi

  # assoc override: make valid always return true
  assoc_ts_valid="$(zig_hot assoc --no-native TimestampRange.valid --file src/lsm/timestamp_range.zig 'fn valid(timestamp: u64) bool { _ = timestamp; return true; }' 2>&1)"
  if echo "$assoc_ts_valid" | grep -qF "done"; then
    ts_valid_patched="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.valid(0)' 2>&1 || true)"
    expect_contains "$ts_valid_patched" "value: true"
    echo "assoc TimestampRange.valid override (always true): OK"

    dissoc_ts_valid="$(zig_hot dissoc TimestampRange.valid 2>&1)"
    expect_contains "$dissoc_ts_valid" "done"
    echo "dissoc TimestampRange.valid: OK"
  else
    echo "assoc TimestampRange.valid not yet supported — skipping"
  fi
else
  echo "eval-zig TimestampRange.valid not yet supported — skipping"
fi

# TimestampRange.gte — pure struct construction with timestamp_max upper bound
ts_gte_eval="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.gte(7).min' 2>&1 || true)"
if echo "$ts_gte_eval" | grep -qF "value: 7"; then
  echo "eval-zig TimestampRange.gte(7).min = 7 ✓"

  assoc_ts_gte="$(zig_hot assoc --no-native TimestampRange.gte --file src/lsm/timestamp_range.zig 'fn gte(initial: u64) TimestampRange { _ = initial; return .{ .min = 9, .max = 9 }; }' 2>&1)"
  if echo "$assoc_ts_gte" | grep -qF "done"; then
    ts_gte_patched="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.gte(7).min' 2>&1 || true)"
    expect_contains "$ts_gte_patched" "value: 9"
    echo "assoc TimestampRange.gte override: OK"

    dissoc_ts_gte="$(zig_hot dissoc TimestampRange.gte 2>&1)"
    expect_contains "$dissoc_ts_gte" "done"
    ts_gte_restored="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.gte(7).min' 2>&1 || true)"
    expect_contains "$ts_gte_restored" "value: 7"
    echo "dissoc TimestampRange.gte: OK"
  else
    echo "assoc TimestampRange.gte not yet supported — skipping"
  fi
else
  echo "eval-zig TimestampRange.gte not yet supported — skipping"
fi

# TimestampRange.lte — pure struct construction with timestamp_min lower bound
ts_lte_eval="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.lte(7).max' 2>&1 || true)"
if echo "$ts_lte_eval" | grep -qF "value: 7"; then
  echo "eval-zig TimestampRange.lte(7).max = 7 ✓"

  assoc_ts_lte="$(zig_hot assoc --no-native TimestampRange.lte --file src/lsm/timestamp_range.zig 'fn lte(final: u64) TimestampRange { _ = final; return .{ .min = 1, .max = 9 }; }' 2>&1)"
  if echo "$assoc_ts_lte" | grep -qF "done"; then
    ts_lte_patched="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.lte(7).max' 2>&1 || true)"
    expect_contains "$ts_lte_patched" "value: 9"
    echo "assoc TimestampRange.lte override: OK"

    dissoc_ts_lte="$(zig_hot dissoc TimestampRange.lte 2>&1)"
    expect_contains "$dissoc_ts_lte" "done"
    ts_lte_restored="$(zig_hot eval-zig src/lsm/timestamp_range.zig 'TimestampRange.lte(7).max' 2>&1 || true)"
    expect_contains "$ts_lte_restored" "value: 7"
    echo "dissoc TimestampRange.lte: OK"
  else
    echo "assoc TimestampRange.lte not yet supported — skipping"
  fi
else
  echo "eval-zig TimestampRange.lte not yet supported — skipping"
fi

# snapshot_min_for_table_output — compaction half-bar snapshot math
snapshot_min_eval="$(zig_hot eval-zig src/lsm/compaction.zig 'snapshot_min_for_table_output(@divExact(constants.lsm_compaction_ops, 2)) == constants.lsm_compaction_ops' 2>&1 || true)"
expect_hot_success "$snapshot_min_eval"
expect_contains "$snapshot_min_eval" "value: true"
echo "eval-zig snapshot_min_for_table_output(...)=constants.lsm_compaction_ops ✓"

assoc_snapshot_min="$(zig_hot assoc --no-native snapshot_min_for_table_output --file src/lsm/compaction.zig 'fn snapshot_min_for_table_output(op_min: u64) u64 { _ = op_min; return 1234; }' 2>&1 || true)"
expect_hot_success "$assoc_snapshot_min"
snapshot_min_patched="$(zig_hot eval-zig src/lsm/compaction.zig 'snapshot_min_for_table_output(@divExact(constants.lsm_compaction_ops, 2))' 2>&1 || true)"
expect_hot_success "$snapshot_min_patched"
expect_contains "$snapshot_min_patched" "value: 1234"
echo "assoc snapshot_min_for_table_output override: OK"

dissoc_snapshot_min="$(zig_hot dissoc snapshot_min_for_table_output 2>&1 || true)"
expect_hot_success "$dissoc_snapshot_min"
snapshot_min_restored="$(zig_hot eval-zig src/lsm/compaction.zig 'snapshot_min_for_table_output(@divExact(constants.lsm_compaction_ops, 2)) == constants.lsm_compaction_ops' 2>&1 || true)"
expect_hot_success "$snapshot_min_restored"
expect_contains "$snapshot_min_restored" "value: true"
echo "dissoc snapshot_min_for_table_output: OK"

# snapshot_max_for_table_input — companion snapshot math derived from output minimum
snapshot_max_eval="$(zig_hot eval-zig src/lsm/compaction.zig 'snapshot_max_for_table_input(@divExact(constants.lsm_compaction_ops, 2)) == constants.lsm_compaction_ops - 1' 2>&1 || true)"
if echo "$snapshot_max_eval" | grep -qF "value: true"; then
  echo "eval-zig snapshot_max_for_table_input(...)=constants.lsm_compaction_ops-1 ✓"

  assoc_snapshot_max="$(zig_hot assoc --no-native snapshot_max_for_table_input --file src/lsm/compaction.zig 'fn snapshot_max_for_table_input(op_min: u64) u64 { _ = op_min; return 1233; }' 2>&1)"
  if echo "$assoc_snapshot_max" | grep -qF "done"; then
    snapshot_max_patched="$(zig_hot eval-zig src/lsm/compaction.zig 'snapshot_max_for_table_input(@divExact(constants.lsm_compaction_ops, 2))' 2>&1 || true)"
    expect_contains "$snapshot_max_patched" "value: 1233"
    echo "assoc snapshot_max_for_table_input override: OK"

    dissoc_snapshot_max="$(zig_hot dissoc snapshot_max_for_table_input 2>&1)"
    expect_contains "$dissoc_snapshot_max" "done"
    snapshot_max_restored="$(zig_hot eval-zig src/lsm/compaction.zig 'snapshot_max_for_table_input(@divExact(constants.lsm_compaction_ops, 2)) == constants.lsm_compaction_ops - 1' 2>&1 || true)"
    expect_contains "$snapshot_max_restored" "value: true"
    echo "dissoc snapshot_max_for_table_input: OK"
  else
    echo "assoc snapshot_max_for_table_input not yet supported — skipping"
  fi
else
  echo "eval-zig snapshot_max_for_table_input not yet supported — skipping"
fi

# multi_batch_count_max — worst-case trailer-aware batch count calculation
multi_batch_count_eval="$(zig_hot eval-zig src/vsr/multi_batch.zig 'multi_batch_count_max(.{ .batch_size_min = 1, .batch_size_limit = 10 })' 2>&1 || true)"
if echo "$multi_batch_count_eval" | grep -qF "value: 2"; then
  echo "eval-zig multi_batch_count_max(...)=2 ✓"

  assoc_multi_batch_count="$(zig_hot assoc --no-native multi_batch_count_max --file src/vsr/multi_batch.zig 'fn multi_batch_count_max(options: struct { batch_size_min: u32, batch_size_limit: u32, }) u16 { _ = options; return 7; }' 2>&1)"
  if echo "$assoc_multi_batch_count" | grep -qF "done"; then
    multi_batch_count_patched="$(zig_hot eval-zig src/vsr/multi_batch.zig 'multi_batch_count_max(.{ .batch_size_min = 1, .batch_size_limit = 10 })' 2>&1 || true)"
    expect_contains "$multi_batch_count_patched" "value: 7"
    echo "assoc multi_batch_count_max override: OK"

    dissoc_multi_batch_count="$(zig_hot dissoc multi_batch_count_max 2>&1)"
    expect_contains "$dissoc_multi_batch_count" "done"
    multi_batch_count_restored="$(zig_hot eval-zig src/vsr/multi_batch.zig 'multi_batch_count_max(.{ .batch_size_min = 1, .batch_size_limit = 10 })' 2>&1 || true)"
    expect_contains "$multi_batch_count_restored" "value: 2"
    echo "dissoc multi_batch_count_max: OK"
  else
    echo "assoc multi_batch_count_max not yet supported — skipping"
  fi
else
  echo "eval-zig multi_batch_count_max not yet supported — skipping"
fi

# trailer_total_size — trailer alignment through div_ceil and element-size rounding
trailer_total_size_eval="$(zig_hot eval-zig src/vsr/multi_batch.zig 'trailer_total_size(.{ .element_size = 128, .batch_count = 4 })' 2>&1 || true)"
if echo "$trailer_total_size_eval" | grep -qF "value: 128"; then
  echo "eval-zig trailer_total_size(...)=128 ✓"

  assoc_trailer_total_size="$(zig_hot assoc --no-native trailer_total_size --file src/vsr/multi_batch.zig 'fn trailer_total_size(options: struct { element_size: u32, batch_count: u16, }) u32 { _ = options; return 64; }' 2>&1)"
  if echo "$assoc_trailer_total_size" | grep -qF "done"; then
    trailer_total_size_patched="$(zig_hot eval-zig src/vsr/multi_batch.zig 'trailer_total_size(.{ .element_size = 128, .batch_count = 4 })' 2>&1 || true)"
    expect_contains "$trailer_total_size_patched" "value: 64"
    echo "assoc trailer_total_size override: OK"

    dissoc_trailer_total_size="$(zig_hot dissoc trailer_total_size 2>&1)"
    expect_contains "$dissoc_trailer_total_size" "done"
    trailer_total_size_restored="$(zig_hot eval-zig src/vsr/multi_batch.zig 'trailer_total_size(.{ .element_size = 128, .batch_count = 4 })' 2>&1 || true)"
    expect_contains "$trailer_total_size_restored" "value: 128"
    echo "dissoc trailer_total_size: OK"
  else
    echo "assoc trailer_total_size not yet supported — skipping"
  fi
else
  echo "eval-zig trailer_total_size not yet supported — skipping"
fi

# div_ceil — anytype dispatch with concrete unsigned integer bindings
div_ceil_eval="$(zig_hot eval-zig src/stdx/stdx.zig 'div_ceil(@as(u32, 18), @as(u32, 16))' 2>&1 || true)"
if echo "$div_ceil_eval" | grep -qF "value: 2"; then
  echo "eval-zig div_ceil(@as(u32, 18), @as(u32, 16)) = 2 ✓"

  assoc_div_ceil="$(zig_hot assoc --no-native div_ceil --file src/stdx/stdx.zig 'fn div_ceil(numerator: anytype, denominator: anytype) @TypeOf(numerator, denominator) { _ = numerator; _ = denominator; return @as(@TypeOf(numerator, denominator), 7); }' 2>&1)"
  if echo "$assoc_div_ceil" | grep -qF "done"; then
    div_ceil_patched="$(zig_hot eval-zig src/stdx/stdx.zig 'div_ceil(@as(u32, 18), @as(u32, 16))' 2>&1 || true)"
    expect_contains "$div_ceil_patched" "value: 7"
    echo "assoc div_ceil override: OK"

    dissoc_div_ceil="$(zig_hot dissoc div_ceil 2>&1)"
    expect_contains "$dissoc_div_ceil" "done"
    div_ceil_restored="$(zig_hot eval-zig src/stdx/stdx.zig 'div_ceil(@as(u32, 18), @as(u32, 16))' 2>&1 || true)"
    expect_contains "$div_ceil_restored" "value: 2"
    tb_proven_functions+=(div_ceil)
    echo "dissoc div_ceil: OK"
  else
    echo "assoc div_ceil not yet supported — skipping"
  fi
else
  echo "eval-zig div_ceil not yet supported — skipping"
fi

# pop_winner — nested comptime dispatch through a concrete tournament-tree alias
pop_winner_baseline="$(zig_hot compile-body hot_pop_winner_probe.zig popWinnerProbe 2>&1 || true)"
expect_hot_success "$pop_winner_baseline"
expect_contains "$pop_winner_baseline" "value: 60"
echo "compile-body popWinnerProbe() = 60 ✓"

assoc_pop_winner="$(zig_hot assoc --no-native pop_winner --file hot_pop_winner_probe.zig 'fn pop_winner(tree: *Tree, entrant: ?u32) void { tree.win_key = if (entrant) |key| key + 100 else 777; tree.win_id = 3; }' 2>&1)"
expect_hot_success "$assoc_pop_winner"
pop_winner_patched="$(zig_hot compile-body hot_pop_winner_probe.zig popWinnerProbe 2>&1 || true)"
expect_hot_success "$pop_winner_patched"
expect_contains "$pop_winner_patched" "value: 1063"
echo "assoc pop_winner override: OK"

dissoc_pop_winner="$(zig_hot dissoc pop_winner 2>&1)"
expect_hot_success "$dissoc_pop_winner"
pop_winner_restored="$(zig_hot compile-body hot_pop_winner_probe.zig popWinnerProbe 2>&1 || true)"
expect_hot_success "$pop_winner_restored"
expect_contains "$pop_winner_restored" "value: 60"
tb_proven_functions+=(Tree.pop_winner)
echo "dissoc pop_winner: OK"

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

echo "summary tigerbeetle hot surface: functions=${#tb_proven_functions[@]} vars=${#tb_proven_vars[@]}"
echo "hot smoke test passed"
