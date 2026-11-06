//! Small line icons drawn with Cairo in the widget's own text color, so they follow the theme
//! and look the same on every distribution, whatever icon theme it ships.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");

pub const Kind = enum { sidebar, more, plus, split_right, split_down, float, zoom, close, terminal, server, gear, search, bell, up, down };

pub fn image(kind: Kind, size: c_int) *gtk.Widget {
    const area = gtk.DrawingArea.new();
    area.setContentWidth(size);
    area.setContentHeight(size);
    area.setDrawFunc(&draw, @ptrFromInt(@intFromEnum(kind) + 1), null);
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
    cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, color.f_alpha);
    // Icons are drawn on a 16-unit grid, centred.
    const s = @as(f64, @floatFromInt(@min(width, height))) / 16.0;
    cr.translate((@as(f64, @floatFromInt(width)) - 16 * s) / 2, (@as(f64, @floatFromInt(height)) - 16 * s) / 2);
    cr.scale(s, s);
    cr.setLineWidth(1.4);
    cr.setLineCap(.round);
    cr.setLineJoin(.round);
    switch (kind) {
        .sidebar => {
            roundRect(cr, 2, 3, 12, 10, 2);
            cr.stroke();
            line(cr, 6.5, 3, 6.5, 13);
        },
        .more => {
            for ([_]f64{ 4, 8, 12 }) |x| {
                cr.arc(x, 8, 1.2, 0, 2 * std.math.pi);
                cr.fill();
            }
        },
        .plus => {
            line(cr, 8, 3, 8, 13);
            line(cr, 3, 8, 13, 8);
        },
        .split_right => {
            roundRect(cr, 2, 3, 12, 10, 2);
            cr.stroke();
            line(cr, 8, 3, 8, 13);
        },
        .split_down => {
            roundRect(cr, 2, 3, 12, 10, 2);
            cr.stroke();
            line(cr, 2, 8, 14, 8);
        },
        .float => {
            roundRect(cr, 2, 5, 8, 7, 1.5);
            cr.stroke();
            roundRect(cr, 6, 3, 8, 7, 1.5);
            cr.stroke();
        },
        .zoom => {
            line(cr, 9.5, 2.5, 13.5, 2.5);
            line(cr, 13.5, 2.5, 13.5, 6.5);
            line(cr, 13.5, 2.5, 9.5, 6.5);
            line(cr, 2.5, 9.5, 2.5, 13.5);
            line(cr, 2.5, 13.5, 6.5, 13.5);
            line(cr, 2.5, 13.5, 6.5, 9.5);
        },
        .close => {
            line(cr, 4, 4, 12, 12);
            line(cr, 12, 4, 4, 12);
        },
        .terminal => {
            roundRect(cr, 1.5, 2.5, 13, 11, 2.5);
            cr.stroke();
            line(cr, 4.5, 6, 6.8, 8);
            line(cr, 6.8, 8, 4.5, 10);
            line(cr, 8.5, 10.5, 11.5, 10.5);
        },
        .server => {
            roundRect(cr, 2, 2.5, 12, 4.5, 1.5);
            cr.stroke();
            roundRect(cr, 2, 9, 12, 4.5, 1.5);
            cr.stroke();
            cr.arc(5, 4.75, 0.8, 0, 2 * std.math.pi);
            cr.fill();
            cr.arc(5, 11.25, 0.8, 0, 2 * std.math.pi);
            cr.fill();
        },
        .gear => {
            cr.arc(8, 8, 2.2, 0, 2 * std.math.pi);
            cr.stroke();
            for (0..8) |i| {
                const a = @as(f64, @floatFromInt(i)) * std.math.pi / 4;
                line(cr, 8 + @cos(a) * 4.3, 8 + @sin(a) * 4.3, 8 + @cos(a) * 6, 8 + @sin(a) * 6);
            }
            cr.arc(8, 8, 4.3, 0, 2 * std.math.pi);
            cr.stroke();
        },
        .search => {
            cr.arc(7, 7, 4, 0, 2 * std.math.pi);
            cr.stroke();
            line(cr, 10, 10, 13.5, 13.5);
        },
        .up => {
            line(cr, 4, 10, 8, 6);
            line(cr, 8, 6, 12, 10);
        },
        .down => {
            line(cr, 4, 6, 8, 10);
            line(cr, 8, 10, 12, 6);
        },
        .bell => {
            cr.moveTo(4, 11);
            cr.curveTo(4, 5, 5, 3, 8, 3);
            cr.curveTo(11, 3, 12, 5, 12, 11);
            cr.closePath();
            cr.stroke();
            line(cr, 3, 11, 13, 11);
            line(cr, 7, 13.5, 9, 13.5);
        },
    }
}

fn line(cr: *cairo.Context, x0: f64, y0: f64, x1: f64, y1: f64) void {
    cr.moveTo(x0, y0);
    cr.lineTo(x1, y1);
    cr.stroke();
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
