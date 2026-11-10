//! The pictures in the settings window: small drawings on the cards that pick a color scheme,
//! where tabs go and how panes are spaced, live samples of the terminal's text, cursor and
//! selection, and the colored marks beside each kind of program status. They are drawn from
//! the settings and theme in effect, so a change shows in them at once.
const std = @import("std");
const glib = @import("glib");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const draw = @import("../util/draw.zig");
const settings = @import("settings.zig");
const themes = @import("../theme/themes.zig");
const termview = @import("../terminal/termview.zig");

/// What a card shows.
pub const Art = enum(usize) { scheme_auto, scheme_light, scheme_dark, tabs_left, tabs_right, tabs_above, panes_roomy, panes_compact };

/// A live sample of how the terminal draws something.
pub const Sample = enum(usize) { typography, cursor, selection };

pub const Status = enum(usize) { working, blocked, failed, done, idle };

/// The terminal's colors as they are now: the theme picked in Compy, or a plain dark or light
/// set with the window when each host's own theme is followed.
const Look = struct { bg: u32, fg: u32, accent: u32, green: u32, yellow: u32, blue: u32 };

fn look(widget: *gtk.Widget) Look {
    _ = widget;
    const dark = isDark();
    var l: Look = if (dark)
        .{ .bg = 0x1c1c1f, .fg = 0xdcdcdc, .accent = 0x7aa2f7, .green = 0x9ece6a, .yellow = 0xe0af68, .blue = 0x7aa2f7 }
    else
        .{ .bg = 0xfbfbfa, .fg = 0x2a2a2e, .accent = 0x2f6fde, .green = 0x3f8a2b, .yellow = 0x9a6a00, .blue = 0x2f6fde };
    if (termview.theme_bg != 0) l.bg = termview.theme_bg;
    if (themes.active) |c| {
        l.bg = c.bg;
        l.fg = c.fg;
        if (c.cursor != 0) l.accent = c.cursor;
        if (c.palette) |p| {
            l.green = p[2];
            l.yellow = p[3];
            l.blue = p[4];
        }
    }
    return l;
}

/// Whether the window is in its dark look. Asked of the app, not read off a widget's text
/// color, which differs between a picked card and the ones beside it.
fn isDark() bool {
    return @import("adw").StyleManager.getDefault().getDark() != 0;
}

fn rgb(cr: *cairo.Context, c: u32, alpha: f64) void {
    const ch = draw.channels(c);
    cr.setSourceRgba(ch[0], ch[1], ch[2], alpha);
}

// Cards.

/// A drawing for a card, `w` by `h` pixels.
pub fn card(kind: Art, w: c_int, h: c_int) *gtk.Widget {
    const area = gtk.DrawingArea.new();
    area.setContentWidth(w);
    area.setContentHeight(h);
    area.setDrawFunc(&drawCard, @ptrFromInt(@intFromEnum(kind) + 1), null);
    return area.as(gtk.Widget);
}

