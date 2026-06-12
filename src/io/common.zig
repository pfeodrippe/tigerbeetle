//! Code shared across several IO implementations, because, e.g., it is expressible via POSIX layer.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

const stdx = @import("stdx");

const Tracer = @import("../trace.zig").Tracer;

const assert = std.debug.assert;

const is_linux = builtin.target.os.tag == .linux;

const WriteStreamingAllReturn =
    @typeInfo(@TypeOf(std.Io.File.writeStreamingAll)).@"fn".return_type.?;

pub const AOFWriteError = @typeInfo(WriteStreamingAllReturn).error_union.error_set;
pub const AOFPReadError = std.Io.File.ReadPositionalError;
pub const AOFStat = std.Io.File.Stat;
pub const AOFStatError = std.Io.Dir.StatFileError;
pub const AOFFStatError = std.Io.File.StatError;

pub const TCPOptions = struct {
    rcvbuf: c_int,
    sndbuf: c_int,
    keepalive: ?struct {
        keepidle: c_int,
        keepintvl: c_int,
        keepcnt: c_int,
    },
    user_timeout_ms: c_int,
    nodelay: bool,
};

pub const ListenOptions = struct {
    backlog: u31,
};

pub const NextTickSource = enum { lsm, vsr };

pub fn listen(
    fd: posix.socket_t,
    address: stdx.net.Address,
    options: ListenOptions,
) !stdx.net.Address {
    try setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
    try bind_socket(fd, &address.any, address.getOsSockLen());

    // Resolve port 0 to an actual port picked by the OS.
    var address_resolved: stdx.net.Address = .{ .any = undefined };
    var addrlen: posix.socklen_t = @sizeOf(stdx.net.Address);
    try getsockname_socket(fd, &address_resolved.any, &addrlen);
    assert(address_resolved.getOsSockLen() == addrlen);
    assert(address_resolved.any.family == address.any.family);

    try listen_socket(fd, options.backlog);

    return address_resolved;
}

fn bind_socket(
    fd: posix.socket_t,
    address: *const posix.sockaddr,
    address_len: posix.socklen_t,
) !void {
    while (true) switch (posix.errno(posix.system.bind(fd, address, address_len))) {
        .SUCCESS => return,
        .INTR => continue,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        .NOMEM => return error.SystemResources,
        else => |errno| return stdx.unexpected_errno("bind", errno),
    };
}

fn getsockname_socket(
    fd: posix.socket_t,
    address: *posix.sockaddr,
    address_len: *posix.socklen_t,
) !void {
    while (true) switch (posix.errno(posix.system.getsockname(fd, address, address_len))) {
        .SUCCESS => return,
        .INTR => continue,
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        .NOBUFS => return error.SystemResources,
        else => |errno| return stdx.unexpected_errno("getsockname", errno),
    };
}

fn listen_socket(fd: posix.socket_t, backlog: u31) !void {
    while (true) switch (posix.errno(posix.system.listen(fd, backlog))) {
        .SUCCESS => return,
        .INTR => continue,
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable,
        .DESTADDRREQ => return error.SocketNotBound,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => |errno| return stdx.unexpected_errno("listen", errno),
    };
}

/// Sets the socket options.
/// Although some options are generic at the socket level,
/// these settings are intended only for TCP sockets.
pub fn tcp_options(
    fd: posix.socket_t,
    options: TCPOptions,
) !void {
    if (options.rcvbuf > 0) rcvbuf: {
        if (is_linux) {
            // Requires CAP_NET_ADMIN privilege (settle for SO_RCVBUF in case of an EPERM):
            if (setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUFFORCE, options.rcvbuf)) |_| {
                break :rcvbuf;
            } else |err| switch (err) {
                error.PermissionDenied => {},
                else => |e| return e,
            }
        }
        try setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, options.rcvbuf);
    }

    if (options.sndbuf > 0) sndbuf: {
        if (is_linux) {
            // Requires CAP_NET_ADMIN privilege (settle for SO_SNDBUF in case of an EPERM):
            if (setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUFFORCE, options.sndbuf)) |_| {
                break :sndbuf;
            } else |err| switch (err) {
                error.PermissionDenied => {},
                else => |e| return e,
            }
        }
        try setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, options.sndbuf);
    }

    if (options.keepalive) |keepalive| {
        try setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, 1);
        if (is_linux) {
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, keepalive.keepidle);
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, keepalive.keepintvl);
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, keepalive.keepcnt);
        }
    }

    if (options.user_timeout_ms > 0) {
        if (is_linux) {
            const timeout_ms = options.user_timeout_ms;
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.USER_TIMEOUT, timeout_ms);
        }
    }

    // Set tcp no-delay
    if (options.nodelay) {
        if (is_linux) {
            try setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, 1);
        }
    }
}

