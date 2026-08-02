const std = @import("std");
const windows = std.os.windows;
const assert = std.debug.assert;

/// Kernel ABI types removed from Zig's public `std.os.windows` surface in 0.16.
/// TigerBeetle uses them directly for its IOCP backend.
pub const OVERLAPPED = extern struct {
    Internal: windows.ULONG_PTR,
    InternalHigh: windows.ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: windows.DWORD,
            OffsetHigh: windows.DWORD,
        },
        Pointer: ?windows.PVOID,
    },
    hEvent: ?windows.HANDLE,
};

pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: windows.ULONG_PTR,
    lpOverlapped: *OVERLAPPED,
    Internal: windows.ULONG_PTR,
    dwNumberOfBytesTransferred: windows.DWORD,
};

pub const WSABUF = extern struct {
    len: windows.ULONG,
    buf: [*]u8,
};

pub const SOCKET_ERROR = -1;

pub const WSAID_CONNECTEX = windows.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};

pub const SIO_GET_EXTENSION_FUNCTION_POINTER: u32 =
    1 << 30 | 1 << 31 | 1 << 27 | 6;

pub const SO_UPDATE_ACCEPT_CONTEXT = 28683;
pub const SO_UPDATE_CONNECT_CONTEXT = 28688;

pub const WinsockError = enum(i32) {
    WSA_INVALID_HANDLE = 6,
    WSA_NOT_ENOUGH_MEMORY = 8,
    WSA_INVALID_PARAMETER = 87,
    WSA_OPERATION_ABORTED = 995,
    WSA_IO_INCOMPLETE = 996,
    WSA_IO_PENDING = 997,
    WSAEINTR = 10004,
    WSAEBADF = 10009,
    WSAEACCES = 10013,
    WSAEFAULT = 10014,
    WSAEINVAL = 10022,
    WSAEMFILE = 10024,
    WSAEWOULDBLOCK = 10035,
    WSAEINPROGRESS = 10036,
    WSAEALREADY = 10037,
    WSAENOTSOCK = 10038,
    WSAEMSGSIZE = 10040,
    WSAEPROTOTYPE = 10041,
    WSAENOPROTOOPT = 10042,
    WSAEOPNOTSUPP = 10045,
    WSAEAFNOSUPPORT = 10047,
    WSAEADDRINUSE = 10048,
    WSAEADDRNOTAVAIL = 10049,
    WSAENETDOWN = 10050,
    WSAENETUNREACH = 10051,
    WSAENETRESET = 10052,
    WSAECONNABORTED = 10053,
    WSAECONNRESET = 10054,
    WSAENOBUFS = 10055,
    WSAEISCONN = 10056,
    WSAENOTCONN = 10057,
    WSAESHUTDOWN = 10058,
    WSAETIMEDOUT = 10060,
    WSAECONNREFUSED = 10061,
    WSAEHOSTUNREACH = 10065,
    WSAEPROCLIM = 10067,
    WSASYSNOTREADY = 10091,
    WSAVERNOTSUPPORTED = 10092,
    WSANOTINITIALISED = 10093,
    WSAEDISCON = 10101,
    _,
};

extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WinsockError;

pub fn wsa_get_last_error() WinsockError {
    return WSAGetLastError();
}

pub fn unexpected_wsa_error(err: WinsockError) error{Unexpected} {
    if (std.options.unexpected_error_tracing) {
        std.debug.print("error.Unexpected: WSAGetLastError({d}): {t}\n", .{ err, err });
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    }
    return error.Unexpected;
}

const WSADESCRIPTION_LEN = 256;
const WSASYS_STATUS_LEN = 128;

const WSADATA = if (@sizeOf(usize) == @sizeOf(u64))
    extern struct {
        wVersion: windows.WORD,
        wHighVersion: windows.WORD,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: *u8,
        szDescription: [WSADESCRIPTION_LEN + 1]u8,
        szSystemStatus: [WSASYS_STATUS_LEN + 1]u8,
    }
