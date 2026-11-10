//! Terminal themes Compy can use instead of the host's. They only recolor this app; Compy never
//! changes a server's theme. Built-ins are well-known MIT-licensed palettes; any Ghostty theme
//! file can be imported too.
const std = @import("std");
const glib = @import("glib");
const stream = @import("../rex/stream.zig");
const Colors = stream.Colors;
const Rgb = @import("theme.zig").Rgb;

const gpa = std.heap.c_allocator;

/// The theme chosen in Compy's settings, or null to follow each host.
pub var active: ?Colors = null;

pub const Theme = struct {
    name: []const u8,
    bg: u32,
    fg: u32,
    cursor: u32,
    ansi: [16]u32,
};

pub const builtins = [_]Theme{
    .{ .name = "Dracula", .bg = 0x282a36, .fg = 0xf8f8f2, .cursor = 0xf8f8f2, .ansi = .{ 0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2, 0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff } },
    .{ .name = "Nord", .bg = 0x2e3440, .fg = 0xd8dee9, .cursor = 0xd8dee9, .ansi = .{ 0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0, 0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4 } },
    .{ .name = "Tokyo Night", .bg = 0x1a1b26, .fg = 0xc0caf5, .cursor = 0xc0caf5, .ansi = .{ 0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6, 0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5 } },
    .{ .name = "Catppuccin Mocha", .bg = 0x1e1e2e, .fg = 0xcdd6f4, .cursor = 0xf5e0dc, .ansi = .{ 0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de, 0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8 } },
    .{ .name = "Gruvbox Dark", .bg = 0x282828, .fg = 0xebdbb2, .cursor = 0xebdbb2, .ansi = .{ 0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984, 0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2 } },
    .{ .name = "Solarized Dark", .bg = 0x002b36, .fg = 0x839496, .cursor = 0x93a1a1, .ansi = .{ 0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5, 0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3 } },
    .{ .name = "Solarized Light", .bg = 0xfdf6e3, .fg = 0x657b83, .cursor = 0x586e75, .ansi = .{ 0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5, 0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3 } },
    .{ .name = "Catppuccin Latte", .bg = 0xeff1f5, .fg = 0x4c4f69, .cursor = 0xdc8a78, .ansi = .{ 0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be, 0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc } },
};

/// Remakes colors 16 to 255 from the first 16, like Ghostty's generated palette: the 6x6x6
/// cube blends between the background, the six base colors and the foreground, and the 24
/// grays run from the background to the foreground.
pub fn extendPalette(p: *[256]u32, bg: u32, fg: u32) void {
    // Corners of the cube: black is the background and white the foreground.
    const k000 = Rgb.of(bg);
    const k100 = Rgb.of(p[1]);
    const k010 = Rgb.of(p[2]);
    const k110 = Rgb.of(p[3]);
    const k001 = Rgb.of(p[4]);
    const k101 = Rgb.of(p[5]);
    const k011 = Rgb.of(p[6]);
    const k111 = Rgb.of(fg);
    for (0..6) |r| for (0..6) |g| for (0..6) |b| {
        const tr = @as(f64, @floatFromInt(r)) / 5;
        const tg = @as(f64, @floatFromInt(g)) / 5;
        const tb = @as(f64, @floatFromInt(b)) / 5;
        const c0 = k000.mix(k100, tr).mix(k010.mix(k110, tr), tg);
        const c1 = k001.mix(k101, tr).mix(k011.mix(k111, tr), tg);
        p[16 + r * 36 + g * 6 + b] = c0.mix(c1, tb).pack() | 0xFF000000;
    };
    for (0..24) |i| p[232 + i] = k000.mix(k111, @as(f64, @floatFromInt(i + 1)) / 25).pack() | 0xFF000000;
}

pub fn colorsOf(t: Theme) Colors {
    var p = stream.builtin_palette;
    for (t.ansi, 0..) |c, i| p[i] = c | 0xFF000000;
    return .{ .fg = t.fg | 0xFF000000, .bg = t.bg | 0xFF000000, .cursor = t.cursor | 0xFF000000, .palette = p };
}

/// The colors for a setting value: a built-in name, or `file:PATH` for a Ghostty theme file.
/// Null follows the host.
pub fn resolve(setting: []const u8) ?Colors {
    if (setting.len == 0) return null;
    if (std.mem.startsWith(u8, setting, "file:")) return loadGhostty(setting["file:".len..]);
    for (builtins) |t| if (std.mem.eql(u8, t.name, setting)) return colorsOf(t);
    return null;
}

/// Reads a Ghostty theme file: `background = #..`, `foreground`, `cursor-color`, `palette = N=#..`.
pub fn loadGhostty(path: []const u8) ?Colors {
    const z = gpa.dupeSentinel(u8, path, 0) catch return null;
    defer gpa.free(z);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(z.ptr, &contents, &len, null) == 0) return null;
    defer glib.free(contents);
    return parseGhostty(contents[0..len]);
}

pub fn parseGhostty(text: []const u8) ?Colors {
    var c: Colors = .{ .palette = stream.builtin_palette };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (std.mem.eql(u8, key, "background")) c.bg = stream.hex(value) else if (std.mem.eql(u8, key, "foreground")) c.fg = stream.hex(value) else if (std.mem.eql(u8, key, "cursor-color")) c.cursor = stream.hex(value) else if (std.mem.eql(u8, key, "palette")) {
            const at = std.mem.indexOfScalar(u8, value, '=') orelse continue;
            const index = std.fmt.parseInt(u8, std.mem.trim(u8, value[0..at], " "), 10) catch continue;
            const color = stream.hex(std.mem.trim(u8, value[at + 1 ..], " "));
            if (color != 0) c.palette.?[index] = color;
        }
    }
    if (c.bg == 0 or c.fg == 0) return null;
    return c;
}

test "ghostty theme files" {
    const c = parseGhostty("# A theme\nbackground = #101010\nforeground = e0e0e0\npalette = 1=#ff0000\ncursor-color = #00ff00\n").?;
    try std.testing.expectEqual(@as(u32, 0xFF101010), c.bg);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), c.palette.?[1]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), c.cursor);
    try std.testing.expect(parseGhostty("nothing = here") == null);
    try std.testing.expect(resolve("Nord") != null);
}

test "the generated palette runs from the background to the foreground" {
    var p = stream.builtin_palette;
    const nord = colorsOf(builtins[0]);
    p = nord.palette.?;
    extendPalette(&p, nord.bg, nord.fg);
    // The cube's corners are the background, the six base colors and the foreground.
    try std.testing.expectEqual(nord.bg, p[16]);
    try std.testing.expectEqual(nord.fg, p[231]);
    try std.testing.expectEqual(p[1], p[16 + 5 * 36]);
    try std.testing.expectEqual(p[2], p[16 + 5 * 6]);
    try std.testing.expectEqual(p[4], p[16 + 5]);
    // The grays are opaque and step evenly between the two, never reaching either.
    for (232..256) |i| try std.testing.expectEqual(@as(u32, 0xFF), p[i] >> 24);
    try std.testing.expect(p[232] != nord.bg and p[255] != nord.fg);
    try std.testing.expectEqual(Rgb.of(nord.bg).mix(Rgb.of(nord.fg), 0.52).pack(), p[244] & 0xffffff);
}
