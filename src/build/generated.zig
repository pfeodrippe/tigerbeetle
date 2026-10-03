const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 3 and std.mem.eql(u8, args[1], "print")) {
        var buffer: [4096]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &buffer);
        try output.interface.print("{s}\n", .{args[2]});
        try output.interface.flush();
        return;
    }
    if (args.len != 5) return error.InvalidArguments;
    const check = if (std.mem.eql(u8, args[2], "check")) true else if (std.mem.eql(u8, args[2], "update")) false else return error.InvalidArguments;
    const cwd = std.Io.Dir.cwd();
    const fresh = if (std.mem.eql(u8, args[1], "file"))
        try process_file(arena, init.io, cwd, args[3], cwd, args[4], check)
    else if (std.mem.eql(u8, args[1], "directory")) blk: {
        var source = try cwd.openDir(init.io, args[3], .{ .iterate = true });
        defer source.close(init.io);
        var target = if (check)
            cwd.openDir(init.io, args[4], .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            }
        else
            try cwd.createDirPathOpen(init.io, args[4], .{});
        defer target.close(init.io);
        var entries = source.iterate();
        var all_fresh = true;
        while (try entries.next(init.io)) |entry| {
            if (entry.kind != .file) return error.ExpectedGeneratedFile;
            const entry_fresh = try process_file(
                arena,
                init.io,
                source,
                entry.name,
                target,
                entry.name,
                check,
            );
            all_fresh = all_fresh and entry_fresh;
        }
        break :blk all_fresh;
    } else return error.InvalidArguments;
    if (!fresh) {
        std.log.err("generated source '{s}' is outdated", .{args[4]});
        return error.OutdatedGeneratedSource;
    }
}

fn process_file(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    source_path: []const u8,
    target: std.Io.Dir,
    target_path: []const u8,
    check: bool,
) !bool {
    if (!check) {
        _ = try std.Io.Dir.updateFile(source, io, source_path, target, target_path, .{});
        return true;
    }
    const want = try source.readFileAlloc(io, source_path, allocator, .unlimited);
    defer allocator.free(want);
    const got = target.readFileAlloc(io, target_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(got);
    return std.mem.eql(u8, want, got);
}
