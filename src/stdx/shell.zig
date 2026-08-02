//! Collection of utilities for scripting: an in-process sh+coreutils combo.
//!
//! Keep this as a single file, independent from the rest of the codebase, to make it easier to
//! reuse across different processes (eg build.zig).
//!
//! If possible, avoid shelling out to `sh` or other systems utils --- the whole purpose here is to
//! avoid any extra dependencies.
//!
//! The `exec_` family of methods provides a convenience wrapper around `std.process.Child`:
//!   - It allows constructing the array of arguments using convenient interpolation syntax a-la
//!     `std.fmt` (but of course no actual string concatenation happens anywhere).
//!   - `ChildProcess` is versatile and has many knobs, but they might be hard to use correctly (eg,
//!     its easy to forget to check exit status). `Shell` instead is focused on providing a set of
//!     specific narrow use-cases (eg, parsing the output of a subprocess) and takes care of setting
//!     the right defaults.

const std = @import("std");
const stdx = @import("stdx.zig");
const log = std.log;
const builtin = @import("builtin");
const assert = std.debug.assert;

const Shell = @This();

const MiB = stdx.MiB;

const cwd_stack_max = 16;

/// For internal use by the `Shell` itself.
gpa: std.mem.Allocator,

/// To improve ergonomics, any returned data is owned by the `Shell` and is stored in this arena.
/// This way, the user doesn't need to worry about deallocating each individual string, as long as
/// they don't forget to call `Shell.destroy`.
arena: std.heap.ArenaAllocator,

/// Root directory of this repository.
///
/// This is initialized when a shell is created. It would be more flexible to lazily initialize this
/// on the first access, but, given that we always use `Shell` in the context of our repository,
/// eager initialization is more ergonomic.
project_root: std.Io.Dir,

/// Shell's logical cwd which is used for all functions in this file. It might be different from
/// `std.fs.cwd()` and is set to `project_root` on init.
cwd: std.Io.Dir,

// Stack of working directories backing pushd/popd.
cwd_stack: [cwd_stack_max]std.Io.Dir,
cwd_stack_count: usize,

// Zig uses file-descriptor oriented APIs in the standard library, with the one exception being
// ChildProcess's cwd, which is required to be a path, rather than a file descriptor. This buffer
// is used to materialize the path to cwd when spawning a new process.
//   <https://github.com/ziglang/zig/issues/5190>
cwd_path_buffer: [std.fs.max_path_bytes]u8 = undefined,

env: std.process.Environ.Map,

/// True if the process is run in CI (the CI env var is set)
ci: bool,

/// Absolute path to the Zig binary.
zig_exe: ?[]const u8,

