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

const Filter = struct {
    min: i64,
    max: i64,
};

const Limit = union(enum) {
    count: i64,
    none,
};

const FieldEnum = enum(u8) {
    a = 1,
    b = 2,
    c = 3,
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

pub fn type_info_integer_bits_score(seed: i64) i64 {
    const bits = @typeInfo(u8).int.bits;
    if (@typeInfo(u8).int.signedness != .unsigned) {
        @compileError("unsigned integer expected");
    }
    return bits + seed;
}

const Hash = u64;
const FingerPrint = u7;

pub fn type_info_alias_bits_score(seed: i64) i64 {
    const hash_bits = @typeInfo(Hash).int.bits;
    const fp_bits = @typeInfo(FingerPrint).int.bits;
    return seed + hash_bits - fp_bits;
}

pub fn type_info_if_tag_score(seed: i64) i64 {
    if (@typeInfo(u8) == .int) return seed + 12;
    return seed;
}

pub fn type_info_enum_fields_score(seed: i64) i64 {
    const fields = @typeInfo(FieldEnum).@"enum".fields;
    var total = seed;
    inline for (fields) |field| {
        total += field.value;
    }
    return total;
}

pub fn type_info_fields_index_score(seed: i64) i64 {
    const fields = @typeInfo(FieldEnum).@"enum".fields;
    var total = seed;
    inline for (fields, 0..) |field, index| {
        total += field.value * @as(i64, @intCast(index + 1));
    }
    return total;
}

pub fn compile_error_guard_score(seed: i64) i64 {
    if (@TypeOf(seed) != i64) {
        @compileError("unexpected seed type");
    }
    return seed + 9;
}

pub fn catch_pointer_alias_score(seed: i64) i64 {
    var value = seed;
    const result: error{Nope}!*i64 = &value;
    const ptr = result catch return 0;
    ptr.* += 14;
    return value;
}

pub fn orelse_pointer_alias_score(seed: i64) i64 {
    var value = seed;
    var maybe: ?*i64 = &value;
    const slot = &maybe;
    const ptr = slot.* orelse return 0;
    ptr.* += 16;
    return value;
}

pub fn optional_pointer_payload_score(seed: i64) i64 {
    var holder = .{ .value = @as(?i64, seed) };
    if (holder.value) |*value| {
        value.* += 18;
    }
    return holder.value.?;
}

pub fn zipped_pointer_capture_score(seed: i64) i64 {
    var left: [2]i64 = .{ seed, seed + 1 };
    var right: [2]i64 = .{ seed + 2, seed + 3 };
    for (left[0..], right[0..]) |*a, *b| {
        a.* += 10;
        b.* += 20;
    }
    return left[0] * 1000 + left[1] * 100 + right[0] * 10 + right[1];
}

pub fn labeled_block_pointer_alias_score(seed: i64) i64 {
    var value = seed;
    const ptr = block: {
        break :block &value;
    };
    ptr.* += 22;
    return value;
}

pub fn labeled_block_struct_store_score(seed: i64) i64 {
    var filters: [1]Filter = .{.{ .min = 0, .max = 0 }};
    const filter: *Filter = block: {
        break :block &filters[0];
    };
    filter.* = .{ .min = seed, .max = seed + 10 };
    return filters[0].min * 10 + filters[0].max;
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
