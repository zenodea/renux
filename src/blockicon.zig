//! A block's program tile, with a dot for its status: working, needs you, finished or failed.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");
const programs = @import("programs.zig");
const Server = @import("server.zig").Server;

const gpa = std.heap.c_allocator;

const Ctx = struct {
    server: *Server,
    block_id: []u8,
    size: c_int,
    /// For a window's row: the dot shows the most urgent of these blocks.
    others: [][]u8 = &.{},
};

/// A tile for `block_id`. Call `gtk.Widget.queueDraw` on it when the block's details change.
pub fn create(server: *Server, block_id: []const u8, size: c_int) *gtk.Widget {
    return createFor(server, block_id, &.{}, size);
}

/// A tile showing `block_id`'s program, with a dot for the most urgent of `blocks`.
pub fn createFor(server: *Server, block_id: []const u8, blocks: []const []const u8, size: c_int) *gtk.Widget {
    const area = gtk.DrawingArea.new();
    // Room for the status dot to sit just past the corner.
    area.setContentWidth(size + 4);
    area.setContentHeight(size + 7);
    const ctx = gpa.create(Ctx) catch unreachable;
    ctx.* = .{ .server = server, .block_id = gpa.dupe(u8, block_id) catch unreachable, .size = size };
    if (blocks.len > 0) {
        ctx.others = gpa.alloc([]u8, blocks.len) catch &.{};
        for (ctx.others, blocks) |*o, b| o.* = gpa.dupe(u8, b) catch @constCast("");
    }
    area.setDrawFunc(&draw, ctx, &free);
    const w = area.as(gtk.Widget);
    w.setValign(.center);
    w.setCanTarget(0);
    return w;
}

fn free(data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    gpa.free(ctx.block_id);
    for (ctx.others) |o| if (o.len > 0) gpa.free(o);
    if (ctx.others.len > 0) gpa.free(ctx.others);
    gpa.destroy(ctx);
}

fn rgb(c: gdk.RGBA) u32 {
    const r: u32 = @intFromFloat(std.math.clamp(c.f_red, 0, 1) * 255);
    const g: u32 = @intFromFloat(std.math.clamp(c.f_green, 0, 1) * 255);
    const b: u32 = @intFromFloat(std.math.clamp(c.f_blue, 0, 1) * 255);
    return (r << 16) | (g << 8) | b;
}

fn draw(area: *gtk.DrawingArea, cr: *cairo.Context, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    const ink_rgb = rgb(ink);
    const dark = ink.f_red + ink.f_green + ink.f_blue > 1.5; // light text means a dark canvas
    const neutral: u32 = if (dark) 0x3a3a3c else 0xdedee2;
    const info = ctx.server.blockInfo(ctx.block_id);
    const brand = @import("settings.zig").current.brand_icons;
    const icon = if (!brand) null else if (info) |b| programs.iconFor(if (b.has_status) b.status_app else null, b.program) else null;
    const size: f64 = @floatFromInt(ctx.size);
    // A window with several panes shows a second card peeking out behind its tile, like Rex.
    const top: f64 = 5;
    if (ctx.others.len > 1) {
        const back = size * 0.8;
        cr.setSourceRgba(ink.f_red, ink.f_green, ink.f_blue, 0.28);
        roundRect(cr, 2 + (size - back) / 2, top - size * 0.16, back, back, back * 0.28);
        cr.fill();
    }
    programs.drawTile(cr, icon, 2, top, size, dark, neutral, ink_rgb);

    var color: ?u32 = dotColor(info);
    var best = rank(color);
    for (ctx.others) |o| {
        const c = dotColor(ctx.server.blockInfo(o));
        if (rank(c) > best) {
            best = rank(c);
            color = c;
        }
    }
    const c = color orelse return;
    const cx = size + 1;
    const cy = top + size - 1;
    // A ring in the canvas color keeps the dot readable over the tile.
    cr.setSourceRgb(if (dark) 0.1 else 0.97, if (dark) 0.1 else 0.97, if (dark) 0.11 else 0.98);
    cr.arc(cx, cy, 4.2, 0, 2 * std.math.pi);
    cr.fill();
    cr.setSourceRgb(@as(f64, @floatFromInt((c >> 16) & 0xff)) / 255, @as(f64, @floatFromInt((c >> 8) & 0xff)) / 255, @as(f64, @floatFromInt(c & 0xff)) / 255);
    cr.arc(cx, cy, 3, 0, 2 * std.math.pi);
    cr.fill();
}

fn dotColor(info: ?*@import("server.zig").BlockInfo) ?u32 {
    const b = info orelse return null;
    if (b.has_status) return switch (b.status) {
        .working => 0x5aa9ff,
        .blocked => 0xffa424,
        .done => if (b.attention) 0x4cc76a else null,
        .failed => 0xff5a52,
        .other => null,
    };
    return if (b.attention) 0x9a9aa0 else null;
}

fn rank(c: ?u32) u8 {
    return switch (c orelse return 0) {
        0xffa424 => 5,
        0xff5a52 => 4,
        0x4cc76a => 3,
        0x5aa9ff => 2,
        else => 1,
    };
}

fn roundRect(cr: *cairo.Context, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const pi: f64 = std.math.pi;
    cr.newSubPath();
    cr.arc(x + w - r, y + r, r, -pi / 2, 0);
    cr.arc(x + w - r, y + h - r, r, 0, pi / 2);
    cr.arc(x + r, y + h - r, r, pi / 2, pi);
    cr.arc(x + r, y + r, r, pi, 3 * pi / 2);
    cr.closePath();
}
