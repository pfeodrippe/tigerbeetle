REPO_ROOT := $(abspath .)
HOT_ZIG ?= zig
HOT_ZIG_LIB_DIR ?=
HOT_DB ?= /tmp/tigerbeetle-hot-run.tigerbeetle
HOT_LOG := $(REPO_ROOT)/.hot-run.log
HOT_PID := $(REPO_ROOT)/.hot-run.pid
HOT_STDIN := $(REPO_ROOT)/.hot-run.stdin
HOT_STDIN_PID := $(REPO_ROOT)/.hot-run.stdin.pid
HOT_PORT_FILE := $(REPO_ROOT)/.nrepl-port
HOT_CONFIG_FILE := $(REPO_ROOT)/zig-out/share/zig-hot/tigerbeetle.config

hot-stop:
	@set -eu; \
	if [ -f "$(HOT_PID)" ]; then \
		pid=$$(cat "$(HOT_PID)" 2>/dev/null || true); \
		if [ -n "$$pid" ]; then \
			kill -TERM "$$pid" 2>/dev/null || true; \
			for _ in 1 2 3 4 5; do \
				if ! kill -0 "$$pid" >/dev/null 2>&1; then \
					break; \
				fi; \
				sleep 1; \
			done; \
			kill -KILL "$$pid" 2>/dev/null || true; \
		fi; \
	fi; \
	if [ -f "$(HOT_STDIN_PID)" ]; then \
		pid=$$(cat "$(HOT_STDIN_PID)" 2>/dev/null || true); \
		if [ -n "$$pid" ]; then \
			kill -TERM "$$pid" 2>/dev/null || true; \
			for _ in 1 2 3 4 5; do \
				if ! kill -0 "$$pid" >/dev/null 2>&1; then \
					break; \
				fi; \
				sleep 1; \
			done; \
			kill -KILL "$$pid" 2>/dev/null || true; \
		fi; \
	fi; \
	rm -f "$(HOT_PORT_FILE)" "$(HOT_PID)" "$(HOT_STDIN)" "$(HOT_STDIN_PID)"
.PHONY: hot-stop

hot-run: hot-stop
	@mkdir -p "$(dir $(HOT_LOG))"
	@bash -lc 'set -euo pipefail; \
		zig_bin="$(HOT_ZIG)"; \
		if [[ "$$zig_bin" == */* ]]; then \
			[[ -x "$$zig_bin" ]] || { echo "error: missing HOT_ZIG at $$zig_bin" >&2; exit 1; }; \
		else \
			command -v "$$zig_bin" >/dev/null 2>&1 || { echo "error: HOT_ZIG command not found: $$zig_bin" >&2; exit 1; }; \
		fi; \
		LLVM_PREFIX="$${LLVM_PREFIX:-$$(brew --prefix llvm@20 2>/dev/null || true)}"; \
		LLD_PREFIX="$${LLD_PREFIX:-$$(brew --prefix lld@20 2>/dev/null || true)}"; \
		ZSTD_PREFIX="$${ZSTD_PREFIX:-$$(brew --prefix zstd 2>/dev/null || true)}"; \
		LIBXML2_PREFIX="$${LIBXML2_PREFIX:-$$(brew --prefix libxml2 2>/dev/null || true)}"; \
		ZLIB_PREFIX="$${ZLIB_PREFIX:-$$(brew --prefix zlib 2>/dev/null || true)}"; \
		prepend_lib_dir() { \
			local dir="$$1"; \
			[[ -n "$$dir" && -d "$$dir" ]] || return 0; \
			if [[ -z "$${DYLD_LIBRARY_PATH:-}" ]]; then \
				export DYLD_LIBRARY_PATH="$$dir"; \
			else \
				export DYLD_LIBRARY_PATH="$$dir:$${DYLD_LIBRARY_PATH}"; \
			fi; \
		}; \
		prepend_lib_dir "$$LLVM_PREFIX/lib"; \
		prepend_lib_dir "$$LLD_PREFIX/lib"; \
		prepend_lib_dir "$$ZSTD_PREFIX/lib"; \
		prepend_lib_dir "$$LIBXML2_PREFIX/lib"; \
		prepend_lib_dir "$$ZLIB_PREFIX/lib"; \
		hot_env=(env DYLD_LIBRARY_PATH="$${DYLD_LIBRARY_PATH:-}"); \
		if [[ -n "$(HOT_ZIG_LIB_DIR)" ]]; then hot_env+=(ZIG_LIB_DIR="$(HOT_ZIG_LIB_DIR)"); fi; \
		rm -f "$(HOT_LOG)" "$(HOT_PID)" "$(HOT_PORT_FILE)" "$(HOT_STDIN)" "$(HOT_STDIN_PID)"; \
		if [[ ! -f "$(HOT_DB)" ]]; then \
			(cd "$(REPO_ROOT)" && "$${hot_env[@]}" "$$zig_bin" build run -- format --cluster=0 --replica=0 --replica-count=1 --development "$(HOT_DB)") >/dev/null; \
		fi; \
		mkfifo "$(HOT_STDIN)"; \
		tail -f /dev/null >"$(HOT_STDIN)" & \
		stdin_pid=$$!; \
		echo "$$stdin_pid" >"$(HOT_STDIN_PID)"; \
		"$${hot_env[@]}" "$$zig_bin" build hot-run -- start --addresses=0 --development "$(HOT_DB)" <"$(HOT_STDIN)" >"$(HOT_LOG)" 2>&1 & \
		run_pid=$$!; \
		echo "$$run_pid" >"$(HOT_PID)"; \
		tail -f "$(HOT_LOG)" & \
		tail_pid=$$!; \
		wait "$$run_pid"; \
		status=$$?; \
		kill "$$tail_pid" 2>/dev/null || true; \
		wait "$$tail_pid" 2>/dev/null || true; \
		exit "$$status"'
