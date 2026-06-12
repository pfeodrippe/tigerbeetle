//! Compatibility helpers for Zig's 0.17 compile-time reflection API.

const std = @import("std");

pub fn name_cast(comptime Target: type, comptime value: anytype) Target {
    const Value = @TypeOf(value);
    const name = comptime switch (@typeInfo(Value)) {
        .@"enum", .enum_literal => @tagName(value),
        .pointer => value,
        .array => &value,
        else => @compileError(
            "expected enum value or field name, found '" ++ @typeName(Value) ++ "'",
        ),
    };
    return @field(Target, name);
}

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque = null,
    is_comptime: bool = false,
    alignment: comptime_int = 0,

    pub fn defaultValue(comptime field: StructField) ?field.type {
        const ptr: *const field.type = @ptrCast(@alignCast(
            field.default_value_ptr orelse return null,
        ));
        return ptr.*;
    }
};

pub const UnionField = struct {
    name: [:0]const u8,
    type: type,
    alignment: comptime_int = 0,
};

pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

pub const ErrorField = struct {
    name: [:0]const u8,
};

pub fn fields(comptime T: type) switch (@typeInfo(T)) {
    .@"struct" => [@typeInfo(T).@"struct".field_names.len]StructField,
    .@"union" => [@typeInfo(T).@"union".field_names.len]UnionField,
    .@"enum" => [@typeInfo(T).@"enum".field_names.len]EnumField,
    .error_set => [@typeInfo(T).error_set.error_names.?.len]ErrorField,
    else => @compileError("Expected struct, union, enum or error set type, found '" ++
        @typeName(T) ++ "'"),
} {
    return comptime switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var result: [info.field_names.len]StructField = undefined;
            for (
                info.field_names,
                info.field_types,
                info.field_attrs,
                0..,
            ) |name, field_type, attrs, i| {
                result[i] = .{
                    .name = name,
                    .type = field_type,
                    .default_value_ptr = attrs.default_value_ptr,
                    .is_comptime = attrs.@"comptime",
                    .alignment = attrs.@"align" orelse @alignOf(field_type),
                };
            }
            break :blk result;
        },
        .@"union" => |info| blk: {
            var result: [info.field_names.len]UnionField = undefined;
            for (
                info.field_names,
                info.field_types,
                info.field_attrs,
                0..,
            ) |name, field_type, attrs, i| {
                result[i] = .{
                    .name = name,
                    .type = field_type,
                    .alignment = attrs.@"align" orelse @alignOf(field_type),
                };
            }
            break :blk result;
        },
        .@"enum" => |info| blk: {
            var result: [info.field_names.len]EnumField = undefined;
            for (info.field_names, info.field_values, 0..) |name, value, i| {
                result[i] = .{ .name = name, .value = value };
            }
            break :blk result;
        },
        .error_set => |info| blk: {
            var result: [info.error_names.?.len]ErrorField = undefined;
            for (info.error_names.?, 0..) |name, i| {
                result[i] = .{ .name = name };
            }
            break :blk result;
        },
        else => unreachable,
    };
}

pub fn StructType(
    comptime layout: std.builtin.Type.ContainerLayout,
    comptime struct_fields: []const StructField,
) type {
    var field_names: [struct_fields.len][:0]const u8 = undefined;
    var field_types: [struct_fields.len]type = undefined;
    var field_attrs: [struct_fields.len]std.builtin.Type.Struct.FieldAttributes = undefined;

    for (struct_fields, 0..) |field, i| {
        field_names[i] = field.name;
        field_types[i] = field.type;
        field_attrs[i] = .{
            .@"comptime" = field.is_comptime,
            .@"align" = field.alignment,
            .default_value_ptr = field.default_value_ptr,
        };
    }

    return @Struct(layout, null, &field_names, &field_types, &field_attrs);
}

pub fn UnionType(
    comptime layout: std.builtin.Type.ContainerLayout,
    comptime tag_type: ?type,
    comptime union_fields: []const UnionField,
) type {
    var field_names: [union_fields.len][:0]const u8 = undefined;
    var field_types: [union_fields.len]type = undefined;
    var field_attrs: [union_fields.len]std.builtin.Type.Union.FieldAttributes = undefined;

    for (union_fields, 0..) |field, i| {
        field_names[i] = field.name;
        field_types[i] = field.type;
        field_attrs[i] = .{ .@"align" = field.alignment };
    }

    return @Union(layout, tag_type, &field_names, &field_types, &field_attrs);
}

pub fn EnumType(
    comptime tag_type: type,
    comptime mode: std.builtin.Type.Enum.Mode,
    comptime enum_fields: []const EnumField,
) type {
    var field_names: [enum_fields.len][:0]const u8 = undefined;
    var field_values: [enum_fields.len]tag_type = undefined;

    for (enum_fields, 0..) |field, i| {
        field_names[i] = field.name;
        field_values[i] = @intCast(field.value);
    }

    return @Enum(tag_type, mode, &field_names, &field_values);
}
