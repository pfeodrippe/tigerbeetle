const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const posix = std.posix;

const native_os = builtin.os.tag;
const native_endian = builtin.target.cpu.arch.endian();

pub const has_unix_sockets = switch (native_os) {
    .windows => builtin.os.version_range.windows.isAtLeast(.win10_rs4) orelse false,
    else => true,
};

pub const IPParseError = error{
    Overflow,
    InvalidEnd,
    InvalidCharacter,
    Incomplete,
};

pub const IPv4ParseError = IPParseError || error{NonCanonical};
pub const IPv6ParseError = IPParseError || error{InvalidIpv4Mapping};

pub const Address = extern union {
    any: posix.sockaddr,
    in: Ip4Address,
    in6: Ip6Address,
    un: if (has_unix_sockets) posix.sockaddr.un else void,

    pub fn parseIp(name: []const u8, port: u16) !Address {
        if (parseIp4(name, port)) |ip4| return ip4 else |err| switch (err) {
            error.Overflow,
            error.InvalidEnd,
            error.InvalidCharacter,
            error.Incomplete,
            error.NonCanonical,
            => {},
        }

        if (parseIp6(name, port)) |ip6| return ip6 else |err| switch (err) {
            error.Overflow,
            error.InvalidEnd,
            error.InvalidCharacter,
            error.Incomplete,
            error.InvalidIpv4Mapping,
            => {},
        }

        return error.InvalidIPAddressFormat;
    }

    pub fn resolveIp(name: []const u8, port: u16) !Address {
        return parseIp(name, port);
    }

    pub fn parseExpectingFamily(name: []const u8, family: posix.sa_family_t, port: u16) !Address {
        switch (family) {
            posix.AF.INET => return parseIp4(name, port),
            posix.AF.INET6 => return parseIp6(name, port),
            posix.AF.UNSPEC => return parseIp(name, port),
            else => unreachable,
        }
    }

    pub fn parseIp6(buf: []const u8, port: u16) IPv6ParseError!Address {
        return .{ .in6 = try Ip6Address.parse(buf, port) };
    }

    pub fn resolveIp6(buf: []const u8, port: u16) IPv6ParseError!Address {
        return parseIp6(buf, port);
    }

    pub fn parseIp4(buf: []const u8, port: u16) IPv4ParseError!Address {
        return .{ .in = try Ip4Address.parse(buf, port) };
    }

    pub fn initIp4(addr: [4]u8, port: u16) Address {
        return .{ .in = Ip4Address.init(addr, port) };
    }

    pub fn initIp6(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Address {
        return .{ .in6 = Ip6Address.init(addr, port, flowinfo, scope_id) };
    }

    pub fn initUnix(path: []const u8) !Address {
        var sock_addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (path.len + 1 > sock_addr.path.len) return error.NameTooLong;

        @memset(&sock_addr.path, 0);
        for (path, sock_addr.path[0..path.len]) |source, *target| {
            target.* = source;
        }

        return .{ .un = sock_addr };
    }

    pub fn getPort(self: Address) u16 {
        return switch (self.any.family) {
            posix.AF.INET => self.in.getPort(),
            posix.AF.INET6 => self.in6.getPort(),
            else => unreachable,
        };
    }

    pub fn setPort(self: *Address, port: u16) void {
        switch (self.any.family) {
            posix.AF.INET => self.in.setPort(port),
            posix.AF.INET6 => self.in6.setPort(port),
            else => unreachable,
        }
    }

    pub fn initPosix(addr: *align(4) const posix.sockaddr) Address {
        switch (addr.family) {
            posix.AF.INET => return Address{
                .in = Ip4Address{ .sa = @as(*const posix.sockaddr.in, @ptrCast(addr)).* },
            },
            posix.AF.INET6 => return Address{
                .in6 = Ip6Address{ .sa = @as(*const posix.sockaddr.in6, @ptrCast(addr)).* },
            },
            else => unreachable,
        }
    }

    pub fn format(self: Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.any.family) {
            posix.AF.INET => try self.in.format(writer),
            posix.AF.INET6 => try self.in6.format(writer),
            posix.AF.UNIX => {
                if (!has_unix_sockets) unreachable;
                try writer.print("{s}", .{std.mem.sliceTo(&self.un.path, 0)});
            },
            else => unreachable,
        }
    }

    pub fn eql(a: Address, b: Address) bool {
        const a_bytes = @as([*]const u8, @ptrCast(&a.any))[0..a.getOsSockLen()];
        const b_bytes = @as([*]const u8, @ptrCast(&b.any))[0..b.getOsSockLen()];
        return mem.eql(u8, a_bytes, b_bytes);
    }

    pub fn getOsSockLen(self: Address) posix.socklen_t {
        return switch (self.any.family) {
            posix.AF.INET => self.in.getOsSockLen(),
            posix.AF.INET6 => self.in6.getOsSockLen(),
            posix.AF.UNIX => if (has_unix_sockets)
                @as(posix.socklen_t, @intCast(@sizeOf(posix.sockaddr.un)))
            else
                unreachable,
            else => unreachable,
        };
    }
};