pub fn create(gpa: std.mem.Allocator) !*Shell {
    if (builtin.is_test) {
        stdx.process_io = std.testing.io;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var project_root = try discover_project_root();
    errdefer project_root.close(stdx.process_io);

    const cwd = try project_root.openDir(stdx.process_io, ".", .{});
    errdefer cwd.close(stdx.process_io);

    var env = try stdx.current_process_environ().createMap(gpa);
    errdefer env.deinit();

    const ci = env.get("CI") != null;

    const result = try gpa.create(Shell);
    errdefer gpa.destroy(result);

    result.* = Shell{
        .gpa = gpa,
        .arena = arena,
        .project_root = project_root,
        .cwd = cwd,
        .cwd_stack = undefined,
        .cwd_stack_count = 0,
        .env = env,
        .ci = ci,
        .zig_exe = env.get("ZIG_EXE"),
    };

    return result;
}

pub fn destroy(shell: *Shell) void {
    const gpa = shell.gpa;

    assert(shell.cwd_stack_count == 0); // pushd not paired by popd

    shell.env.deinit();
    shell.cwd.close(stdx.process_io);
    shell.project_root.close(stdx.process_io);
    shell.arena.deinit();
    gpa.destroy(shell);
}

const ansi = .{
    .red = "\x1b[0;31m",
    .reset = "\x1b[0m",
};

/// Prints formatted input to stderr.
/// Newline symbol is appended automatically.
/// ANSI colors are supported via `"{ansi-red}my colored text{ansi-reset}"` syntax.
pub fn echo(shell: *Shell, comptime format: []const u8, format_args: anytype) void {
    _ = shell;

    comptime var format_ansi: []const u8 = "";
    comptime var pos: usize = 0;
    comptime var pos_start: usize = 0;

    comptime next_pos: while (pos < format.len) {
        if (format[pos] == '{') {
            for (std.meta.fieldNames(@TypeOf(ansi))) |field_name| {
                const tag = "{ansi-" ++ field_name ++ "}";
                if (std.mem.startsWith(u8, format[pos..], tag)) {
                    format_ansi = format_ansi ++ format[pos_start..pos] ++ @field(ansi, field_name);
                    pos += tag.len;
                    pos_start = pos;
                    continue :next_pos;
                }
            }
        }
        pos += 1;
    };
    comptime assert(pos == format.len);

    format_ansi = format_ansi ++ format[pos_start..pos] ++ "\n";

    std.debug.print(format_ansi, format_args);
}

/// Opens a logical, named section of the script.
/// When the section is subsequently closed, its name and timing are printed.
/// Additionally on CI output from a section gets into a named, foldable group.
pub fn open_section(shell: *Shell, name: []const u8) !Section {
    return Section.open(shell.ci, name);
}

const Section = struct {
    ci: bool,
    name: []const u8,
    timer: stdx.Timer,

    fn open(ci: bool, name: []const u8) !Section {
        if (ci) {
            // See
            // https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#grouping-log-lines
            // https://github.com/actions/toolkit/issues/1001
            var buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(stdx.process_io, &buffer);
            try stdout_writer.interface.print("::group::{s}\n", .{name});
            try stdout_writer.interface.flush();
        }

        return .{
            .ci = ci,
            .name = name,
            .timer = try stdx.Timer.start(),
        };
    }

    pub fn close(section: *Section) void {
        const elapsed_ns = section.timer.lap();
        std.debug.print("{s}: {f}\n", .{
            section.name,
            std.Io.Duration.fromNanoseconds(@intCast(elapsed_ns)),
        });
        if (section.ci) {
            var buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(stdx.process_io, &buffer);
            stdout_writer.interface.print("::endgroup::\n", .{}) catch return;
            stdout_writer.interface.flush() catch {};
        }
        section.* = undefined;
    }
};

/// Convenience string formatting function which uses shell's arena and doesn't require
/// freeing the resulting string.
pub fn fmt(shell: *Shell, comptime format: []const u8, format_args: anytype) ![]const u8 {
    return std.fmt.allocPrint(shell.arena.allocator(), format, format_args);
}

pub fn env_get_option(shell: *Shell, var_name: []const u8) ?[]const u8 {
    return std.process.Environ.getAlloc(
        stdx.current_process_environ(),
        shell.arena.allocator(),
        var_name,
    ) catch null;
}

pub fn env_get(shell: *Shell, var_name: []const u8) ![]const u8 {
    errdefer {
        log.warn("environment variable '{s}' not defined", .{var_name});
    }

    return try std.process.Environ.getAlloc(
        stdx.current_process_environ(),
        shell.arena.allocator(),
        var_name,
    );
}

/// Change `shell`'s working directory. It *must* be followed by
///
///     defer shell.popd();
///
/// to restore the previous directory back.
pub fn pushd(shell: *Shell, path: []const u8) !void {
    assert(shell.cwd_stack_count < cwd_stack_max);
    // allow only explicitly relative paths or absolute paths
    assert(path[0] == '.' or path[0] == '/');

    const cwd_new = try shell.cwd.openDir(stdx.process_io, path, .{});

    shell.cwd_stack[shell.cwd_stack_count] = shell.cwd;
    shell.cwd_stack_count += 1;
    shell.cwd = cwd_new;
}

pub fn pushd_dir(shell: *Shell, dir: std.Io.Dir) !void {
    assert(shell.cwd_stack_count < cwd_stack_max);

    // Re-open the directory such that `popd` can close it.
    const cwd_new = try dir.openDir(stdx.process_io, ".", .{});

    shell.cwd_stack[shell.cwd_stack_count] = shell.cwd;
    shell.cwd_stack_count += 1;
    shell.cwd = cwd_new;
}

pub fn popd(shell: *Shell) void {
    shell.cwd.close(stdx.process_io);
    shell.cwd_stack_count -= 1;
    shell.cwd = shell.cwd_stack[shell.cwd_stack_count];
}

/// Checks if the path exists and is a directory.
///
/// Note: this api is prone to TOCTOU and exists primarily for assertions.
pub fn dir_exists(shell: *Shell, path: []const u8) !bool {
    return subdir_exists(shell.cwd, path);
}

/// Checks if the path exists and is a file.
///
/// Note: this api is prone to TOCTOU and exists primarily for assertions.
pub fn file_exists(shell: *Shell, path: []const u8) bool {
    const stat = shell.cwd.statFile(stdx.process_io, path, .{}) catch return false;
    return stat.kind == .file;
}

pub fn file_make_executable(shell: *Shell, path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        const fd = try shell.cwd.openFile(stdx.process_io, path, .{ .mode = .read_write });
        defer fd.close(stdx.process_io);

        try fd.setPermissions(stdx.process_io, .executable_file);
    }
}

fn subdir_exists(dir: std.Io.Dir, path: []const u8) !bool {
    const stat = dir.statFile(stdx.process_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.IsDir => return true,
        else => return err,
    };

    return stat.kind == .directory;
}

pub fn file_ensure_content(
    shell: *Shell,
    path: []const u8,
    content: []const u8,
    create_flags: std.Io.Dir.CreateFileOptions,
) !enum { unchanged, updated } {
    const max_bytes = 1 * MiB;
    const content_current = shell.cwd.readFileAlloc(
        stdx.process_io,
        path,
        shell.gpa,
        .limited(max_bytes),
    ) catch null;
    defer if (content_current) |slice| shell.gpa.free(slice);

    if (content_current != null and std.mem.eql(u8, content_current.?, content)) {
        return .unchanged;
    }

    try shell.cwd.writeFile(stdx.process_io, .{
        .sub_path = path,
        .data = content,
        .flags = create_flags,
    });
    return .updated;
}