fn drawCard(area: *gtk.DrawingArea, cr: *cairo.Context, wi: c_int, hi: c_int, data: ?*anyopaque) callconv(.c) void {
    const kind: Art = @enumFromInt(@intFromPtr(data) - 1);
    const w: f64 = @floatFromInt(wi);
    const h: f64 = @floatFromInt(hi);
    const l = look(area.as(gtk.Widget));
    // A backdrop like a desktop behind a window, in the theme's own accent.
    draw.roundRect(cr, 0, 0, w, h, 9);
    cr.clip();
    rgb(cr, l.blue, 0.6);
    cr.paint();
    rgb(cr, 0xffffff, 0.10);
    cr.moveTo(0, h);
    cr.lineTo(w * 0.55, 0);
    cr.lineTo(w, 0);
    cr.lineTo(w, h * 0.5);
    cr.lineTo(w * 0.4, h);
    cr.closePath();
    cr.fill();
    rgb(cr, 0x000000, 0.12);
    cr.moveTo(0, h * 0.35);
    cr.lineTo(w * 0.3, h);
    cr.lineTo(0, h);
    cr.closePath();
    cr.fill();

    // The little window on it.
    const ww = w * 0.56;
    const wh = h * 0.60;
    const x = (w - ww) / 2;
    const y = (h - wh) / 2;
    const light: u32 = 0xf4f4f6;
    const dark: u32 = 0x1d1d21;
    switch (kind) {
        .scheme_light => window(cr, x, y, ww, wh, light, 0x2a2a2e, true),
        .scheme_dark => window(cr, x, y, ww, wh, dark, 0xe6e6e6, true),
        .scheme_auto => {
            // Light on one side of a slanted line and dark on the other.
            window(cr, x, y, ww, wh, light, 0x2a2a2e, true);
            cr.save();
            cr.moveTo(x + ww * 0.62, y - 1);
            cr.lineTo(x + ww + 1, y - 1);
            cr.lineTo(x + ww + 1, y + wh + 1);
            cr.lineTo(x + ww * 0.38, y + wh + 1);
            cr.closePath();
            cr.clip();
            window(cr, x, y, ww, wh, dark, 0xe6e6e6, true);
            cr.restore();
        },
        .tabs_left, .tabs_right, .tabs_above => {
            const paper: u32 = if (isDark()) dark else light;
            const line: u32 = if (paper == dark) 0xe6e6e6 else 0x2a2a2e;
            window(cr, x, y, ww, wh, paper, line, false);
            rgb(cr, l.blue, 0.95);
            switch (kind) {
                .tabs_left => draw.roundRect(cr, x + 4, y + 9, ww * 0.26, wh - 13, 2.5),
                .tabs_right => draw.roundRect(cr, x + ww - 4 - ww * 0.26, y + 9, ww * 0.26, wh - 13, 2.5),
                else => draw.roundRect(cr, x + 4, y + 9, ww - 8, wh * 0.2, 2.5),
            }
            cr.fill();
            rgb(cr, line, 0.16);
            switch (kind) {
                .tabs_left => draw.roundRect(cr, x + 7 + ww * 0.26, y + 9, ww - 11 - ww * 0.26, wh - 13, 2.5),
                .tabs_right => draw.roundRect(cr, x + 4, y + 9, ww - 11 - ww * 0.26, wh - 13, 2.5),
                else => draw.roundRect(cr, x + 4, y + 12 + wh * 0.2, ww - 8, wh - 16 - wh * 0.2, 2.5),
            }
            cr.fill();
        },
        .panes_roomy, .panes_compact => {
            const paper: u32 = if (isDark()) dark else light;
            const line: u32 = if (paper == dark) 0xe6e6e6 else 0x2a2a2e;
            window(cr, x, y, ww, wh, paper, line, false);
            const gap: f64 = if (kind == .panes_roomy) 3.5 else 1;
            const r: f64 = if (kind == .panes_roomy) 3 else 0.5;
            const left = x + 4;
            const top = y + 9;
            const iw = ww - 8;
            const ih = wh - 13;
            rgb(cr, line, 0.22);
            draw.roundRect(cr, left, top, iw * 0.5 - gap / 2, ih, r);
            draw.roundRect(cr, left + iw * 0.5 + gap / 2, top, iw * 0.5 - gap / 2, ih * 0.5 - gap / 2, r);
            draw.roundRect(cr, left + iw * 0.5 + gap / 2, top + ih * 0.5 + gap / 2, iw * 0.5 - gap / 2, ih * 0.5 - gap / 2, r);
            cr.fill();
        },
    }
}

/// A window in miniature: its three buttons, and with `content` a few blocks inside.
fn window(cr: *cairo.Context, x: f64, y: f64, w: f64, h: f64, paper: u32, line: u32, content: bool) void {
    rgb(cr, 0x000000, 0.25);
    draw.roundRect(cr, x - 0.5, y + 1, w + 1, h + 1, 5.5);
    cr.fill();
    rgb(cr, paper, 1);
    draw.roundRect(cr, x, y, w, h, 5);
    cr.fill();
    inline for (.{ 0xfe5f57, 0xfebc2e, 0x28c840 }, 0..) |c, i| {
        rgb(cr, c, 1);
        cr.arc(x + 5 + @as(f64, @floatFromInt(i)) * 4.5, y + 4.5, 1.6, 0, 2 * std.math.pi);
        cr.fill();
    }
    if (!content) return;
    rgb(cr, line, 0.14);
    draw.roundRect(cr, x + 4, y + 9, w - 8, h * 0.32, 2.5);
    draw.roundRect(cr, x + 4, y + 12 + h * 0.32, (w - 11) / 2, h - 16 - h * 0.32, 2.5);
    draw.roundRect(cr, x + 7 + (w - 11) / 2, y + 12 + h * 0.32, (w - 11) / 2, h - 16 - h * 0.32, 2.5);
    cr.fill();
}

// Samples.

