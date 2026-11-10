//! App colors worked out from the host's terminal theme, the way Rex's own apps color their
//! chrome: surfaces and strokes are small mixes of the background toward the foreground, controls
//! are the foreground at low opacity, and the accent is the cursor color.
const std = @import("std");
const gdk = @import("gdk");
const Colors = @import("stream.zig").Colors;

/// Colors for a terminal whose host reports no theme: a neutral dark one.
pub const default_bg: u32 = 0xFF1E1E1E;
pub const default_fg: u32 = 0xFFD4D4D4;

pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,

    pub fn of(v: u32) Rgb {
        return .{
            .r = @as(f64, @floatFromInt((v >> 16) & 0xff)) / 255,
            .g = @as(f64, @floatFromInt((v >> 8) & 0xff)) / 255,
            .b = @as(f64, @floatFromInt(v & 0xff)) / 255,
        };
    }

    pub fn mix(a: Rgb, b: Rgb, t: f64) Rgb {
        return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t };
    }

    pub fn luma(c: Rgb) f64 {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }

    fn byte(x: f64) u8 {
        return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
    }

    /// As 0xRRGGBB.
    pub fn pack(c: Rgb) u32 {
        return (@as(u32, byte(c.r)) << 16) | (@as(u32, byte(c.g)) << 8) | byte(c.b);
    }

    pub fn fromRgba(v: *const gdk.RGBA) Rgb {
        return .{ .r = v.f_red, .g = v.f_green, .b = v.f_blue };
    }

    /// For GTK, fully opaque.
    pub fn rgba(c: Rgb) gdk.RGBA {
        return .{ .f_red = @floatCast(c.r), .f_green = @floatCast(c.g), .f_blue = @floatCast(c.b), .f_alpha = 1 };
    }

    pub fn format(c: Rgb, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ byte(c.r), byte(c.g), byte(c.b) });
    }
};

pub const Palette = struct {
    dark: bool,
    canvas: Rgb,
    surface: Rgb,
    surface_subtle: Rgb,
    surface_raised: Rgb,
    stroke_subtle: Rgb,
    stroke: Rgb,
    content: Rgb,
    content_secondary: Rgb,
    accent: Rgb,
    on_accent: Rgb,
    danger: Rgb,
    success: Rgb,
    warning: Rgb,
    /// Behind the window card: a step darker than the terminal, like Rex's sidebar.
    shell: Rgb,

    pub fn from(c: Colors) Palette {
        const bg = Rgb.of(if (c.bg != 0) c.bg else default_bg);
        const fg = Rgb.of(if (c.fg != 0) c.fg else default_fg);
        const dark = bg.luma() < fg.luma();
        const p = if (c.palette) |*pal| pal else &@import("stream.zig").builtin_palette;
        const accent = Rgb.of(if (c.cursor != 0 and c.cursor != c.fg) c.cursor else p[4]);
        // Ratios measured from Rex's themes; light themes keep surfaces closer to the canvas.
        const r: [7]f64 = if (dark) .{ 0.019, 0.033, 0.083, 0.172, 0.277, 0.623, 0.101 } else .{ 0.0, 0.050, 0.0, 0.084, 0.205, 0.751, 0.0 };
        return .{
            .dark = dark,
            .canvas = bg,
            .surface = bg.mix(fg, r[0]),
            .surface_subtle = bg.mix(fg, r[1]),
            .surface_raised = bg.mix(fg, r[2]),
            .stroke_subtle = bg.mix(fg, r[3]),
            .stroke = bg.mix(fg, r[4]),
            .content = fg,
            .content_secondary = bg.mix(fg, r[5]),
            .accent = accent,
            .on_accent = if (accent.luma() > 0.5) bg.mix(Rgb.of(0), 0.6) else Rgb.of(0xffffff),
            .danger = Rgb.of(p[1]),
            .success = Rgb.of(p[2]),
            .warning = Rgb.of(p[3]),
            .shell = if (dark) bg.mix(Rgb.of(0), 0.22) else bg.mix(fg, 0.04),
        };
    }

    /// libadwaita's named colors, redefined so every widget follows the terminal theme.
    pub fn css(p: Palette, out: *std.Io.Writer) !void {
        const fg = p.content;
        try out.print(
            \\@define-color window_bg_color {f};
            \\@define-color window_fg_color {f};
            \\@define-color view_bg_color {f};
            \\@define-color view_fg_color {f};
            \\@define-color headerbar_bg_color {f};
            \\@define-color headerbar_fg_color {f};
            \\@define-color headerbar_backdrop_color {f};
            \\@define-color headerbar_shade_color {f};
            \\@define-color sidebar_bg_color {f};
            \\@define-color sidebar_fg_color {f};
            \\@define-color sidebar_backdrop_color {f};
            \\@define-color sidebar_shade_color {f};
            \\@define-color card_bg_color {f};
            \\@define-color card_fg_color {f};
            \\@define-color popover_bg_color {f};
            \\@define-color popover_fg_color {f};
            \\@define-color dialog_bg_color {f};
            \\@define-color dialog_fg_color {f};
            \\@define-color accent_bg_color {f};
            \\@define-color accent_fg_color {f};
            \\@define-color accent_color {f};
            \\@define-color destructive_bg_color {f};
            \\@define-color destructive_color {f};
            \\@define-color success_color {f};
            \\@define-color warning_color {f};
            \\@define-color error_color {f};
            \\@define-color compy_stroke {f};
            \\@define-color compy_stroke_subtle {f};
            \\@define-color compy_secondary {f};
            \\@define-color compy_shell {f};
            \\@define-color sidebar_border_color {f};
            \\
        , .{
            p.canvas,         fg,
            p.canvas,         fg,
            p.surface,        fg,
            p.surface,        p.stroke_subtle,
            p.surface_subtle, fg,
            p.surface_subtle, p.stroke_subtle,
            p.surface_raised, fg,
            p.surface_raised, fg,
            p.surface_raised, fg,
            p.accent,         p.on_accent,
            p.accent,         p.danger,
            p.danger,         p.success,
            p.warning,        p.danger,
            p.stroke,         p.stroke_subtle,
            p.content_secondary,
            p.shell,
            p.shell,
        });
    }
};

test "a dark theme gives a dark palette with surfaces just above the canvas" {
    const p = Palette.from(.{ .bg = 0xFF06101a, .fg = 0xFFb8cdd9, .cursor = 0xFF4fe3c1 });
    try std.testing.expect(p.dark);
    try std.testing.expect(p.surface_raised.luma() > p.surface.luma());
    try std.testing.expect(p.surface.luma() > p.canvas.luma());
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.css(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "@define-color accent_bg_color #4fe3c1;") != null);
}

test "a color packs back to the number it came from" {
    for ([_]u32{ 0x000000, 0xffffff, 0x4fe3c1, 0x010203, 0x7f8081 }) |c| {
        try std.testing.expectEqual(c, Rgb.of(c).pack());
        try std.testing.expectEqual(c, Rgb.fromRgba(&Rgb.of(c).rgba()).pack());
    }
    try std.testing.expectEqual(@as(u32, 0x808080), Rgb.of(0).mix(Rgb.of(0xffffff), 0.5).pack());
}