/// Creates a new temporary directory (in the project-level .zig-cache) and returns the
/// absolute path.
///
/// It's the callers responsibility to delete the directory when done with it, e.g.
/// with `defer shell.cwd.deleteTree(dir) catch {};`.
pub fn create_tmp_dir(
    shell: *Shell,
) ![]const u8 {
    const root = try shell.project_root.realPathFileAlloc(
        stdx.process_io,
        ".",
        shell.arena.allocator(),
    );
    const tmp_absolute = try shell.fmt("{s}/.zig-cache/tmp/{}", .{
        root,
        stdx.random_int(u64),
    });
    assert(!try shell.dir_exists(tmp_absolute));
    try shell.project_root.createDirPath(stdx.process_io, tmp_absolute);
    return tmp_absolute;
}

const FindOptions = struct {
    where: []const []const u8,
    extension: ?[]const u8 = null,
    extensions: ?[]const []const u8 = null,
};

/// Analogue of the `find` utility, returns a set of paths matching filtering criteria.
///
/// Returned slice is stored in `Shell.arena`.
pub fn find(shell: *Shell, options: FindOptions) ![]const []const u8 {
    if (options.extension != null and options.extensions != null) {
        @panic("conflicting extension filters");
    }
    if (options.extension) |extension| {
        assert(extension[0] == '.');
    }
    if (options.extensions) |extensions| {
        for (extensions) |extension| {
            assert(extension[0] == '.');
        }
    }

    var result = std.array_list.Managed([]const u8).init(shell.arena.allocator());

    for (options.where) |base_path| {
        var base_dir = try shell.cwd.openDir(
            stdx.process_io,
            base_path,
            .{ .iterate = true },
        );
        defer base_dir.close(stdx.process_io);

        var walker = try base_dir.walk(shell.gpa);
        defer walker.deinit();

        while (try walker.next(stdx.process_io)) |entry| {
            if (entry.kind == .file and find_filter_path(entry.path, options)) {
                const full_path =
                    try std.fs.path.join(shell.arena.allocator(), &.{ base_path, entry.path });
                try result.append(full_path);
            }
        }
    }

    return result.items;
}

fn find_filter_path(path: []const u8, options: FindOptions) bool {
    if (options.extension == null and options.extensions == null) return true;
    if (options.extension != null and options.extensions != null) @panic("conflicting filters");

    if (options.extension) |extension| {
        return std.mem.endsWith(u8, path, extension);
    }

    if (options.extensions) |extensions| {
        for (extensions) |extension| {
            if (std.mem.endsWith(u8, path, extension)) return true;
        }
        return false;
    }

    unreachable;
}

/// Copy file, creating the destination directory as necessary.
pub fn copy_path(
    src_dir: std.Io.Dir,
    src_path: []const u8,
    dst_dir: std.Io.Dir,
    dst_path: []const u8,
) !void {
    errdefer {
        log.warn("failed to copy {s} to {s}", .{ src_path, dst_path });
    }
    if (std.fs.path.dirname(dst_path)) |dir| {
        try dst_dir.createDirPath(stdx.process_io, dir);
    }
    try src_dir.copyFile(src_path, dst_dir, dst_path, stdx.process_io, .{});
}

