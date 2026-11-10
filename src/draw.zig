//! Small drawing helpers shared by the tiles, icons and pane cards.
const std = @import("std");
const gdk = @import("gdk");
const cairo = @import("cairo");
const rsvg = @import("rsvg");

const gpa = std.heap.c_allocator;

/// A rectangle with rounded corners, as a new sub-path.
pub fn roundRect(cr: *cairo.Context, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const pi: f64 = std.math.pi;
    cr.newSubPath();
    cr.arc(x + w - r, y + r, r, -pi / 2, 0);
    cr.arc(x + w - r, y + h - r, r, 0, pi / 2);
    cr.arc(x + r, y + h - r, r, pi / 2, pi);
    cr.arc(x + r, y + r, r, pi, 3 * pi / 2);
    cr.closePath();
}

/// The red, green and blue of a 0xRRGGBB color, each from 0 to 1.
pub fn channels(c: u32) [3]f64 {
    return .{
        @as(f64, @floatFromInt((c >> 16) & 0xff)) / 255,
        @as(f64, @floatFromInt((c >> 8) & 0xff)) / 255,
        @as(f64, @floatFromInt(c & 0xff)) / 255,
    };
}

/// Paints with a 0xRRGGBB color.
pub fn setColor(cr: *cairo.Context, c: u32) void {
    const ch = channels(c);
    cr.setSourceRgb(ch[0], ch[1], ch[2]);
}

/// Paints with a widget's color at a share of its own opacity.
pub fn setRgba(cr: *cairo.Context, c: gdk.RGBA, alpha: f64) void {
    cr.setSourceRgba(c.f_red, c.f_green, c.f_blue, c.f_alpha * alpha);
}

/// A widget color as 0xRRGGBB, without its opacity.
pub fn rgb(c: gdk.RGBA) u32 {
    return (byte(c.f_red) << 16) | (byte(c.f_green) << 8) | byte(c.f_blue);
}

fn byte(v: f32) u32 {
    // A color that isn't a number counts as none of it.
    if (!(v > 0)) return 0;
    return @intFromFloat(@round(@min(v, 1) * 255));
}

/// How bright a 0xRRGGBB color looks, from 0 to 1.
pub fn luma(c: u32) f64 {
    const ch = channels(c);
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}

/// A 24 by 24 icon path as an SVG, filled with `fill` (such as "#ffffff").
pub fn svgHandle(path: []const u8, transform: []const u8, fill: []const u8) ?*rsvg.Handle {
    const svg = std.fmt.allocPrint(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path fill=\"{s}\" transform=\"{s}\" d=\"{s}\"/></svg>", .{ fill, transform, path }) catch return null;
    defer gpa.free(svg);
    return rsvg.Handle.newFromData(svg.ptr, svg.len, null);
}

test "colors convert both ways" {
    try std.testing.expectEqual(@as(u32, 0xff8000), rgb(.{ .f_red = 1, .f_green = 0.5, .f_blue = 0, .f_alpha = 1 }));
    try std.testing.expectEqual(@as(u32, 0x0000ff), rgb(.{ .f_red = -1, .f_green = std.math.nan(f32), .f_blue = 7, .f_alpha = 1 }));
    try std.testing.expectApproxEqAbs(@as(f64, 1), luma(0xffffff), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), luma(0x000000), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), channels(0x008000)[1], 0.01);
}
