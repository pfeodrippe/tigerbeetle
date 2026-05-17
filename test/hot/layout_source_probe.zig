const imported = @import("layout_source_import.zig");

pub fn imported_layout_size_score(seed: i64) i64 {
    return seed + @sizeOf(imported.Payload);
}