/// Runs the given command for side effects.
/// Returns an error if exit status is non-zero.
///
/// Supports interpolation using the following syntax:
///
/// ```
/// shell.exec("git branch {op} {branches}", .{
///     .op = "-D",
///     .branches = &.{"main", "feature"},
/// })
/// ```
pub fn exec(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !void {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit();

    return exec_inner(shell, argv.slice(), .{});
}

pub fn exec_options(
    shell: *Shell,
    options: struct {
        stdin_slice: ?[]const u8 = null,
        timeout: stdx.Duration = .minutes(10),
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) !void {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit();

    return exec_inner(shell, argv.slice(), .{
        .stdin_slice = options.stdin_slice,
        .timeout = options.timeout,
    });
}

/// Runs the given command and returns its output.
/// If the output is a single line, the final newline is stripped.
pub fn exec_stdout(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) ![]const u8 {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit();

    var captured_stdout: []const u8 = &.{};
    try exec_inner(shell, argv.slice(), .{
        .capture_stdout = &captured_stdout,
    });
    return captured_stdout;
}

pub fn exec_stdout_stderr(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !struct {
    []const u8,
    []const u8,
} {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit();

    var captured_stdout: []const u8 = &.{};
    var captured_stderr: []const u8 = &.{};
    try exec_inner(shell, argv.slice(), .{
        .capture_stdout = &captured_stdout,
        .capture_stderr = &captured_stderr,
    });
    return .{ captured_stdout, captured_stderr };
}

pub fn exec_stdout_options(
    shell: *Shell,
    options: struct {
        stdin_slice: ?[]const u8 = null,
        timeout: stdx.Duration = .minutes(10),
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) ![]const u8 {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit();

    var captured_stdout: []const u8 = &.{};
    try exec_inner(shell, argv.slice(), .{
        .stdin_slice = options.stdin_slice,
        .capture_stdout = &captured_stdout,
        .timeout = options.timeout,
    });
    return captured_stdout;
}

/// Runs the zig compiler.
pub fn exec_zig(shell: *Shell, comptime cmd: []const u8, cmd_args: anytype) !void {
    return shell.exec_zig_options(.{}, cmd, cmd_args);
}

pub fn exec_zig_options(
    shell: *Shell,
    options: struct {
        timeout: stdx.Duration = .minutes(10),
        capture_stdout: ?*[]const u8 = null,
        capture_stderr: ?*[]const u8 = null,
    },
    comptime cmd: []const u8,
    cmd_args: anytype,
) !void {
    var argv = Argv.init(shell.gpa);
    defer argv.deinit();

    try argv.append_new_arg("{s}", .{shell.zig_exe.?});
    try expand_argv(&argv, cmd, cmd_args);

    return shell.exec_inner(argv.slice(), .{
        .timeout = options.timeout,
        .capture_stdout = options.capture_stdout,
        .capture_stderr = options.capture_stderr,
    });
}

fn exec_inner(
    shell: *Shell,
    argv: []const []const u8,
    options: struct {
        stdin_slice: ?[]const u8 = null,

        // Optional out parameters:
        capture_stdout: ?*[]const u8 = null,
        capture_stderr: ?*[]const u8 = null,

        output_limit_bytes: usize = 128 * MiB,
        timeout: stdx.Duration = .minutes(10),
    },
) !void {
    const argv_formatted = try std.mem.join(shell.gpa, " ", argv);
    defer shell.gpa.free(argv_formatted);

    const run_options: std.process.RunOptions = .{
        .argv = argv,
        .cwd = .{ .dir = shell.cwd },
        .environ_map = &shell.env,
        .stdout_limit = .limited(options.output_limit_bytes),
        .stderr_limit = .limited(options.output_limit_bytes),
        .timeout = process_timeout(options.timeout),
    };
    const result = (if (options.stdin_slice) |stdin_slice|
        run_with_stdin(shell.gpa, stdx.process_io, run_options, stdin_slice)
    else
        std.process.run(shell.gpa, stdx.process_io, run_options)) catch |err| {
        log.err("process failed with {s}: {s}", .{ @errorName(err), argv_formatted });
        return switch (err) {
            error.Timeout => error.ExecTimeout,
            else => err,
        };
    };
    defer shell.gpa.free(result.stdout);
    defer shell.gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            log.err("process exited with {d}: {s}\n{s}", .{ code, argv_formatted, result.stderr });
            return error.ExecNonZeroExitStatus;
        },
        else => return error.ExecFailed,
    }

    inline for (
        .{ options.capture_stdout, options.capture_stderr },
        .{ result.stdout, result.stderr },
    ) |capture_destination, stream| {
        if (capture_destination) |destination| {
            const trailing_newline = std.mem.endsWith(u8, stream, "\n");
            const single_line = trailing_newline and
                std.mem.indexOfScalar(u8, stream[0 .. stream.len - 1], '\n') == null;
            const len_without_newline = stream.len - @intFromBool(single_line);
            destination.* = try shell.arena.allocator().dupe(u8, stream[0..len_without_newline]);
        }
    }
}

fn process_timeout(timeout: stdx.Duration) std.Io.Timeout {
    return .{ .duration = .{
        .raw = .fromNanoseconds(timeout.ns),
        .clock = .awake,
    } };
}

/// `std.process.run` intentionally connects stdin to the null stream. Mirror its implementation
/// here when a caller supplies stdin, writing on a separate thread so a child cannot deadlock by
/// filling stdout or stderr while the parent is still writing.
fn run_with_stdin(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: std.process.RunOptions,
    stdin_slice: []const u8,
) !std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .progress_node = options.progress_node,
        .create_no_window = options.create_no_window,
        .disable_aslr = options.disable_aslr,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    const stdin_file = child.stdin.?;
    child.stdin = null;
    const stdin_thread = try std.Thread.spawn(.{}, struct {
        fn write(io_inner: std.Io, file: std.Io.File, bytes: []const u8) void {
            defer file.close(io_inner);

            file.writeStreamingAll(io_inner, bytes) catch {};
        }
    }.write, .{ io, stdin_file, stdin_slice });

    var completed = false;
    defer if (!completed) {
        // Killing the child closes its stdin read end and unblocks the writer before joining it.
        child.kill(io);
        stdin_thread.join();
    };

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        gpa,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(options.reserve_amount, options.timeout)) |_| {
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    stdin_thread.join();
    const term = try child.wait(io);

    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr);

    completed = true;
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

/// Run the command and return its status, stderr and stdout.
/// The caller is responsible for checking the status.
pub fn exec_raw(
    shell: *Shell,
    comptime cmd: []const u8,
    cmd_args: anytype,
) !std.process.RunResult {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit();

    return try std.process.run(shell.arena.allocator(), stdx.process_io, .{
        .argv = argv.slice(),
        .cwd = .{ .dir = shell.cwd },
        .environ_map = &shell.env,
    });
}

pub const SpawnOptions = struct {
    stdin_behavior: std.process.SpawnOptions.StdIo = .ignore,
    stdout_behavior: std.process.SpawnOptions.StdIo = .ignore,
    stderr_behavior: std.process.SpawnOptions.StdIo = .ignore,
};

pub fn spawn(
    shell: *Shell,
    options: SpawnOptions,
    comptime cmd: []const u8,
    cmd_args: anytype,
) !std.process.Child {
    var argv = try Argv.expand(shell.gpa, cmd, cmd_args);
    defer argv.deinit();

    return shell.spawn_argv(options, &argv);
}

pub fn spawn_zig(
    shell: *Shell,
    options: SpawnOptions,
    comptime cmd: []const u8,
    cmd_args: anytype,
) !std.process.Child {
    var argv = Argv.init(shell.gpa);
    defer argv.deinit();

    try argv.append_new_arg("{s}", .{shell.zig_exe.?});
    try expand_argv(&argv, cmd, cmd_args);
    return shell.spawn_argv(options, &argv);
}

fn spawn_argv(
    shell: *Shell,
    options: SpawnOptions,
    argv: *const Argv,
) !std.process.Child {
    return std.process.spawn(stdx.process_io, .{
        .argv = argv.slice(),
        .cwd = .{ .dir = shell.cwd },
        .environ_map = &shell.env,
        .stdin = options.stdin_behavior,
        .stdout = options.stdout_behavior,
        .stderr = options.stderr_behavior,
    });
}

/// On GitHub Actions runners, `git commit` fails with an "Author identity unknown" error.
///
/// This function sets up appropriate environmental variables to correct that error.
pub fn git_env_setup(shell: *Shell, options: struct { use_hostname: bool }) !void {
    if (options.use_hostname) {
        if (builtin.target.os.tag != .linux) {
            @panic("use_hostname only supported on linux");
        }
        var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = @splat(0);
        const hostname = try std.posix.gethostname(&hostname_buffer);

        try shell.env.put("GIT_AUTHOR_NAME", hostname);
        try shell.env.put("GIT_COMMITTER_NAME", hostname);
    } else {
        try shell.env.put("GIT_AUTHOR_NAME", "TigerBeetle Bot");
        try shell.env.put("GIT_COMMITTER_NAME", "TigerBeetle Bot");
    }

    try shell.env.put("GIT_AUTHOR_EMAIL", "bot@tigerbeetle.com");
    try shell.env.put("GIT_COMMITTER_EMAIL", "bot@tigerbeetle.com");
}

pub fn git_commit_timestamp(shell: *Shell, sha: []const u8) !stdx.InstantUnix {
    assert(sha.len == 40);

    const timestamp_s = try shell.exec_stdout("git show -s --format=%ct {sha}", .{ .sha = sha });
    return stdx.InstantUnix.from_timestamp_s(
        try stdx.parse_int(u64, timestamp_s, .{}),
    );
}

const Argv = struct {
    args: std.array_list.Managed([]const u8),

    fn init(gpa: std.mem.Allocator) Argv {
        return Argv{ .args = std.array_list.Managed([]const u8).init(gpa) };
    }

    fn expand(gpa: std.mem.Allocator, comptime cmd: []const u8, cmd_args: anytype) !Argv {
        var result = Argv.init(gpa);
        errdefer result.deinit();
        try expand_argv(&result, cmd, cmd_args);
        return result;
    }

    fn deinit(argv: *Argv) void {
        for (argv.args.items) |arg| argv.args.allocator.free(arg);
        argv.args.deinit();
    }

    fn slice(argv: *const Argv) []const []const u8 {
        return argv.args.items;
    }

    fn append_new_arg(argv: *Argv, comptime arg_fmt: []const u8, arg: anytype) !void {
        const arg_owned = try std.fmt.allocPrint(
            argv.args.allocator,
            arg_fmt,
            arg,
        );
        errdefer argv.args.allocator.free(arg_owned);

        try argv.args.append(arg_owned);
    }

    fn extend_last_arg(argv: *Argv, comptime arg_fmt: []const u8, arg: anytype) !void {
        assert(argv.args.items.len > 0);
        const arg_allocated = try std.fmt.allocPrint(
            argv.args.allocator,
            "{s}" ++ arg_fmt,
            .{argv.args.items[argv.args.items.len - 1]} ++ arg,
        );
        argv.args.allocator.free(argv.args.items[argv.args.items.len - 1]);
        argv.args.items[argv.args.items.len - 1] = arg_allocated;
    }
};

/// Expands `cmd` into an array of command arguments, substituting values from `cmd_args`.
///
/// This avoids shell injection by construction as it doesn't concatenate strings.
fn expand_argv(argv: *Argv, comptime cmd: []const u8, cmd_args: anytype) !void {
    @setEvalBranchQuota(5_000);
    // Mostly copy-paste from std.fmt.format

    comptime var pos: usize = 0;

    // For arguments like `tigerbeetle-{version}.exe`, we want to concatenate literal suffix
    // ("tigerbeetle-") and prefix (".exe") to the value of `version` interpolated argument.
    //
    // These two variables track the spaces around `{}` syntax.
    comptime var concat_left: bool = false;
    comptime var concat_right: bool = false;

    const arg_count = std.meta.fields(@TypeOf(cmd_args)).len;
    comptime var args_used: stdx.BitSetType(arg_count) = .{};
    comptime assert(std.mem.indexOfScalar(u8, cmd, '\'') == null); // Intentionally unsupported.
    comptime assert(std.mem.indexOfScalar(u8, cmd, '"') == null);
    inline while (pos < cmd.len) {
        inline while (pos < cmd.len and (cmd[pos] == ' ' or cmd[pos] == '\n')) {
            pos += 1;
        }

        const pos_start = pos;
        inline while (pos < cmd.len) : (pos += 1) {
            switch (cmd[pos]) {
                ' ', '\n', '{' => break,
                else => {},
            }
        }

        const pos_end = pos;
        if (pos_start != pos_end) {
            if (concat_right) {
                assert(pos_start > 0 and cmd[pos_start - 1] == '}');
                try argv.extend_last_arg("{s}", .{cmd[pos_start..pos_end]});
            } else {
                try argv.append_new_arg("{s}", .{cmd[pos_start..pos_end]});
            }
        }

        concat_left = false;
        concat_right = false;

        if (pos >= cmd.len) break;
        if (cmd[pos] == ' ' or cmd[pos] == '\n') continue;

        comptime assert(cmd[pos] == '{');
        concat_left = pos > 0 and cmd[pos - 1] != ' ' and cmd[pos - 1] != '\n';
        if (concat_left) assert(argv.slice().len > 0);
        pos += 1;

        const pos_arg_start = pos;
        inline while (pos < cmd.len and cmd[pos] != '}') : (pos += 1) {}
        const pos_arg_end = pos;

        if (pos >= cmd.len) @compileError("Missing closing }");

        comptime assert(cmd[pos] == '}');
        concat_right = pos + 1 < cmd.len and cmd[pos + 1] != ' ' and cmd[pos + 1] != '\n';
        pos += 1;

        const arg_name = comptime cmd[pos_arg_start..pos_arg_end];
        const arg_or_slice = @field(cmd_args, arg_name);
        comptime args_used.set(for (std.meta.fieldNames(@TypeOf(cmd_args)), 0..) |field, index| {
            if (std.mem.eql(u8, field, arg_name)) break index;
        } else unreachable);

        const T = @TypeOf(arg_or_slice);

        if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
            if (concat_left) {
                try argv.extend_last_arg("{d}", .{arg_or_slice});
            } else {
                try argv.append_new_arg("{d}", .{arg_or_slice});
            }
        } else if (std.meta.Elem(T) == u8) {
            if (concat_left) {
                try argv.extend_last_arg("{s}", .{arg_or_slice});
            } else {
                try argv.append_new_arg("{s}", .{arg_or_slice});
            }
        } else if (std.meta.Elem(T) == []const u8) {
            if (concat_left or concat_right) @compileError("Can't concatenate slices");
            for (arg_or_slice) |arg_part| {
                try argv.append_new_arg("{s}", .{arg_part});
            }
        } else {
            @compileError("Unsupported argument type");
        }
    }

    comptime if (args_used.count() != arg_count) @compileError("Unused argument");
}

