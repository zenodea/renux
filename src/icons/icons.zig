//! The Android app's icons (Material Icons Round), drawn in the widget's own text color, so they
//! follow the theme and look the same on every distribution, whatever icon theme it ships.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");
const rsvg = @import("rsvg");
const table = @import("ui_icons.zig");
const draw_util = @import("../util/draw.zig");

pub const Kind = enum { sidebar, more, plus, split_right, split_down, float, zoom, close, terminal, server, gear, palette, interface, keyboard, search, bell, up, down, right, new_session, add_host, filter, minimize, board, eye };

pub fn image(kind: Kind, size: c_int) *gtk.Widget {
    const area = gtk.DrawingArea.new();
    area.setContentWidth(size);
    area.setContentHeight(size);
    area.setDrawFunc(&draw, @ptrFromInt(@as(usize, @backingInt(kind)) + 1), null);
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
    const kind: Kind = @fromBackingInt(@intCast(@intFromPtr(data) - 1));
    var color: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&color);
    const h = handleFor(kind) orelse return;
    const side: f64 = @floatFromInt(@min(width, height));
    const viewport: rsvg.Rectangle = .{
        .f_x = (@as(f64, @floatFromInt(width)) - side) / 2,
        .f_y = (@as(f64, @floatFromInt(height)) - side) / 2,
        .f_width = side,
        .f_height = side,
    };
    // The shape is drawn once as a mask and filled with the widget's color, so a color that
    // fades (hover, a disabled button) needs no new SVG for each shade on the way.
    cr.pushGroup();
    _ = h.renderDocument(cr, &viewport, null);
    const shape = cr.popGroup();
    defer shape.destroy();
    draw_util.setRgba(cr, color, 1);
    cr.mask(shape);
}

var handles: [std.enums.values(Kind).len]?*rsvg.Handle = @splat(null);

/// The icon's shape as an SVG, parsed once.
fn handleFor(kind: Kind) ?*rsvg.Handle {
    const slot = &handles[@backingInt(kind)];
    if (slot.*) |h| return h;
    const icon = for (table.icons) |i| {
        if (std.mem.eql(u8, i.name, @tagName(kind))) break i;
    } else return null;
    slot.* = draw_util.svgHandle(icon.path, icon.transform, "#ffffff");
    return slot.*;
}