/// A sample of the terminal, drawn with its font and colors.
pub fn sample(kind: Sample) *gtk.Widget {
    const area = gtk.DrawingArea.new();
    area.setContentHeight(48);
    area.as(gtk.Widget).setHexpand(1);
    area.as(gtk.Widget).addCssClass("settings-sample");
    area.setDrawFunc(&drawSample, @ptrFromInt(@intFromEnum(kind) + 1), null);
    // The cursor's sample blinks as the terminal's does.
    if (kind == .cursor) _ = area.as(gtk.Widget).addTickCallback(&blinkTick, null, null);
    return area.as(gtk.Widget);
}

var blink_shown: bool = true;

fn blinkTick(widget: *gtk.Widget, _: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
    const period: i64 = @intFromFloat(@max(100, settings.current.cursor_blink_ms) * 1000);
    const on = !settings.current.cursor_blink or @mod(@divTrunc(glib.getMonotonicTime(), period), 2) == 0;
    if (on != blink_shown) {
        blink_shown = on;
        widget.queueDraw();
    }
    return 1;
}

const Run = struct { text: [:0]const u8, color: u32, face: enum { regular, bold, italic } = .regular, alpha: f64 = 1 };

fn drawSample(area: *gtk.DrawingArea, cr: *cairo.Context, wi: c_int, hi: c_int, data: ?*anyopaque) callconv(.c) void {
    const kind: Sample = @enumFromInt(@intFromPtr(data) - 1);
    const w: f64 = @floatFromInt(wi);
    const h: f64 = @floatFromInt(hi);
    const l = look(area.as(gtk.Widget));
    const font = termview.font orelse return;
    const layout = pangocairo.createLayout(cr);
    defer layout.as(@import("gobject").Object).unref();

    // The row height the terminal uses, from the font and the line height setting.
    layout.setFontDescription(font.regular);
    layout.setText("M", 1);
    var cell_w: c_int = 0;
    var cell_h: c_int = 0;
    layout.getPixelSize(&cell_w, &cell_h);
    const row: f64 = @round(@as(f64, @floatFromInt(cell_h)) * settings.current.line_height);
    const lines: f64 = if (kind == .typography) 3 else 1;
    const pad: f64 = 14;
    const want: c_int = @intFromFloat(lines * row + 2 * pad);
    if (area.getContentHeight() != want) area.setContentHeight(want);

    // The terminal's own background, as a rounded panel.
    rgb(cr, l.bg, 1);
    draw.roundRect(cr, 0.5, 0.5, w - 1, h - 1, 10);
    cr.fillPreserve();
    rgb(cr, l.fg, 0.14);
    cr.setLineWidth(1);
    cr.stroke();
    draw.roundRect(cr, 1, 1, w - 2, h - 2, 9);
    cr.clip();

    const x0: f64 = 16;
    switch (kind) {
        .typography => {
            _ = runs(cr, layout, &font, x0, pad, &.{
                .{ .text = "~/compy ", .color = l.blue },
                .{ .text = "main ", .color = l.green },
                .{ .text = "$ zig build test", .color = l.fg },
            });
            _ = runs(cr, layout, &font, x0, pad + row, &.{
                .{ .text = "main.zig:4: ", .color = l.fg },
                .{ .text = "warning:", .color = l.yellow },
                .{ .text = " 'run' is deprecated", .color = l.fg },
            });
            _ = runs(cr, layout, &font, x0, pad + 2 * row, &.{
                .{ .text = "Build complete!", .color = l.fg, .face = .bold },
                .{ .text = " (1.24 sec)", .color = l.fg, .face = .italic, .alpha = 0.8 },
            });
        },
        .cursor => {
            const end = runs(cr, layout, &font, x0, pad, &.{
                .{ .text = "~/compy ", .color = l.blue },
                .{ .text = "$ ", .color = l.fg },
            });
            if (!blink_shown) return;
            const cw: f64 = @floatFromInt(cell_w);
            const ch: f64 = @floatFromInt(cell_h);
            const width = settings.current.cursor_width;
            rgb(cr, l.accent, 1);
            switch (settings.current.cursor_style) {
                .bar => cr.rectangle(end, pad, width, ch),
                .underline => cr.rectangle(end, pad + ch - width, cw, width),
                .program, .block => cr.rectangle(end, pad, cw, ch),
            }
            cr.fill();
        },
        .selection => {
            const start = runs(cr, layout, &font, x0, pad, &.{.{ .text = "On branch ", .color = l.fg }});
            // Selected text swaps its colors unless colors were picked for it.
            const st = &settings.current;
            const back: u32 = if (st.selection_bg != 0) st.selection_bg else l.fg;
            const front: u32 = if (st.selection_fg != 0) st.selection_fg else l.bg;
            layout.setFontDescription(font.regular);
            layout.setText("feature/tabs", -1);
            var sw: c_int = 0;
            var sh: c_int = 0;
            layout.getPixelSize(&sw, &sh);
            rgb(cr, back, if (st.selection_bg != 0) 1 else 0.9);
            if (st.rounded_selection)
                draw.roundRect(cr, start - 2, pad - 1, @as(f64, @floatFromInt(sw)) + 4, @as(f64, @floatFromInt(sh)) + 2, 4)
            else
                cr.rectangle(start, pad, @floatFromInt(sw), @floatFromInt(sh));
            cr.fill();
            _ = runs(cr, layout, &font, start, pad, &.{.{ .text = "feature/tabs", .color = front }});
        },
    }
}