pub fn setsockopt(fd: posix.socket_t, level: i32, option: u32, value: c_int) !void {
    try posix.setsockopt(fd, level, option, &std.mem.toBytes(value));
}

fn file_from_fd(fd: posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn dir_from_fd(fd: posix.fd_t) std.Io.Dir {
    return .{ .handle = fd };
}

fn seek_to_end(fd: posix.fd_t) !void {
    if (builtin.os.tag == .windows) return;

    switch (posix.errno(posix.system.lseek(fd, 0, posix.SEEK.END))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .INVAL => return error.Unseekable,
        .OVERFLOW => return error.Overflow,
        .SPIPE => return error.Unseekable,
        else => |errno| return stdx.unexpected_errno("lseek", errno),
    }
}

pub fn aof_blocking_write_all(fd: posix.fd_t, buffer: []const u8) AOFWriteError!void {
    return file_from_fd(fd).writeStreamingAll(std.Options.debug_io, buffer);
}

pub fn aof_blocking_pread_all(fd: posix.fd_t, buffer: []u8, offset: u64) AOFPReadError!usize {
    return file_from_fd(fd).readPositionalAll(std.Options.debug_io, buffer, offset);
}

pub fn aof_blocking_close(fd: posix.fd_t) void {
    file_from_fd(fd).close(std.Options.debug_io);
}

pub fn aof_blocking_stat(path: []const u8) AOFStatError!AOFStat {
    return std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
}

pub fn aof_blocking_fstat(fd: posix.fd_t) AOFFStatError!AOFStat {
    return file_from_fd(fd).stat(std.Options.debug_io);
}

pub fn aof_blocking_open(dir_fd: posix.fd_t, path: []const u8) !posix.fd_t {
    assert(!std.fs.path.isAbsolute(path));

    const dir = dir_from_fd(dir_fd);

    const file = try dir.createFile(std.Options.debug_io, path, .{
        .read = true,
        .truncate = false,
        .exclusive = false,
        .lock = .exclusive,
    });
    errdefer file.close(std.Options.debug_io);

    try file.sync(std.Options.debug_io);

    // We cannot fsync the directory handle on Windows.
    // We have no way to open a directory with write access.
    if (builtin.os.tag != .windows) {
        try file_from_fd(dir_fd).sync(std.Options.debug_io);
    }

    try seek_to_end(file.handle);

    return file.handle;
}

pub const Stats = struct {
    tracer: ?*Tracer = null,

    total: Timings = .{},
    window: Timings = .{},

    const Timings = struct {
        time_callbacks: stdx.Duration = .ms(0),
        time_run_for_ns: stdx.Duration = .ms(0),
        time_kernel: stdx.Duration = .ms(0),

        pub fn add(total: *Timings, increment: Timings) void {
            total.time_callbacks.ns +|= increment.time_callbacks.ns;
            total.time_run_for_ns.ns +|= increment.time_run_for_ns.ns;
            total.time_kernel.ns +|= increment.time_kernel.ns;
        }
    };

    pub fn trace(stats: *Stats) void {
        if (stats.tracer) |tracer| {
            tracer.timing(.loop_run_for_ns, stats.window.time_run_for_ns);
            tracer.timing(.loop_callbacks, stats.window.time_callbacks);
            tracer.timing(.loop_kernel, stats.window.time_kernel);
        }
        stats.total.add(stats.window);
        stats.window = .{};
    }
};