pub const Ip4Address = extern struct {
    sa: posix.sockaddr.in,

    pub fn parse(buf: []const u8, port: u16) IPv4ParseError!Ip4Address {
        const parsed = try std.Io.net.Ip4Address.parse(buf, port);
        return init(parsed.bytes, parsed.port);
    }

    pub fn init(addr: [4]u8, port: u16) Ip4Address {
        return .{
            .sa = posix.sockaddr.in{
                .port = mem.nativeToBig(u16, port),
                .addr = @as(*align(1) const u32, @ptrCast(&addr)).*,
            },
        };
    }

    pub fn getPort(self: Ip4Address) u16 {
        return mem.bigToNative(u16, self.sa.port);
    }

    pub fn setPort(self: *Ip4Address, port: u16) void {
        self.sa.port = mem.nativeToBig(u16, port);
    }

    pub fn format(self: Ip4Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const bytes = @as(*const [4]u8, @ptrCast(&self.sa.addr));
        try writer.print("{}.{}.{}.{}:{}", .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            self.getPort(),
        });
    }

    pub fn getOsSockLen(self: Ip4Address) posix.socklen_t {
        _ = self;
        return @sizeOf(posix.sockaddr.in);
    }
};

pub const Ip6Address = extern struct {
    sa: posix.sockaddr.in6,

    pub fn parse(buf: []const u8, port: u16) IPv6ParseError!Ip6Address {
        const parsed = std.Io.net.Ip6Address.parse(buf, port) catch |err| switch (err) {
            error.ParseFailed, error.UnresolvedScope => return error.InvalidCharacter,
        };
        return init(parsed.bytes, parsed.port, parsed.flow, 0);
    }

    pub fn init(addr: [16]u8, port: u16, flowinfo: u32, scope_id: u32) Ip6Address {
        return .{
            .sa = posix.sockaddr.in6{
                .addr = addr,
                .port = mem.nativeToBig(u16, port),
                .flowinfo = flowinfo,
                .scope_id = scope_id,
            },
        };
    }

    pub fn getPort(self: Ip6Address) u16 {
        return mem.bigToNative(u16, self.sa.port);
    }

    pub fn setPort(self: *Ip6Address, port: u16) void {
        self.sa.port = mem.nativeToBig(u16, port);
    }

    pub fn format(self: Ip6Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const port = mem.bigToNative(u16, self.sa.port);
        if (mem.eql(u8, self.sa.addr[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
            try writer.print("[::ffff:{}.{}.{}.{}]:{}", .{
                self.sa.addr[12],
                self.sa.addr[13],
                self.sa.addr[14],
                self.sa.addr[15],
                port,
            });
            return;
        }
        const big_endian_parts = @as(*align(1) const [8]u16, @ptrCast(&self.sa.addr));
        const native_endian_parts = switch (native_endian) {
            .big => big_endian_parts.*,
            .little => blk: {
                var buf: [8]u16 = undefined;
                for (big_endian_parts, 0..) |part, i| {
                    buf[i] = mem.bigToNative(u16, part);
                }
                break :blk buf;
            },
        };

        var longest_start: usize = 8;
        var longest_len: usize = 0;
        var current_start: usize = 0;
        var current_len: usize = 0;

        for (native_endian_parts, 0..) |part, i| {
            if (part == 0) {
                if (current_len == 0) current_start = i;
                current_len += 1;
                if (current_len > longest_len) {
                    longest_start = current_start;
                    longest_len = current_len;
                }
            } else {
                current_len = 0;
            }
        }

        if (longest_len < 2) {
            longest_start = 8;
            longest_len = 0;
        }

        try writer.writeAll("[");
        var i: usize = 0;
        var abbrv = false;
        while (i < native_endian_parts.len) : (i += 1) {
            if (i == longest_start) {
                if (!abbrv) {
                    try writer.writeAll(if (i == 0) "::" else ":");
                    abbrv = true;
                }
                i += longest_len - 1;
                continue;
            }
            if (abbrv) abbrv = false;
            try writer.print("{x}", .{native_endian_parts[i]});
            if (i != native_endian_parts.len - 1) try writer.writeAll(":");
        }
        try writer.print("]:{}", .{port});
    }

    pub fn getOsSockLen(self: Ip6Address) posix.socklen_t {
        _ = self;
        return @sizeOf(posix.sockaddr.in6);
    }
};

pub fn tcpConnectToAddress(address: Address) !std.Io.net.Stream {
    const stream = try std.Io.net.Socket.create(.{
        .domain = address.any.family,
        .mode = .stream,
        .protocol = .tcp,
        .close_on_exec = true,
    });
    errdefer stream.close();
    try stream.connect(&address.any, address.getOsSockLen());
    return stream;
}
