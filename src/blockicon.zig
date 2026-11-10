//! A block's program tile, with a dot for its status: working, needs you, finished or failed.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");
const programs = @import("programs.zig");
const draw_util = @import("draw.zig");
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
    const w = area.as(gtk.Widget);
    w.setValign(.center);
    w.setCanTarget(0);
    // Out of memory leaves an empty tile of the right size rather than taking the app down.
    const ctx = gpa.create(Ctx) catch return w;
    ctx.* = .{ .server = server, .block_id = gpa.dupe(u8, block_id) catch {
        gpa.destroy(ctx);
        return w;
    }, .size = size };
    if (blocks.len > 0) {
        var others: std.ArrayList([]u8) = .empty;
        for (blocks) |b| others.append(gpa, gpa.dupe(u8, b) catch continue) catch {};
        ctx.others = others.toOwnedSlice(gpa) catch &.{};
    }
    area.setDrawFunc(&draw, ctx, &free);
    return w;
}

fn free(data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    gpa.free(ctx.block_id);
    for (ctx.others) |o| gpa.free(o);
    gpa.free(ctx.others);
    gpa.destroy(ctx);
}

fn draw(area: *gtk.DrawingArea, cr: *cairo.Context, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    const ink_rgb = draw_util.rgb(ink);
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
        draw_util.roundRect(cr, 2 + (size - back) / 2, top - size * 0.16, back, back, back * 0.28);
        cr.fill();
    }
    programs.drawTile(cr, icon, 2, top, size, dark, neutral, ink_rgb);

    var dot = Dot.of(info);
    for (ctx.others) |o| {
        const d = Dot.of(ctx.server.blockInfo(o));
        if (@backingInt(d) > @backingInt(dot)) dot = d;
    }
    const c = dot.color() orelse return;
    const cx = size + 1;
    const cy = top + size - 1;
    // A ring cut out of the tile keeps the dot readable, and shows whatever is behind the
    // tile: the sidebar, a title row, or a frame in its program's color.
    cr.setOperator(.clear);
    cr.arc(cx, cy, 4.2, 0, 2 * std.math.pi);
    cr.fill();
    cr.setOperator(.over);
    draw_util.setColor(cr, c);
    cr.arc(cx, cy, 3, 0, 2 * std.math.pi);
    cr.fill();
}

/// What a block's dot says, from least to most urgent.
const Dot = enum(u8) {
    none,
    unread,
    working,
    done,
    failed,
    blocked,

    fn of(info: ?*@import("server.zig").BlockInfo) Dot {
        const b = info orelse return .none;
        if (b.has_status) return switch (b.status) {
            .working => .working,
            .blocked => .blocked,
            .done => if (b.attention) .done else .none,
            .failed => .failed,
            .other => .none,
        };
        return if (b.attention) .unread else .none;
    }

    fn color(d: Dot) ?u32 {
        return switch (d) {
            .none => null,
            .unread => 0x9a9aa0,
            .working => 0x5aa9ff,
            .done => 0x4cc76a,
            .failed => 0xff5a52,
            .blocked => 0xffa424,
        };
    }
};

test "the most urgent dot wins" {
    try std.testing.expect(@backingInt(Dot.blocked) > @backingInt(Dot.failed));
    try std.testing.expect(@backingInt(Dot.failed) > @backingInt(Dot.done));
    try std.testing.expect(@backingInt(Dot.done) > @backingInt(Dot.working));
    try std.testing.expect(@backingInt(Dot.working) > @backingInt(Dot.unread));
    try std.testing.expect(Dot.none.color() == null);
    try std.testing.expect(Dot.of(null) == .none);
}
