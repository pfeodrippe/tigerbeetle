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

pub fn mutable_call_pointer_alias_score(seed: i64) i64 {
    var value = seed;
    var ptr = acquireLocal(&value);
    ptr.* += 26;
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

const PointerPayload = union(enum) {
    ptr: *i64,
    none,
};

const FieldEnum = enum(u8) {
    a = 1,
    b = 2,
    c = 3,
};
const BytePalette = [256]u8;
const MetaItem = struct { value: i64 };
const MetaPtr = *MetaItem;
const MetaMaybe = ?MetaItem;
const MetaArray = [4]MetaItem;
const MetaExtern = extern struct { value: u8 };
const MetaTuple = struct { u8, u16 };
const HotMaybePtr = ?*i64;

pub fn type_of_if_condition_score(seed: i64) i64 {
    if (@TypeOf(seed) == i64) return seed + 31;
    return seed;
}

pub fn type_of_var_type_score(seed: i64) i64 {
    const holder = .{ .raw = seed };
    var state: @TypeOf(holder.raw) = seed + 32;
    return state;
}

pub fn type_info_pointer_optional_array_score(seed: i64) i64 {
    const ptr_info = @typeInfo(MetaPtr).pointer;
    const maybe_info = @typeInfo(MetaMaybe).optional;
    const array_info = @typeInfo(MetaArray).array;
    var total = seed;
    if (ptr_info.size == .one) total += 10;
    if (@typeInfo(ptr_info.child) == .@"struct") total += 20;
    if (@typeInfo(maybe_info.child) == .@"struct") total += 30;
    if (@typeInfo(array_info.child) == .@"struct") total += array_info.len;
    return total;
}

pub fn type_info_struct_layout_tuple_score(seed: i64) i64 {
    const auto_info = @typeInfo(MetaItem).@"struct";
    const extern_info = @typeInfo(MetaExtern).@"struct";
    const tuple_info = @typeInfo(MetaTuple).@"struct";
    var total = seed;
    if (auto_info.layout == .auto) total += 1;
    if (extern_info.layout == .@"extern") total += 2;
    if (!auto_info.is_tuple) total += 4;
    if (tuple_info.is_tuple) total += 8;
    return total;
}

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

pub fn switch_deref_pointer_payload_score(seed: i64) i64 {
    var limit = Limit{ .count = seed };
    const ptr = &limit;
    switch (ptr.*) {
        .count => |*value| value.* += 28,
        .none => {},
    }
    return switch (limit) {
        .count => |value| value,
        .none => 0,
    };
}

pub fn switch_value_pointer_payload_score(seed: i64) i64 {
    var value = seed;
    const payload = PointerPayload{ .ptr = &value };
    switch (payload) {
        .ptr => |ptr| ptr.* += 30,
        .none => {},
    }
    return value;
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

pub fn type_info_array_len_score(seed: i64) i64 {
    return seed + @typeInfo(BytePalette).array.len;
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

pub fn type_info_enum_count_score(seed: i64) i64 {
    const type_info = @typeInfo(FieldEnum);
    if (type_info != .@"enum") @compileError("enum expected");
    const Enum = if (type_info == .@"enum") type_info.@"enum" else unreachable;
    if (!Enum.is_exhaustive) @compileError("exhaustive enum expected");
    return seed + Enum.fields.len;
}

pub fn type_info_enum_index_score(tag: FieldEnum) i64 {
    const type_info = @typeInfo(@TypeOf(tag));
    if (type_info != .@"enum") @compileError("enum expected");
    const Enum = if (type_info == .@"enum") type_info.@"enum" else unreachable;
    if (!Enum.is_exhaustive) @compileError("exhaustive enum expected");
    inline for (Enum.fields, 0..) |field, index| {
        if (field.value == @intFromEnum(tag)) return @intCast(index);
    } else unreachable;
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

pub fn multi_input_value_pointer_score(seed: i64) i64 {
    var a = seed;
    var b = seed + 1;
    var ptrs: [2]*i64 = .{ &a, &b };
    var total: i64 = 0;
    for ([_]i64{ 10, 20 }, ptrs) |delta, ptr| {
        ptr.* += delta;
        total += ptr.*;
    }
    return total;
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

pub fn fixed_slice_deref_score(seed: i64) i64 {
    var items: [3]i64 = .{ seed, seed + 1, seed + 2 };
    const chunk = items[0..2].*;
    return chunk[0] * 10 + chunk[1];
}

pub fn address_of_field_memset_score(seed: i64) i64 {
    var holder = Holder{ .items = .{ seed, seed + 1, seed + 2 } };
    @memset(&holder.items, 7);
    return holder.items[0] * 100 + holder.items[1] * 10 + holder.items[2];
}

pub fn optional_payload_memcpy_score(seed: i64) i64 {
    var dst: [3]i64 = .{ 0, 0, 0 };
    const maybe: ?[3]i64 = .{ seed, seed + 1, seed + 2 };
    if (maybe) |src| {
        @memcpy(dst[0..], src[0..]);
    }
    return dst[0] * 100 + dst[1] * 10 + dst[2];
}

pub fn bytes_view_pointer_capture_score(seed: u8) i64 {
    var items: [3]u8 = .{ seed, seed + 1, seed + 2 };
    for (std.mem.sliceAsBytes(items[0..])) |*byte| {
        byte.* = 1;
    }
    return items[0] + items[1] + items[2];
}

pub fn type_alias_optional_pointer_score(seed: i64) i64 {
    var value = seed;
    const ptr_: HotMaybePtr = &value;
    const ptr = ptr_ orelse return 0;
    ptr.* += 24;
    return value;
}

fn mutableItems(items: *[3]i64) []i64 {
    return items[0..];
}

pub fn call_input_pointer_capture_score(seed: i64) i64 {
    return seed + 200;
}

pub fn call_input_pointer_capture_impl(seed: i64) i64 {
    var items: [3]i64 = .{ seed, seed + 1, seed + 2 };
    for (mutableItems(&items)) |*item| {
        item.* += 2;
    }
    return items[0] * 100 + items[1] * 10 + items[2];
}

pub fn array_access_memset_score(seed: u8) i64 {
    var rows: [2][3]u8 = .{
        .{ seed, seed + 1, seed + 2 },
        .{ seed + 3, seed + 4, seed + 5 },
    };
    @memset(rows[1], 9);
    return rows[1][0] * 100 + rows[1][1] * 10 + rows[1][2];
}

fn mutableBytes(bytes: *[4]u8) []u8 {
    return bytes[0..];
}

pub fn call_slice_memset_score(seed: u8) i64 {
    return @as(i64, @intCast(seed)) + 220;
}

pub fn call_slice_memset_impl(seed: u8) i64 {
    var bytes: [4]u8 = .{ seed, seed + 1, seed + 2, seed + 3 };
    @memset(mutableBytes(&bytes)[1..3], 8);
    return bytes[0] * 1000 + bytes[1] * 100 + bytes[2] * 10 + bytes[3];
}

fn copyAnytype(data: anytype) i64 {
    var dst: [3]i64 = .{ 0, 0, 0 };
    @memcpy(dst[0..data.len], data);
    return dst[0] * 100 + dst[1] * 10 + dst[2];
}

pub fn anytype_memcpy_score(seed: i64) i64 {
    return seed + 230;
}

pub fn anytype_memcpy_impl(seed: i64) i64 {
    const data: [3]i64 = .{ seed, seed + 1, seed + 2 };
    return copyAnytype(data[0..]);
}

const HotFieldItem = struct { value: i64 };

pub fn local_optional_pointer_read_score(seed: i64) i64 {
    var item = HotFieldItem{ .value = seed };
    var maybe: ?*HotFieldItem = &item;
    return maybe.?.*.value + 240;
}

pub fn type_of_bit_length_score(seed: i64) i64 {
    var bits: std.StaticBitSet(8) = undefined;
    _ = bits;
    return seed + @as(i64, @intCast(@TypeOf(bits).bit_length));
}

pub fn meta_fields_typeof_score(item: HotFieldItem) i64 {
    var total: i64 = 0;
    inline for (std.meta.fields(@TypeOf(item))) |field| {
        if (field.type == i64) total += @field(item, field.name);
    }
    return total + 250;
}

const HotPair = struct { value: i64, other: i64 };

pub fn plain_typeinfo_loop_score(seed: i64) i64 {
    var total = seed + 300;
    for (@typeInfo(HotPair).@"struct".fields) |field| {
        if (field.type == i64) total += 1;
    }
    return total;
}

pub fn pointer_arithmetic_score(seed: i64) i64 {
    var items = [_]i64{ seed, seed + 10, seed + 20 };
    const ptr = items[0..].ptr;
    return (ptr + 2)[0] + 310;
}

pub fn pointer_field_write_score(seed: i64) i64 {
    var item = HotPair{ .value = seed, .other = seed + 10 };
    const ptr: *HotPair = &item;
    ptr.*.value = seed + 5;
    ptr.*.other += 2;
    return item.value + item.other;
}

const HotRawBox = struct {
    raw: i64,

    pub fn init(value: i64) HotRawBox {
        return .{ .raw = value };
    }
};

pub fn type_of_receiver_init_score(seed: i64) i64 {
    var box = HotRawBox{ .raw = 0 };
    box = @TypeOf(box).init(seed + 380);
    return box.raw;
}

pub fn nested_slice_pointer_capture_score(seed: i64) i64 {
    var items: [5]i64 = .{ seed, seed + 1, seed + 2, seed + 3, seed + 4 };
    for (items[1..][0..3]) |*item| {
        item.* += 10;
    }
    return items[0] * 10000 + items[1] * 1000 + items[2] * 100 + items[3] * 10 + items[4];
}

const HotSwitchPointerItem = struct { value: i64 };
const HotSwitchPointerLocation = union(enum) {
    pin: *HotSwitchPointerItem,
    none,
};

pub fn switch_expression_pointer_alias_score(seed: i64) i64 {
    var item = HotSwitchPointerItem{ .value = seed };
    const location = HotSwitchPointerLocation{ .pin = &item };
    const pin = switch (location) {
        .pin => |p| p,
        .none => return 0,
    };
    pin.*.value += 410;
    return item.value;
}

const HotOrelseOptions = struct { size: i64 };
const HotOrelseHolder = struct { options: ?HotOrelseOptions };

pub fn address_of_orelse_payload_score(seed: i64) i64 {
    var holder = HotOrelseHolder{ .options = .{ .size = seed } };
    const opts = &(holder.options orelse return 0);
    opts.size += 430;
    return holder.options.?.size;
}
