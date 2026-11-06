//! Lenient readers for JSON from the server: a missing or mistyped field reads as null.
const std = @import("std");

pub const Value = std.json.Value;

pub fn get(v: ?Value, key: []const u8) ?Value {
    const o = v orelse return null;
    return switch (o) {
        .object => |m| m.get(key),
        else => null,
    };
}

pub fn str(v: ?Value, key: []const u8) ?[]const u8 {
    return switch (get(v, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn int(v: ?Value, key: []const u8) ?i64 {
    return switch (get(v, key) orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn float(v: ?Value, key: []const u8) ?f64 {
    return asFloat(get(v, key));
}

pub fn asFloat(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn boolean(v: ?Value, key: []const u8) ?bool {
    return switch (get(v, key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn array(v: ?Value, key: []const u8) []const Value {
    return switch (get(v, key) orelse return &.{}) {
        .array => |a| a.items,
        else => &.{},
    };
}

pub fn isObject(v: ?Value) bool {
    return v != null and v.? == .object;
}

/// Already-encoded JSON, written as is. Lets a request be built now and sent later.
pub const Raw = struct {
    text: []const u8,

    pub fn jsonStringify(r: Raw, jw: anytype) !void {
        try jw.print("{s}", .{r.text});
    }
};
