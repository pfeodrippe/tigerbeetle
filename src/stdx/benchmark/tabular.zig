const std = @import("std");
const assert = std.debug.assert;

pub fn TabularOutputType(comptime row_types: []const type) type {
    return struct {
        const TabularOutput = @This();
        pub const Row = ConcatStructsType(row_types);

        writer: *std.Io.Writer,

        pub fn init(writer: *std.Io.Writer, options: struct {
            header: bool = true,
        }) !TabularOutput {
            var output: TabularOutput = .{ .writer = writer };
            if (options.header) {
                try output.write_header();
            }
            return output;
        }

        fn write_header(tabular_output: *TabularOutput) !void {
            inline for (@typeInfo(Row).@"struct".field_names, 0..) |name, index| {
                if (index > 0) try tabular_output.writer.writeAll(", ");
                try tabular_output.writer.print("{s: >4}", .{name});
            }
            try tabular_output.writer.writeAll("\n");
        }

        pub inline fn write_row(tabular_output: *TabularOutput, row: *const Row) !void {
            const info = @typeInfo(Row).@"struct";
            inline for (info.field_names, info.field_types, 0..) |name, T, index| {
                if (index > 0) try tabular_output.writer.writeAll(", ");
                const cell_fmt = switch (@typeInfo(T)) {
                    .int => "{[field_value]d: >[field_width]}",
                    .float => "{[field_value]d: >[field_width].2}",
                    .pointer => "{[field_value]s: >[field_width]}",
                    .bool => "{[field_value]: >[field_width]}",
                    .@"enum" => "{[field_value]any: >[field_width]}",
                    else => @panic("Type not supported for serialization"),
                };
                try tabular_output.writer.print(cell_fmt, .{
                    .field_value = @field(row, name),
                    .field_width = @max(name.len, 4),
                });
            }
            try tabular_output.writer.writeAll("\n");
        }

        pub inline fn row_from_bag(bag: anytype) ConcatStructsType(@typeInfo(@TypeOf(bag)).@"struct".field_types) {
            const info = @typeInfo(@TypeOf(bag)).@"struct";
            var result: ConcatStructsType(info.field_types) = undefined;

            var fields_set: u64 = 0;
            inline for (info.field_names, info.field_types) |outer_name, T| {
                assert(@typeInfo(T) == .@"struct");
                const value_outer = @field(bag, outer_name);
                inline for (@typeInfo(T).@"struct".field_names) |name| {
                    fields_set += 1;
                    @field(result, name) = @field(value_outer, name);
                }
            }

            assert(fields_set == @typeInfo(@TypeOf(result)).@"struct".field_names.len);
            return result;
        }
    };
}

fn ConcatStructsType(comptime types: []const type) type {
    comptime var names: []const [:0]const u8 = &.{};
    comptime var field_types: []const type = &.{};
    comptime var attrs: []const std.lang.Type.Struct.FieldAttributes = &.{};
    inline for (types) |t| {
        const struct_type = @typeInfo(t).@"struct";
        assert(struct_type.layout == .auto);
        assert(!struct_type.is_tuple);

        names = names ++ struct_type.field_names;
        field_types = field_types ++ struct_type.field_types;
        attrs = attrs ++ struct_type.field_attrs;
    }

    return @Struct(.auto, null, names, field_types, attrs);
}

test "tabular output concatenates reflected fields" {
    const Left = struct { a: u32 };
    const Right = struct { b: bool };
    const Output = TabularOutputType(&.{ Left, Right });
    const row = Output.row_from_bag(.{ Left{ .a = 5 }, Right{ .b = true } });
    try std.testing.expectEqual(@as(u32, 5), row.a);
    try std.testing.expect(row.b);

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var output = try Output.init(&writer, .{});
    try output.write_row(&row);
    try std.testing.expectEqualStrings("   a,    b\n   5, true\n", writer.buffered());
}