const Snap = stdx.Snap;
const snap = Snap.snap_fn("src");

test "shell: expand_argv" {
    const T = struct {
        fn check(
            comptime cmd: []const u8,
            args: anytype,
            want: Snap,
        ) !void {
            var argv = Argv.init(std.testing.allocator);
            defer argv.deinit();

            try expand_argv(&argv, cmd, args);
            try want.diff_zon(argv.slice());
        }
    };

    try T.check("zig version", .{}, snap(@src(),
        \\.{ "zig", "version" }
    ));
    try T.check("  zig  version  ", .{}, snap(@src(),
        \\.{ "zig", "version" }
    ));

    try T.check(
        "zig {version}",
        .{ .version = @as([]const u8, "version") },
        snap(@src(),
            \\.{ "zig", "version" }
        ),
    );

    try T.check(
        "zig {version}",
        .{ .version = @as([]const []const u8, &.{ "version", "--verbose" }) },
        snap(@src(),
            \\.{
            \\    "zig",
            \\    "version",
            \\    "--verbose",
            \\}
        ),
    );

    try T.check(
        "git fetch origin refs/pull/{pr}/head",
        .{ .pr = 92 },
        snap(@src(),
            \\.{
            \\    "git",
            \\    "fetch",
            \\    "origin",
            \\    "refs/pull/92/head",
            \\}
        ),
    );
    try T.check(
        "gh pr checkout {pr}",
        .{ .pr = @as(u32, 92) },
        snap(@src(),
            \\.{
            \\    "gh",
            \\    "pr",
            \\    "checkout",
            \\    "92",
            \\}
        ),
    );
}