else
    extern struct {
        wVersion: windows.WORD,
        wHighVersion: windows.WORD,
        szDescription: [WSADESCRIPTION_LEN + 1]u8,
        szSystemStatus: [WSASYS_STATUS_LEN + 1]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: *u8,
    };

extern "ws2_32" fn WSAStartup(
    wVersionRequired: windows.WORD,
    lpWSAData: *WSADATA,
) callconv(.winapi) i32;

extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;

pub fn wsa_startup(major_version: u8, minor_version: u8) !void {
    var data: WSADATA = undefined;
    return switch (WSAStartup((@as(windows.WORD, minor_version) << 8) | major_version, &data)) {
        0 => {},
        10091 => error.SystemNotAvailable,
        10092 => error.VersionNotSupported,
        10036 => error.BlockingOperationInProgress,
        10067 => error.ProcessFdQuotaExceeded,
        else => error.Unexpected,
    };
}

pub fn wsa_cleanup() !void {
    return switch (WSACleanup()) {
        0 => {},
        -1 => error.Unexpected,
        else => unreachable,
    };
}

pub fn query_performance_frequency() u64 {
    var result: windows.LARGE_INTEGER = undefined;
    assert(windows.ntdll.RtlQueryPerformanceFrequency(&result) != .FALSE);
    return @bitCast(result);
}

pub fn query_performance_counter() u64 {
    var result: windows.LARGE_INTEGER = undefined;
    assert(windows.ntdll.RtlQueryPerformanceCounter(&result) != .FALSE);
    return @bitCast(result);
}

extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;

pub fn get_last_error() windows.Win32Error {
    return @enumFromInt(GetLastError());
}

