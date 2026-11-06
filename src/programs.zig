//! What a terminal is running, shown as a program's brand tile like Rex and the Android app do.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const cairo = @import("cairo");
const rsvg = @import("rsvg");
const table = @import("program_icons.zig");

const gpa = std.heap.c_allocator;

const aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "claude-code", "claude" }, .{ "cursor-agent", "cursor" }, .{ "gh", "github" },
    .{ "nvim", "neovim" },        .{ "vi", "vim" },               .{ "python3", "python" },
    .{ "ipython", "python" },     .{ "pip", "python" },           .{ "pip3", "python" },
    .{ "npx", "node" },           .{ "nodejs", "node" },          .{ "psql", "postgres" },
    .{ "sqlite3", "sqlite" },     .{ "kubectl", "kube" },         .{ "kubernetes", "kube" },
    .{ "tofu", "terraform" },     .{ "nu", "nushell" },           .{ "swiftc", "swift" },
    .{ "javac", "java" },         .{ "clang++", "clang" },        .{ "gcc", "clang" },
    .{ "g++", "clang" },          .{ "nix-shell", "nix" },        .{ "redis-server", "redis" },
    .{ "redis-cli", "redis" },    .{ "mysqld", "mysql" },         .{ "xcodebuild", "xcode" },
    .{ "hx", "helix" },
});

/// Simple Icons names for programs whose icon is named differently.
const slugs = std.StaticStringMap([]const u8).initComptime(.{
    .{ "node", "nodedotjs" },         .{ "bash", "gnubash" },        .{ "copilot", "githubcopilot" },
    .{ "gemini", "googlegemini" },    .{ "kube", "kubernetes" },     .{ "mistral", "mistralai" },
    .{ "nix", "nixos" },              .{ "postgres", "postgresql" }, .{ "brew", "homebrew" },
    .{ "clang", "cplusplus" },        .{ "java", "openjdk" },
});

/// The icon for what a block runs: its own status report wins, then its script, then its process
/// (given as `name/script`).
pub fn iconFor(status_app: ?[]const u8, process: ?[]const u8) ?*const table.Icon {
    var buf: [3][64]u8 = undefined;
    var names: [3][]const u8 = undefined;
    var n: usize = 0;
    if (status_app) |app| {
        names[n] = lower(&buf[n], app);
        n += 1;
    }
    if (process) |p| {
        var parts = std.mem.splitScalar(u8, p, '/');
        const name = std.mem.trimStart(u8, parts.first(), "-");
        if (parts.next()) |script| {
            const base = if (std.mem.lastIndexOfScalar(u8, script, '.')) |dot| script[0..dot] else script;
            names[n] = lower(&buf[n], base);
            n += 1;
        }
        names[n] = lower(&buf[n], name);
        n += 1;
    }
    for (names[0..n]) |raw| {
        const name = aliases.get(raw) orelse raw;
        const slug = slugs.get(name) orelse name;
        for (&table.icons) |*icon| if (std.mem.eql(u8, icon.slug, slug)) return icon;
    }
    return null;
}