/// Finds the root of TigerBeetle repo.
///
/// Caller is responsible for closing the dir.
fn discover_project_root() !std.Io.Dir {
    var current = try std.Io.Dir.cwd().openDir(stdx.process_io, ".", .{});
    errdefer current.close(stdx.process_io); // Caller is responsible for closing on success.

    for (0..16) |_| {
        if (detect_project_root(current)) |_| {
            return current;
        } else |err| switch (err) {
            error.FileNotFound => {
                const parent = try current.openDir(stdx.process_io, "..", .{});
                current.close(stdx.process_io);
                current = parent;
            },
            else => return err,
        }
    }

    return error.DiscoverProjectRootDepthExceeded;
}

fn detect_project_root(dir: std.Io.Dir) !void {
    try dir.access(stdx.process_io, "build.zig", .{});
    try dir.access(stdx.process_io, "src", .{});
}

pub const HttpOptions = struct {
    pub const ContentType = enum {
        json,

        fn string(content_type: ContentType) []const u8 {
            return switch (content_type) {
                .json => "application/json",
            };
        }
    };

    content_type: ?ContentType = null,
    authorization: ?[]const u8 = null,

    response_body_size_max: u32 = 512 * stdx.KiB,
    expected_response_code: std.http.Status = .ok,
};