extern "kernel32" fn CreateIoCompletionPort(
    file_handle: windows.HANDLE,
    existing_completion_port: ?windows.HANDLE,
    completion_key: usize,
    concurrent_thread_count: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

pub fn create_io_completion_port(
    file_handle: windows.HANDLE,
    existing_completion_port: ?windows.HANDLE,
    completion_key: usize,
    concurrent_thread_count: windows.DWORD,
) !windows.HANDLE {
    return CreateIoCompletionPort(
        file_handle,
        existing_completion_port,
        completion_key,
        concurrent_thread_count,
    ) orelse switch (get_last_error()) {
        .INVALID_PARAMETER => unreachable,
        else => |err| windows.unexpectedError(err),
    };
}

extern "kernel32" fn PostQueuedCompletionStatus(
    completion_port: windows.HANDLE,
    bytes_transferred_count: windows.DWORD,
    completion_key: usize,
    overlapped: ?*OVERLAPPED,
) callconv(.winapi) windows.BOOL;

pub fn post_queued_completion_status(
    completion_port: windows.HANDLE,
    bytes_transferred_count: windows.DWORD,
    completion_key: usize,
    overlapped: ?*OVERLAPPED,
) !void {
    if (PostQueuedCompletionStatus(
        completion_port,
        bytes_transferred_count,
        completion_key,
        overlapped,
    ) == .FALSE) return windows.unexpectedError(get_last_error());
}

extern "kernel32" fn GetQueuedCompletionStatusEx(
    completion_port: windows.HANDLE,
    completion_port_entries: [*]OVERLAPPED_ENTRY,
    completion_port_entries_count: windows.ULONG,
    entries_removed: *windows.ULONG,
    milliseconds: windows.DWORD,
    alertable: windows.BOOL,
) callconv(.winapi) windows.BOOL;

pub fn get_queued_completion_status_ex(
    completion_port: windows.HANDLE,
    completion_port_entries: []OVERLAPPED_ENTRY,
    timeout_ms: ?windows.DWORD,
    alertable: bool,
) !u32 {
    var entries_removed: windows.ULONG = 0;
    if (GetQueuedCompletionStatusEx(
        completion_port,
        completion_port_entries.ptr,
        @intCast(completion_port_entries.len),
        &entries_removed,
        timeout_ms orelse std.math.maxInt(windows.DWORD),
        @enumFromInt(@intFromBool(alertable)),
    ) == .FALSE) {
        return switch (get_last_error()) {
            .ABANDONED_WAIT_0 => error.Aborted,
            .OPERATION_ABORTED => error.Cancelled,
            .HANDLE_EOF => error.EOF,
            .WAIT_TIMEOUT => error.Timeout,
            else => |err| windows.unexpectedError(err),
        };
    }
    return entries_removed;
}

extern "kernel32" fn SetFileCompletionNotificationModes(
    handle: windows.HANDLE,
    flags: windows.BYTE,
) callconv(.winapi) windows.BOOL;

pub fn set_file_completion_notification_modes(
    handle: windows.HANDLE,
    flags: windows.BYTE,
) !void {
    if (SetFileCompletionNotificationModes(handle, flags) == .FALSE) {
        return windows.unexpectedError(get_last_error());
    }
}

pub extern "ws2_32" fn WSAGetOverlappedResult(
    socket: std.posix.socket_t,
    overlapped: *OVERLAPPED,
    transferred: *u32,
    wait: windows.BOOL,
    flags: *u32,
) callconv(.winapi) windows.BOOL;

pub extern "ws2_32" fn WSASend(
    socket: std.posix.socket_t,
    buffers: [*]WSABUF,
    buffer_count: u32,
    bytes_sent: ?*u32,
    flags: u32,
    overlapped: ?*OVERLAPPED,
    completion_routine: ?*const anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSARecv(
    socket: std.posix.socket_t,
    buffers: [*]WSABUF,
    buffer_count: u32,
    bytes_received: ?*u32,
    flags: *u32,
    overlapped: ?*OVERLAPPED,
    completion_routine: ?*const anyopaque,
) callconv(.winapi) i32;

pub extern "ws2_32" fn WSAIoctl(
    socket: std.posix.socket_t,
    io_control_code: u32,
    input_buffer: ?*const anyopaque,
    input_buffer_size: u32,
    output_buffer: ?*anyopaque,
    output_buffer_size: u32,
    bytes_returned: *u32,
    overlapped: ?*OVERLAPPED,
    completion_routine: ?*const anyopaque,
) callconv(.winapi) i32;

pub extern "mswsock" fn AcceptEx(
    listen_socket: std.posix.socket_t,
    accept_socket: std.posix.socket_t,
    output_buffer: *anyopaque,
    receive_data_length: u32,
    local_address_length: u32,
    remote_address_length: u32,
    bytes_received: *u32,
    overlapped: *OVERLAPPED,
) callconv(.winapi) windows.BOOL;

extern "ws2_32" fn WSASocketW(
    address_family: i32,
    socket_type: i32,
    protocol: i32,
    protocol_info: ?*anyopaque,
    group: u32,
    flags: u32,
) callconv(.winapi) std.posix.socket_t;

pub fn wsa_socket(
    address_family: i32,
    socket_type: i32,
    protocol: i32,
    flags: u32,
) !std.posix.socket_t {
    const socket = WSASocketW(address_family, socket_type, protocol, null, 0, flags);
    const invalid_socket: std.posix.socket_t = @ptrFromInt(std.math.maxInt(usize));
    if (socket != invalid_socket) return socket;
    return switch (wsa_get_last_error()) {
        .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
        .WSAEMFILE => error.ProcessFdQuotaExceeded,
        .WSAENOBUFS => error.SystemResources,
        .WSANOTINITIALISED => error.Unexpected,
        else => |err| unexpected_wsa_error(err),
    };
}

pub extern "ws2_32" fn getsockopt(
    socket: std.posix.socket_t,
    level: i32,
    option_name: i32,
    option_value: [*]u8,
    option_length: *i32,
) callconv(.winapi) i32;

pub extern "ws2_32" fn setsockopt(
    socket: std.posix.socket_t,
    level: i32,
    option_name: i32,
    option_value: ?[*]const u8,
    option_length: i32,
) callconv(.winapi) i32;

pub fn set_socket_option(
    socket: std.posix.socket_t,
    level: i32,
    option_name: u32,
    option_value: []const u8,
) !void {
    if (setsockopt(
        socket,
        level,
        @intCast(option_name),
        option_value.ptr,
        @intCast(option_value.len),
    ) != SOCKET_ERROR) return;
    return switch (wsa_get_last_error()) {
        .WSANOTINITIALISED, .WSAEFAULT => unreachable,
        .WSAENETDOWN => error.NetworkSubsystemFailed,
        .WSAENOTSOCK => error.FileDescriptorNotASocket,
        .WSAEINVAL => error.SocketNotBound,
        else => |err| unexpected_wsa_error(err),
    };
}

extern "ws2_32" fn bind(
    socket: std.posix.socket_t,
    address: *const std.posix.sockaddr,
    address_length: i32,
) callconv(.winapi) i32;

pub fn bind_socket(
    socket: std.posix.socket_t,
    address: *const std.posix.sockaddr,
    address_length: std.posix.socklen_t,
) (error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    FileDescriptorNotASocket,
    AlreadyBound,
    SystemResources,
    NetworkSubsystemFailed,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    ReadOnlyFileSystem,
} || std.posix.UnexpectedError)!void {
    if (bind(socket, address, @intCast(address_length)) != SOCKET_ERROR) return;
    return switch (wsa_get_last_error()) {
        .WSANOTINITIALISED, .WSAEFAULT => unreachable,
        .WSAEACCES => error.AccessDenied,
        .WSAEADDRINUSE => error.AddressInUse,
        .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
        .WSAENOTSOCK => error.FileDescriptorNotASocket,
        .WSAEINVAL => error.AlreadyBound,
        .WSAENOBUFS => error.SystemResources,
        .WSAENETDOWN => error.NetworkSubsystemFailed,
        else => |err| unexpected_wsa_error(err),
    };
}

pub extern "ws2_32" fn closesocket(socket: std.posix.socket_t) callconv(.winapi) i32;

extern "ws2_32" fn shutdown(
    socket: std.posix.socket_t,
    how: i32,
) callconv(.winapi) i32;

pub fn shutdown_compat(socket: std.posix.socket_t, how: std.Io.net.ShutdownHow) !void {
    const result = shutdown(socket, switch (how) {
        .recv => 0,
        .send => 1,
        .both => 2,
    });
    if (result == 0) return;
    return switch (wsa_get_last_error()) {
        .WSAECONNABORTED => error.ConnectionAborted,
        .WSAECONNRESET => error.ConnectionResetByPeer,
        .WSAEINPROGRESS => error.BlockingOperationInProgress,
        .WSAEINVAL, .WSAENOTSOCK, .WSANOTINITIALISED => unreachable,
        .WSAENETDOWN => error.NetworkSubsystemFailed,
        .WSAENOTCONN => error.SocketNotConnected,
        else => |err| unexpected_wsa_error(err),
    };
}

pub extern "kernel32" fn GetSystemTimePreciseAsFileTime(
    lpFileTime: *windows.FILETIME,
) callconv(.winapi) void;

pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) windows.LPWSTR;

pub extern "kernel32" fn GetProcessTimes(
    in_hProcess: windows.HANDLE,
    out_lpCreationTime: *windows.FILETIME,
    out_lpExitTime: *windows.FILETIME,
    out_lpKernelTime: *windows.FILETIME,
    out_lpUserTime: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetProcessWorkingSetSize(
    hProcess: windows.HANDLE,
    dwMinimumWorkingSetSize: windows.SIZE_T,
    dwMaximumWorkingSetSize: windows.SIZE_T,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetProcessWorkingSetSize(
    hProcess: windows.HANDLE,
    lpMinimumWorkingSetSize: *windows.SIZE_T,
    lpMaximumWorkingSetSize: *windows.SIZE_T,
) callconv(.winapi) windows.BOOL;

pub const LOCKFILE_EXCLUSIVE_LOCK = 0x2;
pub const LOCKFILE_FAIL_IMMEDIATELY = 0x1;
pub extern "kernel32" fn LockFileEx(
    hFile: windows.HANDLE,
    dwFlags: windows.DWORD,
    dwReserved: windows.DWORD,
    nNumberOfBytesToLockLow: windows.DWORD,
    nNumberOfBytesToLockHigh: windows.DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetEndOfFile(
    hFile: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) windows.BOOL;