fn lower(buf: *[64]u8, s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " ");
    const n = @min(t.len, buf.len);
    for (t[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

var handles: std.StringHashMapUnmanaged(*rsvg.Handle) = .empty;

fn handleFor(icon: *const table.Icon, dark_glyph: bool) ?*rsvg.Handle {
    var key_buf: [80]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{}", .{ icon.slug, dark_glyph }) catch return null;
    if (handles.get(key)) |h| return h;
    const svg = std.fmt.allocPrint(gpa, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path fill=\"{s}\" d=\"{s}\"/></svg>", .{
        if (dark_glyph) "#111111" else "#ffffff", icon.path,
    }) catch return null;
    defer gpa.free(svg);
    const h = rsvg.Handle.newFromData(svg.ptr, svg.len, null) orelse return null;
    handles.put(gpa, gpa.dupe(u8, key) catch return h, h) catch {};
    return h;
}

fn luma(c: u32) f64 {
    const r: f64 = @floatFromInt((c >> 16) & 0xff);
    const g: f64 = @floatFromInt((c >> 8) & 0xff);
    const b: f64 = @floatFromInt(c & 0xff);
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

/// Draws a rounded tile of `size` at (x, y): the brand color with the logo, or a neutral tile
/// with a prompt when nothing matches. `neutral` and `ink` are the theme's tile and text colors.
pub fn drawTile(cr: *cairo.Context, icon: ?*const table.Icon, x: f64, y: f64, size: f64, canvas_dark: bool, neutral: u32, ink: u32) void {
    // A near-black or near-white logo would vanish against the canvas, so it gets a neutral tile.
    const brand: ?u32 = if (icon) |i| blk: {
        const l = luma(i.color);
        break :blk if ((canvas_dark and l > 0.04) or (!canvas_dark and l < 0.85)) i.color else null;
    } else null;
    const tile = brand orelse neutral;
    setColor(cr, tile);
    roundRect(cr, x, y, size, size, size * 0.28);
    cr.fill();
    const glyph = size * 0.64;
    const gx = x + (size - glyph) / 2;
    const gy = y + (size - glyph) / 2;
    if (icon) |i| {
        const dark_glyph = if (brand) |b| luma(b) > 0.6 else luma(ink) < 0.5;
        if (handleFor(i, dark_glyph)) |h| {
            const viewport: rsvg.Rectangle = .{ .f_x = gx, .f_y = gy, .f_width = glyph, .f_height = glyph };
            _ = h.renderDocument(cr, &viewport, null);
            return;
        }
    }
    // A prompt, for programs without a logo.
    setColor(cr, ink);
    cr.setLineWidth(size / 11);
    cr.setLineCap(.round);
    cr.setLineJoin(.round);
    cr.moveTo(gx + glyph * 0.12, gy + glyph * 0.25);
    cr.lineTo(gx + glyph * 0.45, gy + glyph * 0.5);
    cr.lineTo(gx + glyph * 0.12, gy + glyph * 0.75);
    cr.stroke();
    cr.moveTo(gx + glyph * 0.55, gy + glyph * 0.8);
    cr.lineTo(gx + glyph * 0.9, gy + glyph * 0.8);
    cr.stroke();
}

fn setColor(cr: *cairo.Context, c: u32) void {
    cr.setSourceRgb(@as(f64, @floatFromInt((c >> 16) & 0xff)) / 255, @as(f64, @floatFromInt((c >> 8) & 0xff)) / 255, @as(f64, @floatFromInt(c & 0xff)) / 255);
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

/// The folder part of a reported directory, shortened under a home directory: `~/compy`.
pub fn shortFolder(buf: []u8, pwd: []const u8) []const u8 {
    var path = pwd;
    if (std.mem.startsWith(u8, path, "file://")) {
        path = path["file://".len..];
        if (std.mem.indexOfScalar(u8, path, '/')) |slash| path = path[slash..] else path = "/";
    }
    for ([_][]const u8{ "/Users/", "/home/" }) |prefix| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;
        const rest = path[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "~";
        return std.fmt.bufPrint(buf, "~{s}", .{rest[slash..]}) catch path;
    }
    if (std.mem.eql(u8, path, "/root")) return "~";
    return path;
}

test "program names map to icons" {
    try std.testing.expectEqualStrings("zsh", iconFor(null, "-zsh").?.slug);
    try std.testing.expectEqualStrings("claude", iconFor(null, "node/claude.js").?.slug);
    try std.testing.expectEqualStrings("nodedotjs", iconFor(null, "node").?.slug);
    try std.testing.expectEqualStrings("claude", iconFor("Claude", "node").?.slug);
    try std.testing.expect(iconFor(null, "weird-thing") == null);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("~/compy", shortFolder(&buf, "file://mac.local/Users/someone/compy"));
    try std.testing.expectEqualStrings("~", shortFolder(&buf, "/home/someone"));
    try std.testing.expectEqualStrings("/etc", shortFolder(&buf, "/etc"));
}