.PHONY: hot-run

hot-test: hot-stop
	@mkdir -p "$(dir $(HOT_LOG))"
	@bash -lc 'set -euo pipefail; \
		clean_dir() { \
			local path="$$1"; \
			if [ -e "$$path" ]; then \
				echo "clean\t$$path"; \
				rm -rf "$$path"; \
			fi; \
		}; \
		clean_dir "$(REPO_ROOT)/.zig-cache"; \
		clean_dir "$(REPO_ROOT)/zig-out"; \
		zig_bin="$(HOT_ZIG)"; \
		if [[ "$$zig_bin" == */* ]]; then \
			[[ -x "$$zig_bin" ]] || { echo "error: missing HOT_ZIG at $$zig_bin" >&2; exit 1; }; \
		else \
			command -v "$$zig_bin" >/dev/null 2>&1 || { echo "error: HOT_ZIG command not found: $$zig_bin" >&2; exit 1; }; \
		fi; \
		LLVM_PREFIX="$${LLVM_PREFIX:-$$(brew --prefix llvm@20 2>/dev/null || true)}"; \
		LLD_PREFIX="$${LLD_PREFIX:-$$(brew --prefix lld@20 2>/dev/null || true)}"; \
		ZSTD_PREFIX="$${ZSTD_PREFIX:-$$(brew --prefix zstd 2>/dev/null || true)}"; \
		LIBXML2_PREFIX="$${LIBXML2_PREFIX:-$$(brew --prefix libxml2 2>/dev/null || true)}"; \
		ZLIB_PREFIX="$${ZLIB_PREFIX:-$$(brew --prefix zlib 2>/dev/null || true)}"; \
		prepend_lib_dir() { \
			local dir="$$1"; \
			[[ -n "$$dir" && -d "$$dir" ]] || return 0; \
			if [[ -z "$${DYLD_LIBRARY_PATH:-}" ]]; then \
				export DYLD_LIBRARY_PATH="$$dir"; \
			else \
				export DYLD_LIBRARY_PATH="$$dir:$${DYLD_LIBRARY_PATH}"; \
			fi; \
		}; \
		prepend_lib_dir "$$LLVM_PREFIX/lib"; \
		prepend_lib_dir "$$LLD_PREFIX/lib"; \
		prepend_lib_dir "$$ZSTD_PREFIX/lib"; \
		prepend_lib_dir "$$LIBXML2_PREFIX/lib"; \
		prepend_lib_dir "$$ZLIB_PREFIX/lib"; \
		hot_env=(env DYLD_LIBRARY_PATH="$${DYLD_LIBRARY_PATH:-}"); \
		if [[ -n "$(HOT_ZIG_LIB_DIR)" ]]; then hot_env+=(ZIG_LIB_DIR="$(HOT_ZIG_LIB_DIR)"); fi; \
		rm -f "$(HOT_LOG)" "$(HOT_PID)" "$(HOT_PORT_FILE)" "$(HOT_STDIN)" "$(HOT_STDIN_PID)"; \
		cleanup() { "$(MAKE)" hot-stop >/dev/null 2>&1 || true; }; \
		trap cleanup EXIT INT TERM; \
		rm -f "$(HOT_DB)"; \
		(cd "$(REPO_ROOT)" && "$${hot_env[@]}" "$$zig_bin" build run -- format --cluster=0 --replica=0 --replica-count=1 --development "$(HOT_DB)") >/dev/null; \
		mkfifo "$(HOT_STDIN)"; \
		tail -f /dev/null >"$(HOT_STDIN)" & \
		stdin_pid=$$!; \
		echo "$$stdin_pid" >"$(HOT_STDIN_PID)"; \
		"$${hot_env[@]}" "$$zig_bin" build hot-run -- start --addresses=0 --development "$(HOT_DB)" <"$(HOT_STDIN)" >"$(HOT_LOG)" 2>&1 & \
		run_pid=$$!; \
		echo "$$run_pid" >"$(HOT_PID)"; \
		ZIG_BIN="$$zig_bin" \
		ZIG_LIB_DIR="$(HOT_ZIG_LIB_DIR)" \
		HOT_CONFIG_FILE="$(HOT_CONFIG_FILE)" \
		PORT_FILE="$(HOT_PORT_FILE)" \
		./hot-smoke-test.sh'
.PHONY: hot-test
