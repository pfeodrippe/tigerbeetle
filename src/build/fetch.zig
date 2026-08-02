const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const stdb = @import("./stdb.zig");

const log = std.log;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(process_init: std.process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const args = try process_init.minimal.args.toSlice(arena);
    assert(args.len == 6 or args.len == 7);

    _, const zig, const global_cache, const url, const file_name, const out = args[0..6].*;
    const hash_optional = if (args.len == 7) args[6] else null;
    assert(args.len <= 7);

    if (hash_optional) |hash| {
        // Fast path --- don't touch the Internet if we have the hash locally.
        if (copy_from_cache(arena, process_init.io, global_cache, hash, file_name, out)) {
            log.debug("download skipped: cache hit", .{});
            return;
        } else |_| { // Time to ask for forgiveness!
            log.debug("download: cache miss", .{});
        }
    } else {
        log.debug("download: no hash", .{});
    }

    const hash = try fetch(arena, .{
        .io = process_init.io,
        .zig = zig,
        .tmp = path_join(arena, &.{ global_cache, "tmp" }),
        .url = url,
    });

    if (hash_optional) |hash_specified| {
        if (!std.mem.eql(u8, hash, hash_specified)) {
            log.err(
                \\bad hash
                \\specified: {s}
                \\fetched:   {s}
                \\
            , .{ hash_specified, hash });
            return error.BadHash;
        }
    }

    try copy_from_cache(arena, process_init.io, global_cache, hash, file_name, out);
}

/// Zig 0.16 stores fetched packages as `p/<hash>.tar.gz` instead of an
/// extracted `p/<hash>/` directory. Stream just the requested artifact out of
/// the archive so the build does not depend on an external `tar` executable.
fn copy_from_cache(
    arena: Allocator,
    io: std.Io,
    global_cache: []const u8,
    hash: []const u8,
    file_name: []const u8,
    out: []const u8,
) !void {
    const archive_path = try std.fmt.allocPrint(arena, "{s}/p/{s}.tar.gz", .{
        global_cache,
        hash,
    });
    const wanted = try std.fmt.allocPrint(arena, "{s}/{s}", .{ hash, file_name });
    errdefer log.err("extracting {s} from {s}", .{ wanted, archive_path });

    const archive = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer archive.close(io);

    var archive_buffer: [64 * 1024]u8 = undefined;
    var archive_reader = archive.reader(io, &archive_buffer);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(
        &archive_reader.interface,
        .gzip,
        &decompress_buffer,
    );

    var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.name, wanted)) continue;

        const permissions: std.Io.File.Permissions =
            if (std.Io.File.Permissions.has_executable_bit and (entry.mode & 0o100) != 0)
                .executable_file
            else
                .default_file;
        const destination = try std.Io.Dir.cwd().createFile(io, out, .{
            .truncate = true,
            .permissions = permissions,
        });
        defer destination.close(io);

        var output_buffer: [64 * 1024]u8 = undefined;
        var output_writer = destination.writer(io, &output_buffer);
        try iterator.streamRemaining(entry, &output_writer.interface);
        try output_writer.interface.flush();
        return;
    }

    return error.CacheArtifactNotFound;
}

/// If curl is available, use it for robust downloads, and then
/// `zig fetch` a local file to get the hash. Otherwise, fetch
/// the url directly.
fn fetch(arena: Allocator, options: struct {
    io: std.Io,
    zig: []const u8,
    tmp: []const u8,
    url: []const u8,
}) ![]const u8 {
    if (stdb.exec_ok(arena, options.io, &.{ "curl", "--version" })) {
        log.debug("download: curl", .{});
        const url_file_name = options.url[std.mem.lastIndexOf(u8, options.url, "/").?..];
        var random: u64 = undefined;
        options.io.random(std.mem.asBytes(&random));
        const tmp_dir = path_join(arena, &.{
            options.tmp,
            &std.fmt.bytesToHex(std.mem.asBytes(&random), .lower),
        });
        defer std.Io.Dir.cwd().deleteTree(options.io, tmp_dir) catch {};

        try std.Io.Dir.cwd().createDirPath(options.io, tmp_dir);

        const curl_output = path_join(arena, &.{ tmp_dir, url_file_name });
        // TODO Go back to using stdb.exec once this curl/zip issue is debugged.
        const curl_result = std.process.run(arena, options.io, .{
            .argv = &(.{
                "curl",             "--retry-all-errors",
                "--retry",          "5",
                "--retry-max-time", "120",
                "--retry-delay",    "30",
                "--location",       options.url,
                "--output",         curl_output,
                "--verbose",        "--fail",
            }),
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| {
            log.err("curl error: {}", .{err});
            return err;
        };
        errdefer log.err("curl stderr: {s}\n\ncurl stderr end", .{curl_result.stderr});

        if (!(curl_result.term == .exited and curl_result.term.exited == 0)) {
            log.err("curl error: {}", .{curl_result.term});
            return error.Exec;
        }
        return try stdb.exec(arena, options.io, &.{ options.zig, "fetch", curl_output });
    }
    log.debug("download: zig fetch", .{});
    return try stdb.exec(arena, options.io, &.{ options.zig, "fetch", options.url });
}

fn path_join(arena: Allocator, components: []const []const u8) []const u8 {
    return std.fs.path.join(arena, components) catch |err| oom(err);
}

pub fn oom(_: error{OutOfMemory}) noreturn {
    @panic("OOM");
}