pub fn http_get(shell: *Shell, url: []const u8, options: HttpOptions) ![]const u8 {
    return shell.http_request(.get, url, options);
}

pub fn http_post(
    shell: *Shell,
    url: []const u8,
    body: []const u8,
    options: HttpOptions,
) ![]const u8 {
    return shell.http_request(.{ .post = body }, url, options);
}

/// Issues an HTTP request to the given `url` and returns the response.
///
/// The returned body is owned by the shell arena and doesn't need to be freed.
/// If the response is not 200 OK, the response body is logged and an error is returned.
fn http_request(
    shell: *Shell,
    method: union(enum) { get, post: []const u8 },
    url: []const u8,
    options: HttpOptions,
) anyerror![]const u8 {
    errdefer |err| log.err(
        "failed to HTTP {s} to \"{s}\": {s}",
        .{ @tagName(method), url, @errorName(err) },
    );

    var client = std.http.Client{ .allocator = shell.gpa, .io = stdx.process_io };
    defer client.deinit();

    var headers: std.http.Client.Request.Headers = .{};
    if (options.content_type) |content_type| {
        headers.content_type = .{ .override = content_type.string() };
    }
    if (options.authorization) |authorization| {
        headers.authorization = .{ .override = authorization };
    }

    const response_body_buffer = try shell.arena.allocator().alloc(
        u8,
        options.response_body_size_max,
    );
    var response_writer: std.Io.Writer = .fixed(response_body_buffer);
    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = switch (method) {
            .post => .POST,
            .get => .GET,
        },
        .payload = switch (method) {
            .post => |body| body,
            .get => null,
        },
        .headers = headers,
        .response_writer = &response_writer,
    }) catch |err| {
        switch (err) {
            error.WriteFailed => return error.ResponseTooLarge,
            else => {},
        }
        log.err("HTTP transport failed: {s}", .{@errorName(err)});
        return error.HttpRequestFailed;
    };
    const response_body = response_writer.buffered();

    if (response.status != options.expected_response_code) {
        log.err("response: {s}", .{response_body});
        return error.ResponseWrongStatus;
    }

    return response_body;
}

/// Converts an ISO8601 timestamp into seconds from the epoch by shelling out to the `date` util.
pub fn iso8601_to_timestamp_seconds(shell: *Shell, datetime_iso8601: []const u8) !u64 {
    return try stdx.parse_int(u64, try shell.exec_stdout(
        "date -d {datetime_iso8601} +%s",
        .{ .datetime_iso8601 = datetime_iso8601 },
    ), .{});
}

pub fn unzip_executable(
    shell: *Shell,
    zip_path: []const u8,
    executable_name: []const u8,
) !void {
    const zip_file = try shell.cwd.openFile(stdx.process_io, zip_path, .{});
    defer zip_file.close(stdx.process_io);

    var zip_buffer: [4096]u8 = undefined;
    var zip_reader = zip_file.reader(stdx.process_io, &zip_buffer);
    try std.zip.extract(shell.cwd, &zip_reader, .{});

    const zip_extracted = try shell.cwd.openFile(stdx.process_io, executable_name, .{});
    defer zip_extracted.close(stdx.process_io);

    // Zig's std.zip.extract doesn't handle permissions.
    if (builtin.os.tag != .windows) {
        try zip_extracted.setPermissions(
            stdx.process_io,
            std.Io.File.Permissions.fromMode(0o755),
        );
    }
}

pub const DOSTimestamp = struct {
    time: u16,
    date: u16,
};

