//! What a terminal is running, shown as a program's brand tile like Rex and the Android app do.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const cairo = @import("cairo");
const rsvg = @import("rsvg");
const table = @import("program_icons.zig");
const draw = @import("../util/draw.zig");

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
    .{ "hx", "helix" },                .{ "cargo", "rust" },          .{ "rustc", "rust" },
    .{ "rustup", "rust" },             .{ "irb", "ruby" },            .{ "gem", "ruby" },
    .{ "bundle", "ruby" },             .{ "rake", "ruby" },           .{ "erl", "erlang" },
    .{ "dune", "ocaml" },              .{ "opam", "ocaml" },          .{ "composer", "php" },
    .{ "scp", "ssh" },                 .{ "sftp", "ssh" },            .{ "mosh", "ssh" },
    .{ "codex-cli", "codex" },         .{ "btop", "htop" },           .{ "top", "htop" },
});

/// Simple Icons names for programs whose icon is named differently.
const slugs = std.StaticStringMap([]const u8).initComptime(.{
    .{ "node", "nodedotjs" },         .{ "bash", "gnubash" },        .{ "copilot", "githubcopilot" },
    .{ "gemini", "googlegemini" },    .{ "kube", "kubernetes" },     .{ "mistral", "mistralai" },
    .{ "nix", "nixos" },              .{ "postgres", "postgresql" }, .{ "brew", "homebrew" },
    .{ "clang", "cplusplus" },        .{ "java", "openjdk" },        .{ "fish", "fishshell" },
});

/// Coding agents by the names their programs go by, for telling an agent's pane from a shell's.
const agents = std.StaticStringMap(void).initComptime(.{
    .{"claude"},   .{"claude-code"}, .{"codex"},  .{"codex-cli"}, .{"opencode"},     .{"pi"},
    .{"gemini"},   .{"cursor-agent"}, .{"amp"},   .{"aider"},     .{"copilot"},      .{"goose"},
    .{"crush"},    .{"droid"},        .{"qwen"},  .{"cline"},     .{"kiro"},
});

/// Whether what a block runs (given as `name/script`) is a coding agent.
pub fn isAgent(process: ?[]const u8) bool {
    const p = process orelse return false;
    var buf: [64]u8 = undefined;
    var parts = std.mem.splitScalar(u8, p, '/');
    const name = std.mem.trimStart(u8, parts.first(), "-");
    if (agents.has(lower(&buf, name))) return true;
    const script = parts.next() orelse return false;
    const base = if (std.mem.lastIndexOfScalar(u8, script, '.')) |dot| script[0..dot] else script;
    return agents.has(lower(&buf, base));
}

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
    const h = draw.svgHandle(icon.path, "", if (dark_glyph) "#111111" else "#ffffff") orelse return null;
    handles.put(gpa, gpa.dupe(u8, key) catch return h, h) catch {};
    return h;
}

const luma = draw.luma;
const setColor = draw.setColor;
const roundRect = draw.roundRect;

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

/// A program's own name from what a block reports (`name/script`, a login shell as `-zsh`).
pub fn programName(process: []const u8) []const u8 {
    return std.mem.trimStart(u8, process[0 .. std.mem.indexOfScalar(u8, process, '/') orelse process.len], "-");
}

/// What runs in a pane and where, such as "zsh ~/renux": the program's name, then its folder
/// when one is known. A pane that reported nothing is a shell.
pub fn displayTitle(buf: []u8, process: ?[]const u8, folder: ?[]const u8) []const u8 {
    const name = programName(process orelse "shell");
    const f = folder orelse return name;
    var folder_buf: [256]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ name, shortFolder(&folder_buf, f) }) catch name;
}

/// The folder part of a reported directory, shortened under a home directory: `~/renux`.
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
    try std.testing.expectEqualStrings("neovim", iconFor(null, "nvim").?.slug);
    try std.testing.expectEqualStrings("codex", iconFor("codex", "node").?.slug);
    try std.testing.expectEqualStrings("rust", iconFor(null, "cargo").?.slug);
    try std.testing.expectEqualStrings("fishshell", iconFor(null, "-fish").?.slug);
    try std.testing.expectEqualStrings("lazygit", iconFor(null, "lazygit").?.slug);
    try std.testing.expectEqualStrings("ssh", iconFor(null, "mosh").?.slug);
    try std.testing.expect(iconFor(null, "weird-thing") == null);
    try std.testing.expect(isAgent("node/claude.js"));
    try std.testing.expect(isAgent("codex"));
    try std.testing.expect(!isAgent("-zsh"));
    try std.testing.expect(!isAgent("nvim"));
    try std.testing.expect(!isAgent(null));
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("~/renux", shortFolder(&buf, "file://mac.local/Users/someone/renux"));
    try std.testing.expectEqualStrings("~", shortFolder(&buf, "/home/someone"));
    try std.testing.expectEqualStrings("/etc", shortFolder(&buf, "/etc"));
}

test "titles name the program and its folder" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("zsh", programName("-zsh"));
    try std.testing.expectEqualStrings("node", programName("node/claude.js"));
    try std.testing.expectEqualStrings("zsh ~/renux", displayTitle(&buf, "-zsh", "/home/someone/renux"));
    try std.testing.expectEqualStrings("claude", displayTitle(&buf, "claude", null));
    try std.testing.expectEqualStrings("shell /etc", displayTitle(&buf, null, "/etc"));
    // A title too long for the buffer falls back to the name alone.
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("vim", displayTitle(&small, "vim", "/var/log"));
}

test {
    _ = @import("../util/draw.zig");
}
