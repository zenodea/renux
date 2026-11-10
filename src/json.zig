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
        .float => |f| intOf(f),
        else => null,
    };
}

/// A float as a whole number, or null when it isn't one an i64 can hold: the cast itself is
/// undefined for NaN, infinity and anything out of range.
fn intOf(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    const t = @trunc(f);
    // Both bounds are exact as f64; the upper one is 2^63, the first value that doesn't fit.
    if (t < -9223372036854775808.0 or t >= 9223372036854775808.0) return null;
    return @intFromFloat(t);
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

test "int reads whole numbers and refuses what an i64 can't hold" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"a\":7,\"b\":2.9,\"c\":1e300,\"d\":-1e300,\"e\":\"x\",\"f\":-3.5,\"g\":9223372036854775808.0}", .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqual(@as(?i64, 7), int(v, "a"));
    try std.testing.expectEqual(@as(?i64, 2), int(v, "b"));
    try std.testing.expectEqual(@as(?i64, null), int(v, "c"));
    try std.testing.expectEqual(@as(?i64, null), int(v, "d"));
    try std.testing.expectEqual(@as(?i64, null), int(v, "e"));
    try std.testing.expectEqual(@as(?i64, -3), int(v, "f"));
    try std.testing.expectEqual(@as(?i64, null), int(v, "g"));
    try std.testing.expectEqual(@as(?i64, null), int(v, "missing"));
    try std.testing.expectEqual(@as(?i64, null), intOf(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?i64, null), intOf(std.math.inf(f64)));
}