/// Draws runs of text one after another from `x`, and returns where the last one ends.
fn runs(cr: *cairo.Context, layout: *pango.Layout, font: *const termview.Font, x: f64, y: f64, list: []const Run) f64 {
    var at = x;
    for (list) |r| {
        layout.setFontDescription(switch (r.face) {
            .regular => font.regular,
            .bold => font.bold,
            .italic => font.italic,
        });
        layout.setText(r.text.ptr, -1);
        rgb(cr, r.color, r.alpha);
        cr.moveTo(at, y);
        pangocairo.showLayout(cr, layout);
        var w: c_int = 0;
        var h: c_int = 0;
        layout.getPixelSize(&w, &h);
        at += @floatFromInt(w);
    }
    return at;
}

// Status marks.

/// A round colored mark for one kind of program status, as the sidebar's dots color them.
pub fn status(kind: Status) *gtk.Widget {
    const area = gtk.DrawingArea.new();
    area.setContentWidth(30);
    area.setContentHeight(30);
    area.as(gtk.Widget).setValign(.center);
    area.setDrawFunc(&drawStatus, @ptrFromInt(@intFromEnum(kind) + 1), null);
    return area.as(gtk.Widget);
}

fn drawStatus(_: *gtk.DrawingArea, cr: *cairo.Context, wi: c_int, hi: c_int, data: ?*anyopaque) callconv(.c) void {
    const kind: Status = @enumFromInt(@intFromPtr(data) - 1);
    const cx = @as(f64, @floatFromInt(wi)) / 2;
    const cy = @as(f64, @floatFromInt(hi)) / 2;
    const r = @min(cx, cy) - 1;
    rgb(cr, switch (kind) {
        .working => 0x3b82f6,
        .blocked => 0xf59e0b,
        .failed => 0xef4444,
        .done => 0x22c55e,
        .idle => 0x8a8f98,
    }, 1);
    cr.arc(cx, cy, r, 0, 2 * std.math.pi);
    cr.fill();
    rgb(cr, 0xffffff, 1);
    cr.setLineWidth(2.2);
    cr.setLineCap(.round);
    cr.setLineJoin(.round);
    switch (kind) {
        .working => inline for (.{ -5.0, 0.0, 5.0 }) |dx| {
            cr.arc(cx + dx, cy, 1.7, 0, 2 * std.math.pi);
            cr.fill();
        },
        .blocked => {
            cr.arc(cx, cy, r * 0.5, 0, 2 * std.math.pi);
            cr.stroke();
            cr.moveTo(cx - r * 0.35, cy + r * 0.35);
            cr.lineTo(cx + r * 0.35, cy - r * 0.35);
            cr.stroke();
        },
        .failed => {
            cr.moveTo(cx, cy - r * 0.5);
            cr.lineTo(cx, cy + r * 0.1);
            cr.stroke();
            cr.arc(cx, cy + r * 0.5, 1.4, 0, 2 * std.math.pi);
            cr.fill();
        },
        .idle => {
            // A crescent moon: a disc with a bite out of it, in the mark's own color.
            cr.arc(cx - r * 0.06, cy + r * 0.04, r * 0.5, 0, 2 * std.math.pi);
            cr.fill();
            rgb(cr, 0x8a8f98, 1);
            cr.arc(cx + r * 0.2, cy - r * 0.16, r * 0.42, 0, 2 * std.math.pi);
            cr.fill();
        },
        .done => {
            cr.moveTo(cx - r * 0.42, cy + r * 0.02);
            cr.lineTo(cx - r * 0.1, cy + r * 0.36);
            cr.lineTo(cx + r * 0.46, cy - r * 0.32);
            cr.stroke();
        },
    }
}
