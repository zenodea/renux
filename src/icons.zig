//! The Android app's icons (Material Icons Round), drawn in the widget's own text color, so they
//! follow the theme and look the same on every distribution, whatever icon theme it ships.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");
const rsvg = @import("rsvg");
const table = @import("ui_icons.zig");

const gpa = std.heap.c_allocator;

pub const Kind = enum { sidebar, more, plus, split_right, split_down, float, zoom, close, terminal, server, gear, palette, interface, keyboard, search, bell, up, down, right, new_session, add_host, filter, minimize };

pub fn image(kind: Kind, size: c_int) *gtk.Widget {
    const area = gtk.DrawingArea.new();
    area.setContentWidth(size);
    area.setContentHeight(size);
    area.setDrawFunc(&draw, @ptrFromInt(@as(usize, @intFromEnum(kind)) + 1), null);
    const w = area.as(gtk.Widget);
    w.setCanTarget(0);
    w.setValign(.center);
    w.setHalign(.center);
    return w;
}

/// A flat icon button that runs `action` (such as "app.split-right").
pub fn button(kind: Kind, tooltip: [:0]const u8, action: ?[:0]const u8) *gtk.Button {
    const b = gtk.Button.new();
    b.setChild(image(kind, 16));
    b.as(gtk.Widget).setTooltipText(tooltip.ptr);
    b.as(gtk.Widget).addCssClass("icon-button");
    b.as(gtk.Widget).addCssClass("flat");
    b.as(gtk.Widget).setValign(.center);
    if (action) |a| b.as(gtk.Actionable).setActionName(a.ptr);
    return b;
}

fn draw(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const kind: Kind = @enumFromInt(@intFromPtr(data) - 1);
    var color: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&color);
    const h = handleFor(kind, color) orelse return;
    const side: f64 = @floatFromInt(@min(width, height));
    const viewport: rsvg.Rectangle = .{
        .f_x = (@as(f64, @floatFromInt(width)) - side) / 2,
        .f_y = (@as(f64, @floatFromInt(height)) - side) / 2,
        .f_width = side,
        .f_height = side,
    };
    _ = h.renderDocument(cr, &viewport, null);
}

var handles: std.AutoHashMapUnmanaged(u64, *rsvg.Handle) = .empty;

/// The icon as an SVG in this color, parsed once per color.
fn handleFor(kind: Kind, color: gdk.RGBA) ?*rsvg.Handle {
    const icon = for (table.icons) |i| {
        if (std.mem.eql(u8, i.name, @tagName(kind))) break i;
    } else return null;
    const r: u8 = @intFromFloat(@round(std.math.clamp(color.f_red, 0, 1) * 255));
    const g: u8 = @intFromFloat(@round(std.math.clamp(color.f_green, 0, 1) * 255));
    const b: u8 = @intFromFloat(@round(std.math.clamp(color.f_blue, 0, 1) * 255));
    const a: u8 = @intFromFloat(@round(std.math.clamp(color.f_alpha, 0, 1) * 255));
    const key = (@as(u64, @intFromEnum(kind)) << 32) | (@as(u64, r) << 24) | (@as(u64, g) << 16) | (@as(u64, b) << 8) | a;
    if (handles.get(key)) |h| return h;
    const svg = std.fmt.allocPrint(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path fill=\"#{x:0>2}{x:0>2}{x:0>2}\" fill-opacity=\"{d:.3}\" transform=\"{s}\" d=\"{s}\"/></svg>", .{
        r, g, b, @as(f64, @floatFromInt(a)) / 255, icon.transform, icon.path,
    }) catch return null;
    defer gpa.free(svg);
    const h = rsvg.Handle.newFromData(svg.ptr, svg.len, null) orelse return null;
    handles.put(gpa, key, h) catch {};
    return h;
}
