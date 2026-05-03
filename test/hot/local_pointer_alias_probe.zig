const std = @import("std");

fn acquireLocal(ptr: *i64) *i64 {
    return ptr;
}

pub fn read_after_bump(seed: i64) i64 {
    var value = seed;
    const ptr = acquireLocal(&value);
    ptr.* += 2;
    return value;
}

pub fn cast_memset_score(seed: i64) i64 {
    var items: [4]i64 = .{ seed, seed + 1, seed + 2, seed + 3 };
    @memset(@as([]i64, @ptrCast(items[0..])), 6);
    return items[0] * 1000 + items[1] * 100 + items[2] * 10 + items[3];
}

pub fn deref_slice_score(seed: i64) i64 {
    var items: [4]i64 = .{ seed, seed + 1, seed + 2, seed + 3 };
    const ptr = &items;
    @memset(ptr.*[1..3], 7);
    return items[0] * 1000 + items[1] * 100 + items[2] * 10 + items[3];
}

const Holder = struct {
    items: [3]i64,
};

const Limit = union(enum) {
    count: i64,
    none,
};

pub fn pointer_capture_field_score(seed: i64) i64 {
    var holder = Holder{ .items = .{ seed, seed + 1, seed + 2 } };
    for (holder.items[0..]) |*item| {
        item.* += 10;
    }
    return holder.items[0] * 100 + holder.items[1] * 10 + holder.items[2];
}

pub fn array_address_alias_score(seed: i64) i64 {
    var items: [3]i64 = .{ seed, seed + 1, seed + 2 };
    const ptr = &items[1];
    ptr.* += 20;
    return items[0] * 100 + items[1] * 10 + items[2];
}

pub fn field_address_alias_score(seed: i64) i64 {
    var holder = Holder{ .items = .{ seed, seed + 1, seed + 2 } };
    const ptr = &holder.items[1];
    ptr.* += 30;
    return holder.items[0] * 100 + holder.items[1] * 10 + holder.items[2];
}

pub fn address_of_field_pointer_capture_score(seed: i64) i64 {
    var holder = Holder{ .items = .{ seed, seed + 1, seed + 2 } };
    for (&holder.items) |*item| {
        item.* += 10;
    }
    return holder.items[0] * 100 + holder.items[1] * 10 + holder.items[2];
}

pub fn switch_pointer_payload_score(seed: i64) i64 {
    var holder = .{ .limit = Limit{ .count = seed } };
    switch (holder.limit) {
        .count => |*value| value.* += 10,
        .none => {},
    }
    return switch (holder.limit) {
        .count => |value| value,
        .none => 0,
    };
}

pub fn nested_pointer_alias_score(seed: i64) i64 {
    var value = seed;
    while (value < seed + 1) {
        const ptr = &value;
        ptr.* += 10;
    }
    return value;
}

pub fn for_value_pointer_score(seed: i64) i64 {
    var a = seed;
    var b = seed + 1;
    var ptrs: [2]*i64 = .{ &a, &b };
    for (ptrs[0..]) |ptr| {
        ptr.* += 10;
    }
    return a * 10 + b;
}

pub fn bytes_view_memset_score(seed: u64) i64 {
    var items: [3]u64 = .{ seed, seed + 1, seed + 2 };
    @memset(std.mem.bytesAsSlice(u64, std.mem.sliceAsBytes(items[0..])), seed + 4);
    return @intCast(items[0] * 100 + items[1] * 10 + items[2]);
}

pub fn nested_local_memcpy_score(seed: i64) i64 {
    var dst: [3]i64 = .{ 0, 0, 0 };
    {
        var src: [3]i64 = .{ seed, seed + 1, seed + 2 };
        @memcpy(dst[0..], src[0..]);
    }
    return dst[0] * 100 + dst[1] * 10 + dst[2];
}
