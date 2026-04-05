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

if [[ ! -f "$HOT_CONFIG_FILE" ]]; then
  echo "error: missing hot config at $HOT_CONFIG_FILE" >&2
  exit 1
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