pub fn unix_to_dos_timestamp(instant: stdx.InstantUnix) DOSTimestamp {
    const date_time = instant.date_time();
    assert(date_time.year >= 1980 and date_time.year <= 2107);

    const time: u16 =
        (@as(u16, date_time.hour) << 11) |
        (@as(u16, date_time.minute) << 5) |
        (@as(u16, @divFloor(date_time.second, 2)));

    const date: u16 =
        ((@as(u16, date_time.year - 1980)) << 9) |
        (@as(u16, date_time.month) << 5) |
        (@as(u16, date_time.day));

    return .{ .time = time, .date = date };
}

pub fn zip_executable(
    shell: *Shell,
    zip_file: std.Io.File,
    input: struct {
        executable_name: []const u8,
        executable_mtime: stdx.InstantUnix,
        max_size: u64,
    },
) !void {
    assert(std.mem.eql(u8, std.fs.path.basename(input.executable_name), input.executable_name));

    var zip_buffer: [4096]u8 = undefined;
    var zip_file_writer = zip_file.writer(stdx.process_io, &zip_buffer);
    const writer = &zip_file_writer.interface;

    const executable = try shell.cwd.readFileAlloc(
        stdx.process_io,
        input.executable_name,
        shell.gpa,
        .limited(input.max_size),
    );
    defer shell.gpa.free(executable);

    const executable_mtime_dos = unix_to_dos_timestamp(input.executable_mtime);
    const crc32 = std.hash.Crc32.hash(executable);

    const executable_deflated = blk: {
        var executable_deflated_stream: std.Io.Writer.Allocating = .init(shell.gpa);
        errdefer executable_deflated_stream.deinit();
        try executable_deflated_stream.ensureTotalCapacity(4096);
        const compression_buffer = try shell.gpa.alloc(u8, std.compress.flate.max_window_len);
        defer shell.gpa.free(compression_buffer);

        var compressor = try std.compress.flate.Compress.init(
            &executable_deflated_stream.writer,
            compression_buffer,
            .raw,
            .best,
        );
        try compressor.writer.writeAll(executable);
        try compressor.finish();

        break :blk try executable_deflated_stream.toOwnedSlice();
    };
    defer shell.gpa.free(executable_deflated);

    const zip_version_20 = 0x14;
    const zip_unix = 0x0300;

    const local_file_header: std.zip.LocalFileHeader = .{
        .signature = std.zip.local_file_header_sig,
        .version_needed_to_extract = zip_version_20,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = .deflate,
        .last_modification_time = executable_mtime_dos.time,
        .last_modification_date = executable_mtime_dos.date,
        .crc32 = crc32,
        .compressed_size = @intCast(executable_deflated.len),
        .uncompressed_size = @intCast(executable.len),
        .filename_len = @intCast(input.executable_name.len),
        .extra_len = 0,
    };

    try writer.writeStruct(local_file_header, .little);
    try writer.writeAll(input.executable_name);
    try writer.writeAll(executable_deflated);

    const central_directory_file_header: std.zip.CentralDirectoryFileHeader = .{
        .signature = std.zip.central_file_header_sig,
        .version_made_by = zip_unix | zip_version_20,
        .version_needed_to_extract = zip_version_20,
        .flags = .{ .encrypted = false, ._ = 0 },
        .compression_method = .deflate,
        .last_modification_time = executable_mtime_dos.time,
        .last_modification_date = executable_mtime_dos.date,
        .crc32 = crc32,
        .compressed_size = @intCast(executable_deflated.len),
        .uncompressed_size = @intCast(executable.len),
        .filename_len = @intCast(input.executable_name.len),
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = 0o0100755 << 16, // Regular file, executable.
        .local_file_header_offset = 0,
    };

    const central_directory_offset =
        @sizeOf(std.zip.LocalFileHeader) + input.executable_name.len + executable_deflated.len;
    try writer.writeStruct(central_directory_file_header, .little);
    try writer.writeAll(input.executable_name);
    const central_directory_end = central_directory_offset +
        @sizeOf(std.zip.CentralDirectoryFileHeader) + input.executable_name.len;

    const end_record: std.zip.EndRecord = .{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = @intCast(central_directory_end - central_directory_offset),
        .central_directory_offset = @intCast(central_directory_offset),
        .comment_len = 0,
    };
    try writer.writeStruct(end_record, .little);
    try writer.flush();
}

pub fn sha256sum(shell: *Shell, file_path: []const u8) !u256 {
    const buffer = try shell.gpa.alloc(u8, 512 * stdx.KiB);
    defer shell.gpa.free(buffer);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    const file = try shell.cwd.openFile(file_path, .{});
    defer file.close();

    const stat = try file.stat();
    var bytes_read_total: u64 = 0;
    while (bytes_read_total < stat.size) {
        const bytes_read = try file.readAll(buffer);
        if (bytes_read == 0) {
            break;
        }

        bytes_read_total += bytes_read;
        hasher.update(buffer[0..bytes_read]);
    }

    assert(stat.size == bytes_read_total);

    var output: u256 = undefined;
    hasher.final(std.mem.asBytes(&output));

    return output;
}
