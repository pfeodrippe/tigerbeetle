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

pub fn pointer_capture_field_score(seed: i64) i64 {
    var holder = Holder{ .items = .{ seed, seed + 1, seed + 2 } };
    for (holder.items[0..]) |*item| {
        item.* += 10;
    }
    return holder.items[0] * 100 + holder.items[1] * 10 + holder.items[2];
}
