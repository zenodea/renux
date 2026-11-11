//! Renux's settings, kept in ~/.config/renux/settings.ini. Everything here only changes this
//! app; nothing is sent to a Rex server.
const std = @import("std");
const glib = @import("glib");

const gpa = std.heap.c_allocator;

/// The narrowest the sidebar goes: room for a row's icon, a few letters and its menu.
pub const sidebar_min: f64 = 130;
pub const ColorScheme = enum { auto, light, dark };
pub const CursorStyle = enum { program, block, bar, underline };
/// Where a session's windows show as tabs: in the sidebar on the left or right, or above the panes.
pub const TabPosition = enum { left, right, above };
pub const BoldItalic = enum { fonts, plain };
pub const PaddingColor = enum { terminal, theme };

pub const Host = struct { label: []u8, url: []u8 };

/// A key sequence set in Renux for an action, over the config's own. Empty keys unbind it.
pub const Shortcut = struct { keys: []u8, action: []u8, args: []u8 };

pub const Settings = struct {
    font: []u8,
    tight: bool = false,
    show_headers: bool = true,
    color_scheme: ColorScheme = .auto,
    brand_icons: bool = true,
    cursor_style: CursorStyle = .program,
    cursor_blink: bool = true,
    /// Panes without the keyboard show where their cursor is as an outline; off leaves it out.
    inactive_cursor: bool = true,
    /// The bar cursor's width in pixels.
    cursor_width: f64 = 2,
    /// Row height as a multiple of the font's own line height.
    line_height: f64 = 1,
    /// A Shadertoy-style GLSL file, as Ghostty's custom-shader, that panes are drawn through;
    /// empty for none.
    custom_shader: []u8,
    /// The shader drawn once over the whole window at its one cursor, which moves from pane to
    /// pane with the keyboard; empty for none.
    cursor_shader: []u8,
    /// The shaders' sliders: `shader|NAME|value` entries, split by `;`.
    shader_params: []u8,
    /// Extra pixels between characters; negative brings them closer.
    letter_spacing: f64 = 0,
    /// How opaque the window behind the panes is, from 0.2 to 1.
    window_opacity: f64 = 1,
    /// How opaque the terminals are, from 0.2 to 1. Floating panes stay solid.
    terminal_opacity: f64 = 1,
    /// Blurs what shows through. On Linux the desktop decides; KDE and Hyprland do it.
    blur: bool = true,
    /// The sidebar's width in pixels, set by dragging its edge.
    sidebar_width: f64 = 250,
    /// How far a trackpad's movement scrolls a terminal, as a multiple of the fingers' own.
    scroll_speed: f64 = 2,
    /// After a prefix such as ctrl+a, list the keys that can follow.
    key_hints: bool = true,
    /// Whether the welcome pages have been seen.
    welcomed: bool = false,
    /// Show the window at launch; off starts hidden until `renux --toggle`.
    show_on_launch: bool = true,
    /// Two-finger swipes sideways switch tabs.
    trackpad_gestures: bool = true,
    sidebar_text_scale: f64 = 1,
    /// A count of panes that need you, on the Dock or the desktop's launcher.
    unread_badge: bool = true,
    /// Pointing at a pane gives it the keyboard.
    focus_follows_mouse: bool = false,
    /// How much panes without the keyboard fade, 0 to 0.6.
    fade_inactive: f64 = 0,
    /// Fade every pane while Renux isn't the active window.
    fade_inactive_window: bool = false,
    /// The pane with the keyboard shows a colored border.
    highlight_border: bool = true,
    highlight_opacity: f64 = 0.85,
    highlight_animate: bool = true,
    /// 0 is the theme's accent; otherwise 0xRRGGBB.
    highlight_color: u32 = 0,
    /// Splits share space evenly after a pane comes or goes.
    autobalance: bool = false,
    /// A pane's frame takes its program's background color.
    match_program_bg: bool = false,
    rounded_selection: bool = true,
    /// How round a rounded selection's outer corners are, in points.
    selection_radius: f64 = 7,
    ligatures: bool = true,
    font_smoothing: bool = true,
    /// Bold and italic text in their own faces, or all in the regular one.
    bold_italic: BoldItalic = .fonts,
    cursor_blink_ms: f64 = 530,
    /// The character under a block cursor; 0 uses the terminal's background.
    cursor_text_color: u32 = 0,
    /// 0 swaps the text's own colors.
    selection_bg: u32 = 0,
    selection_fg: u32 = 0,
    pad_x: f64 = 8,
    pad_y: f64 = 8,
    padding_color: PaddingColor = .terminal,
    /// Colors 16 to 255 made from the theme's own 16, so they match it.
    extended_palette: bool = false,
    copy_animation: bool = true,
    /// The agent board lists each column's cards under their sessions' names.
    board_by_session: bool = false,
    /// Link schemes, such as vscode, that open their app without asking.
    trusted_schemes: std.ArrayList([]u8) = .empty,
    tab_position: TabPosition = .left,
    /// Tabs above the panes share the width between them.
    tab_fill: bool = true,
    /// A tab lists every program in its window, not just the focused one.
    tab_processes: bool = false,
    alerts: bool = true,
    alert_blocked: bool = true,
    alert_error: bool = true,
    alert_done: bool = true,
    sound: bool = false,
    terminal_notifications: bool = true,
    improve_contrast: bool = true,
    visual_bell: bool = true,
    paste_warning: bool = true,
    /// Selecting text in a pane also puts it on the clipboard, not only the primary selection.
    copy_on_select: bool = true,
    /// Empty follows each host's theme; otherwise a built-in theme's name or `file:PATH`.
    theme: []u8,
    /// Empty uses this computer's name.
    client_label: []u8,
    /// Look up whether a later Rex than a server runs has been released.
    rex_updates: bool = true,
    /// Keep this computer's Rex server on the tailnet. A restarted server starts with its
    /// Tailscale node off, so Renux turns it on again each time it connects.
    local_tailscale: bool = false,
    /// Let anyone the tailnet's access rules allow reach that server, not only the Tailscale
    /// account that signed it in.
    tailscale_open: bool = false,
    /// The name its Tailscale device asks for; empty takes Rex's own choice.
    tailscale_hostname: []u8,
    /// Let Rex and other clients perform actions in this app, such as focusing a pane.
    remote_control: bool = true,
    /// The release last announced, so each is announced once and not at every start.
    rex_update_told: []u8,
    /// Separate themes for a light and a dark system appearance, instead of `theme`.
    theme_follow_system: bool = false,
    theme_light: []u8,
    theme_dark: []u8,
    hosts: std.ArrayList(Host) = .empty,
    /// Folders panes were in lately, newest first, for Go to Anything.
    recent_paths: std.ArrayList([]u8) = .empty,
    recent_paths_shown: bool = true,
    shortcuts: std.ArrayList(Shortcut) = .empty,
};

/// Sets (or, with `keys` null, removes) Renux's own shortcut for an action and its arguments.
pub fn setShortcut(action: []const u8, args: []const u8, keys: ?[]const u8) void {
    const list = &current.shortcuts;
    for (list.items, 0..) |sc, i| if (std.mem.eql(u8, sc.action, action) and std.mem.eql(u8, sc.args, args)) {
        gpa.free(sc.keys);
        gpa.free(sc.action);
        gpa.free(sc.args);
        _ = list.orderedRemove(i);
        break;
    };
    if (keys) |k| appendShortcut(k, action, args);
    save();
}

/// Puts a folder first among the recent ones, keeping at most 30.
pub fn addRecentPath(path: []const u8) void {
    const list = &current.recent_paths;
    for (list.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) {
        if (i == 0) return;
        const keep = list.orderedRemove(i);
        list.insert(gpa, 0, keep) catch gpa.free(keep);
        return save();
    };
    const copy = gpa.dupe(u8, path) catch return;
    list.insert(gpa, 0, copy) catch return gpa.free(copy);
    while (list.items.len > 30) gpa.free(list.pop().?);
    save();
}

pub var current: Settings = undefined;

const log = std.log.scoped(.settings);

/// Set when settings.ini is there but can't be read or written. Renux then leaves the file
/// alone, so a slip made editing it by hand costs nothing; the Settings window shows this.
pub var problem: ?[:0]const u8 = null;

/// Tests keep their files here instead of in the person's own config folder.
pub var test_dir: ?[]const u8 = null;

fn configDir() []const u8 {
    return test_dir orelse std.mem.span(glib.getUserConfigDir());
}

fn dir() ?[:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/renux", .{configDir()}, 0) catch null;
}

fn file() ?[:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/renux/settings.ini", .{configDir()}, 0) catch null;
}

// Every field of `Settings` that isn't a list is one key of the [renux] group, read and written
// from the field itself: its name with dashes is the key, its type says how it is stored and its
// default is the one in the struct. So a new setting is declared once, there. Only what a field
// can't say lives here: keys that differ from the name, the range of each number and the
// starting text of each string.

const renamed = [_][2][:0]const u8{
    .{ "pad_x", "padding-x" },
    .{ "pad_y", "padding-y" },
    .{ "recent_paths_shown", "recent-paths" },
};

const ranges = [_]struct { []const u8, f64, f64 }{
    .{ "cursor_width", 1, 6 },
    .{ "line_height", 0.8, 2 },
    .{ "letter_spacing", -2, 6 },
    .{ "window_opacity", 0.2, 1 },
    .{ "terminal_opacity", 0.2, 1 },
    .{ "sidebar_width", sidebar_min, 480 },
    .{ "scroll_speed", 0.5, 5 },
    .{ "sidebar_text_scale", 0.8, 1.4 },
    .{ "fade_inactive", 0, 0.6 },
    .{ "highlight_opacity", 0.1, 1 },
    .{ "selection_radius", 1, 16 },
    .{ "cursor_blink_ms", 200, 2000 },
    .{ "pad_x", 0, 40 },
    .{ "pad_y", 0, 40 },
};

const texts = [_][2][]const u8{
    .{ "font", "Monospace 11" },
    .{ "theme_light", "Solarized Light" },
};

const fields = @typeInfo(Settings).@"struct";

fn isList(comptime T: type) bool {
    return T == std.ArrayList([]u8) or T == std.ArrayList(Host) or T == std.ArrayList(Shortcut);
}

fn keyOf(comptime name: []const u8) [:0]const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        for (renamed) |r| if (std.mem.eql(u8, r[0], name)) break :blk r[1];
        var buf: [name.len:0]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const out = buf;
        break :blk &out;
    };
}

fn rangeOf(comptime name: []const u8) [2]f64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        for (ranges) |r| if (std.mem.eql(u8, r[0], name)) break :blk .{ r[1], r[2] };
        @compileError("the number setting " ++ name ++ " needs a range in settings.zig");
    };
}

fn textOf(comptime name: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        for (texts) |t| if (std.mem.eql(u8, t[0], name)) break :blk t[1];
        break :blk "";
    };
}

fn str(kf: *glib.KeyFile, key: [*:0]const u8, default: []const u8) []u8 {
    // Out of memory leaves it empty, which every use takes and `gpa.free` accepts.
    const v = kf.getString("renux", key, null) orelse return gpa.dupe(u8, default) catch &.{};
    defer glib.free(v);
    return gpa.dupe(u8, std.mem.span(v)) catch &.{};
}

fn boolean(kf: *glib.KeyFile, key: [*:0]const u8, default: bool) bool {
    var err: ?*glib.Error = null;
    const v = kf.getBoolean("renux", key, &err);
    if (err) |e| {
        e.free();
        return default;
    }
    return v != 0;
}

fn number(kf: *glib.KeyFile, key: [*:0]const u8, default: f64, min: f64, max: f64) f64 {
    var err: ?*glib.Error = null;
    const v = kf.getDouble("renux", key, &err);
    if (err) |e| {
        e.free();
        return default;
    }
    return if (std.math.isFinite(v)) std.math.clamp(v, min, max) else default;
}

fn enumOf(comptime E: type, kf: *glib.KeyFile, key: [*:0]const u8, default: E) E {
    const v = kf.getString("renux", key, null) orelse return default;
    defer glib.free(v);
    return std.meta.stringToEnum(E, std.mem.span(v)) orelse default;
}

fn readScalars(kf: *glib.KeyFile, s: *Settings) void {
    inline for (fields.field_names, fields.field_types, fields.field_attrs) |name, T, attrs| {
        if (comptime isList(T)) {
            @field(s, name) = .empty;
            continue;
        }
        const key = comptime keyOf(name);
        @field(s, name) = switch (T) {
            []u8 => str(kf, key, comptime textOf(name)),
            bool => boolean(kf, key, comptime attrs.defaultValue(T).?),
            f64 => number(kf, key, comptime attrs.defaultValue(T).?, comptime rangeOf(name)[0], comptime rangeOf(name)[1]),
            // A color, 0xRRGGBB, with 0 for none.
            u32 => @intFromFloat(number(kf, key, @floatFromInt(comptime attrs.defaultValue(T).?), 0, 0xffffff)),
            else => enumOf(T, kf, key, comptime attrs.defaultValue(T).?),
        };
    }
}

fn writeScalars(kf: *glib.KeyFile, s: *const Settings) error{OutOfMemory}!void {
    inline for (fields.field_names, fields.field_types) |name, T| {
        if (comptime isList(T)) continue;
        const key = comptime keyOf(name);
        const v = @field(s, name);
        switch (T) {
            []u8 => {
                const z = try gpa.dupeSentinel(u8, v, 0);
                defer gpa.free(z);
                kf.setString("renux", key, z.ptr);
            },
            bool => kf.setBoolean("renux", key, @intFromBool(v)),
            f64 => kf.setDouble("renux", key, v),
            u32 => kf.setDouble("renux", key, @floatFromInt(v)),
            else => kf.setString("renux", key, @tagName(v)),
        }
    }
}

fn readList(kf: *glib.KeyFile, group: [*:0]const u8, key: [*:0]const u8, out: *std.ArrayList([]u8)) void {
    var n: usize = 0;
    const list = kf.getStringList(group, key, &n, null) orelse return;
    defer glib.strfreev(@ptrCast(list));
    for (0..n) |i| if (std.mem.span(list[i])) |item| {
        const copy = gpa.dupe(u8, item) catch continue;
        out.append(gpa, copy) catch gpa.free(copy);
    };
}

fn writeList(kf: *glib.KeyFile, group: [*:0]const u8, key: [*:0]const u8, items: []const []const u8) error{OutOfMemory}!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const list = try arena.allocator().alloc(?[*:0]const u8, items.len);
    for (items, list) |item, *slot| slot.* = (try arena.allocator().dupeSentinel(u8, item, 0)).ptr;
    kf.setStringList(group, key, @ptrCast(list.ptr), list.len);
}

/// Everything in `s`, as the key file that holds it.
fn toKeyFile(s: *const Settings) error{OutOfMemory}!*glib.KeyFile {
    const kf = glib.KeyFile.new();
    errdefer kf.unref();
    try writeScalars(kf, s);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    // Hosts are stored as matching lists of labels and addresses.
    const labels = try al.alloc([]const u8, s.hosts.items.len);
    const urls = try al.alloc([]const u8, s.hosts.items.len);
    for (s.hosts.items, labels, urls) |h, *l, *u| {
        l.* = h.label;
        u.* = h.url;
    }
    try writeList(kf, "hosts", "labels", labels);
    try writeList(kf, "hosts", "urls", urls);
    try writeList(kf, "paths", "recent", s.recent_paths.items);
    try writeList(kf, "links", "trusted", s.trusted_schemes.items);
    // Each shortcut is "keys<TAB>action<TAB>args".
    const lines = try al.alloc([]const u8, s.shortcuts.items.len);
    for (s.shortcuts.items, lines) |sc, *line| line.* = try std.fmt.allocPrint(al, "{s}\t{s}\t{s}", .{ sc.keys, sc.action, sc.args });
    try writeList(kf, "shortcuts", "bindings", lines);
    return kf;
}

const Read = enum { ok, missing, broken };

/// Reads settings.ini into `kf`, keeping its comments and the keys Renux doesn't know.
fn readFile(kf: *glib.KeyFile) Read {
    const f = file() orelse return .missing;
    defer gpa.free(f);
    var err: ?*glib.Error = null;
    if (kf.loadFromFile(f.ptr, .{ .keep_comments = true, .keep_translations = true }, &err) != 0) return .ok;
    const e = err orelse return .broken;
    defer e.free();
    if (e.matches(glib.fileErrorQuark(), @intFromEnum(glib.FileError.noent)) != 0) return .missing;
    log.warn("settings.ini can't be read, so it is left as it is: {s}", .{if (e.f_message) |m| std.mem.span(m) else "unknown error"});
    return .broken;
}

const unreadable = "settings.ini can't be read, so changes made now aren't saved. Fix or remove the file.";
const unwritable = "settings.ini can't be written, so changes made now aren't saved.";

/// What this process last read from or wrote to the file. A save writes only the keys that
/// differ from it, so the changes another Renux window made in the meantime stay.
var base: ?*glib.KeyFile = null;
var dirty = false;
var timer: c_uint = 0;

/// The app was first called Compy and kept its files in ~/.config/compy under a [compy] group.
/// A person who has those and nothing under the new name keeps them: the folder is renamed,
/// custom themes and all, and the group with it.
fn adoptOldName() void {
    const new = dir() orelse return;
    defer gpa.free(new);
    if (glib.fileTest(new.ptr, .{ .exists = true }) != 0) return;
    const old = std.fmt.allocPrintSentinel(gpa, "{s}/compy", .{configDir()}, 0) catch return;
    defer gpa.free(old);
    if (glib.fileTest(old.ptr, .{ .is_dir = true }) == 0) return;
    if (std.c.rename(old.ptr, new.ptr) != 0) return;
    const f = file() orelse return;
    defer gpa.free(f);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(f.ptr, &contents, &len, null) == 0) return;
    defer glib.free(contents);
    const text = std.mem.replaceOwned(u8, gpa, contents[0..len], "[compy]", "[renux]") catch return;
    defer gpa.free(text);
    _ = glib.fileSetContents(f.ptr, @ptrCast(text.ptr), @intCast(text.len), null);
}

test adoptOldName {
    var tmp_buf: [64]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "/tmp/renux-adopt-{d}", .{std.c.getpid()}, 0) catch unreachable;
    var path_buf: [128]u8 = undefined;
    const old = std.fmt.bufPrintSentinel(&path_buf, "{s}/compy", .{tmp}, 0) catch unreachable;
    _ = glib.mkdirWithParents(old.ptr, 0o700);
    var ini_buf: [160]u8 = undefined;
    const old_ini = std.fmt.bufPrintSentinel(&ini_buf, "{s}/settings.ini", .{old}, 0) catch unreachable;
    const before = "[compy]\nfont-size=17\n";
    _ = glib.fileSetContents(old_ini.ptr, before, before.len, null);
    const saved = test_dir;
    test_dir = tmp;
    defer test_dir = saved;
    adoptOldName();
    const f = file().?;
    defer gpa.free(f);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(glib.fileGetContents(f.ptr, &contents, &len, null) != 0);
    defer glib.free(contents);
    try std.testing.expectEqualStrings("[renux]\nfont-size=17\n", contents[0..len]);
    try std.testing.expect(glib.fileTest(old.ptr, .{ .exists = true }) == 0);
    _ = std.c.unlink(f.ptr);
    const d = dir().?;
    defer gpa.free(d);
    _ = std.c.rmdir(d.ptr);
    _ = std.c.rmdir(tmp.ptr);
}

pub fn load() void {
    adoptOldName();
    const kf = glib.KeyFile.new();
    defer kf.unref();
    problem = if (readFile(kf) == .broken) unreadable else null;
    readScalars(kf, &current);
    const s = &current;
    readList(kf, "links", "trusted", &s.trusted_schemes);
    readList(kf, "paths", "recent", &s.recent_paths);
    {
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |l| gpa.free(l);
            lines.deinit(gpa);
        }
        readList(kf, "shortcuts", "bindings", &lines);
        for (lines.items) |line| {
            var parts = std.mem.splitScalar(u8, line, '\t');
            const k = parts.next() orelse continue;
            const act = parts.next() orelse continue;
            appendShortcut(k, act, parts.next() orelse "");
        }
    }
    {
        var labels: std.ArrayList([]u8) = .empty;
        var urls: std.ArrayList([]u8) = .empty;
        defer for ([_]*std.ArrayList([]u8){ &labels, &urls }) |list| {
            for (list.items) |l| gpa.free(l);
            list.deinit(gpa);
        };
        readList(kf, "hosts", "labels", &labels);
        readList(kf, "hosts", "urls", &urls);
        for (0..@min(labels.items.len, urls.items.len)) |i| addHostNoSave(labels.items[i], urls.items[i]);
    }
    if (base) |old| old.unref();
    base = toKeyFile(&current) catch null;
    dirty = false;
    migrateOldServer();
}

fn appendShortcut(keys: []const u8, action: []const u8, args: []const u8) void {
    const k = gpa.dupe(u8, keys) catch return;
    const act = gpa.dupe(u8, action) catch return gpa.free(k);
    const ar = gpa.dupe(u8, args) catch {
        gpa.free(k);
        return gpa.free(act);
    };
    current.shortcuts.append(gpa, .{ .keys = k, .action = act, .args = ar }) catch {
        gpa.free(k);
        gpa.free(act);
        gpa.free(ar);
    };
}

/// The first version kept one server address in ~/.config/renux/server.
fn migrateOldServer() void {
    if (current.hosts.items.len > 0) return;
    const old = std.fmt.allocPrintSentinel(gpa, "{s}/renux/server", .{configDir()}, 0) catch return;
    defer gpa.free(old);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(old.ptr, &contents, &len, null) == 0) return;
    defer glib.free(contents);
    const url = std.mem.trim(u8, contents[0..len], " \n\r\t");
    if (url.len == 0) return;
    addHostNoSave(labelFor(url), url);
    save();
}

/// A short name for an address: its host part, before any dot.
pub fn labelFor(url: []const u8) []const u8 {
    // A socket is only ever this computer's own server.
    if (std.mem.startsWith(u8, url, "unix://")) return "This Computer";
    var rest = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    rest = rest[0 .. std.mem.indexOfAny(u8, rest, ":/") orelse rest.len];
    // A numeric address says nothing without all of it.
    if (rest.len > 0 and std.ascii.isDigit(rest[0])) return rest;
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '.') orelse rest.len];
}

fn addHostNoSave(label: []const u8, url: []const u8) void {
    // One entry per address, which also drops repeats saved before this check.
    const clean = std.mem.trimEnd(u8, url, "/");
    for (current.hosts.items) |h| if (std.mem.eql(u8, h.url, clean)) return;
    current.hosts.append(gpa, .{
        .label = gpa.dupe(u8, label) catch return,
        .url = gpa.dupe(u8, std.mem.trimEnd(u8, url, "/")) catch return,
    }) catch {};
}

pub fn addHost(label: []const u8, url: []const u8) void {
    addHostNoSave(label, url);
    // Written at once: a window opened next is another process, which reads the file.
    save();
    flush();
}

pub fn removeHost(index: usize) void {
    if (index >= current.hosts.items.len) return;
    const h = current.hosts.orderedRemove(index);
    gpa.free(h.label);
    gpa.free(h.url);
    save();
    flush();
}

pub fn setString(slot: *[]u8, value: []const u8) void {
    const copy = gpa.dupe(u8, value) catch return;
    gpa.free(slot.*);
    slot.* = copy;
    save();
}

/// The folder the settings file lives in, for watching it. The caller frees it.
pub fn folder() ?[:0]u8 {
    return dir();
}

/// Reads the file again after something else wrote it: a script that switches themes, another
/// Renux window, an editor. Whatever this window has yet to save is written first, so nothing
/// is lost either way. Only plain settings are taken up, not the lists (hosts, shortcuts,
/// recent folders), which a running window keeps as they are. True if any setting changed.
pub fn reload() bool {
    if (dirty) flush();
    const kf = glib.KeyFile.new();
    defer kf.unref();
    if (readFile(kf) != .ok) return false;
    var fresh: Settings = undefined;
    readScalars(kf, &fresh);
    var changed = false;
    inline for (fields.field_names, fields.field_types) |name, T| {
        if (comptime isList(T)) continue;
        if (T == []u8) {
            if (std.mem.eql(u8, @field(current, name), @field(fresh, name))) {
                gpa.free(@field(fresh, name));
            } else {
                gpa.free(@field(current, name));
                @field(current, name) = @field(fresh, name);
                changed = true;
            }
        } else if (!std.meta.eql(@field(current, name), @field(fresh, name))) {
            @field(current, name) = @field(fresh, name);
            changed = true;
        }
    }
    if (changed) {
        // What was read is what the file holds, so the next save leaves those keys alone.
        if (toKeyFile(&current)) |now| {
            if (base) |old| old.unref();
            base = now;
        } else |_| {}
    }
    return changed;
}

/// Notes that a setting changed. The file is written a second later, so a burst of changes
/// (a spinner held down, a pane changing folder over and over) is one write.
pub fn save() void {
    dirty = true;
    if (timer == 0) timer = glib.timeoutAdd(1000, &onTimer, null);
}

fn onTimer(_: ?*anyopaque) callconv(.c) c_int {
    timer = 0;
    flush();
    return 0;
}

/// Writes what changed now: as Renux quits, and for changes another window is about to read.
pub fn flush() void {
    if (timer != 0) {
        _ = glib.Source.remove(timer);
        timer = 0;
    }
    if (!dirty) return;
    // A test that hasn't set up a folder of its own never reaches the person's real settings.
    if (@import("builtin").is_test and test_dir == null) return;
    const mine = toKeyFile(&current) catch return;
    var keep = false;
    defer if (!keep) mine.unref();
    // The file as it is now, which another window may have written since this one read it.
    const disk = glib.KeyFile.new();
    defer disk.unref();
    if (readFile(disk) == .broken) {
        problem = unreadable;
        return;
    }
    merge(disk, mine, base);
    const d = dir() orelse return;
    defer gpa.free(d);
    _ = glib.mkdirWithParents(d.ptr, 0o700);
    const f = file() orelse return;
    defer gpa.free(f);
    var err: ?*glib.Error = null;
    if (disk.saveToFile(f.ptr, &err) == 0) {
        if (err) |e| {
            log.warn("settings.ini can't be written: {s}", .{if (e.f_message) |m| std.mem.span(m) else "unknown error"});
            e.free();
        }
        problem = unwritable;
        return;
    }
    problem = null;
    dirty = false;
    if (base) |old| old.unref();
    base = mine;
    keep = true;
}

fn sameValue(kf: ?*glib.KeyFile, group: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) bool {
    const other = (kf orelse return false).getValue(group, key, null) orelse return false;
    defer glib.free(other);
    return std.mem.eql(u8, std.mem.span(other), std.mem.span(value));
}

/// Copies into `disk` every key of `mine` whose value isn't the one in `since`.
fn merge(disk: *glib.KeyFile, mine: *glib.KeyFile, since: ?*glib.KeyFile) void {
    const groups = mine.getGroups(null);
    defer glib.strfreev(@ptrCast(groups));
    var gi: usize = 0;
    while (groups[gi]) |group| : (gi += 1) {
        const names = mine.getKeys(group, null, null) orelse continue;
        defer glib.strfreev(@ptrCast(names));
        // A host's label and address are two lists that only make sense together.
        var whole_group = false;
        if (std.mem.eql(u8, std.mem.span(group), "hosts")) {
            var hi: usize = 0;
            while (names[hi]) |key| : (hi += 1) {
                const value = mine.getValue(group, key, null) orelse continue;
                defer glib.free(value);
                if (!sameValue(since, group, key, value)) whole_group = true;
            }
        }
        var ki: usize = 0;
        while (names[ki]) |key| : (ki += 1) {
            const value = mine.getValue(group, key, null) orelse continue;
            defer glib.free(value);
            if (whole_group or !sameValue(since, group, key, value)) disk.setValue(group, key, value);
        }
    }
}

fn clearForTest() void {
    if (timer != 0) _ = glib.Source.remove(timer);
    timer = 0;
    if (base) |old| old.unref();
    base = null;
    dirty = false;
    problem = null;
}

/// A folder of its own for one test's settings.ini, with `text` in the file when given.
fn testFolder(text: ?[]const u8) ![:0]u8 {
    const tmp = glib.Dir.makeTmp("renux-test-XXXXXX", null) orelse return error.NoTempFolder;
    defer glib.free(tmp);
    const root = try gpa.dupeSentinel(u8, std.mem.span(tmp), 0);
    test_dir = root;
    clearForTest();
    if (text) |t| {
        const d = dir().?;
        defer gpa.free(d);
        _ = glib.mkdirWithParents(d.ptr, 0o700);
        try writeTestFile(t);
    }
    return root;
}

fn writeTestFile(text: []const u8) !void {
    const f = file().?;
    defer gpa.free(f);
    if (glib.fileSetContents(f.ptr, @ptrCast(text.ptr), @intCast(text.len), null) == 0) return error.WriteFailed;
}

fn readTestFile() ![]u8 {
    const f = file().?;
    defer gpa.free(f);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(f.ptr, &contents, &len, null) == 0) return error.ReadFailed;
    defer glib.free(contents);
    return gpa.dupe(u8, contents[0..len]);
}

fn removeTestFolder(root: [:0]u8) void {
    if (file()) |f| {
        _ = glib.unlink(f.ptr);
        gpa.free(f);
    }
    if (dir()) |d| {
        _ = glib.rmdir(d.ptr);
        gpa.free(d);
    }
    _ = glib.rmdir(root.ptr);
    clearForTest();
    test_dir = null;
    gpa.free(root);
}

test "every setting comes back as it was saved" {
    const root = try testFolder(null);
    defer removeTestFolder(root);
    load();
    try std.testing.expectEqualStrings("Monospace 11", current.font);
    try std.testing.expectEqualStrings("Solarized Light", current.theme_light);
    try std.testing.expect(current.show_headers and !current.tight);
    setString(&current.font, "Iosevka 13");
    current.tight = true;
    current.pad_x = 12;
    current.cursor_style = .bar;
    current.highlight_color = 0x4fe3c1;
    current.recent_paths_shown = false;
    addHostNoSave("box", "http://box:8765/");
    addRecentPath("/srv/app");
    setShortcut("pane.close", "", "ctrl+a x");
    flush();
    load();
    try std.testing.expectEqualStrings("Iosevka 13", current.font);
    try std.testing.expect(current.tight);
    try std.testing.expectEqual(@as(f64, 12), current.pad_x);
    try std.testing.expectEqual(CursorStyle.bar, current.cursor_style);
    try std.testing.expectEqual(@as(u32, 0x4fe3c1), current.highlight_color);
    try std.testing.expect(!current.recent_paths_shown);
    try std.testing.expectEqual(@as(usize, 1), current.hosts.items.len);
    try std.testing.expectEqualStrings("http://box:8765", current.hosts.items[0].url);
    try std.testing.expectEqualStrings("/srv/app", current.recent_paths.items[0]);
    try std.testing.expectEqualStrings("ctrl+a x", current.shortcuts.items[0].keys);
    // The keys in the file are the ones older versions wrote.
    const text = try readTestFile();
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "padding-x=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "recent-paths=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cursor-style=bar") != null);
}

test "a save keeps what another window wrote, unknown keys and comments" {
    const root = try testFolder("# mine\n[renux]\ntheme=Nord\nfrom-the-future=1\n");
    defer removeTestFolder(root);
    load();
    try std.testing.expectEqualStrings("Nord", current.theme);
    // Another window changes the theme and adds a host while this one is open.
    try writeTestFile("# mine\n[renux]\ntheme=Dracula\nfrom-the-future=1\n\n[hosts]\nlabels=box;\nurls=http://box:8765;\n");
    current.tight = true;
    save();
    flush();
    const text = try readTestFile();
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "theme=Dracula") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "from-the-future=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# mine") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tight=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "labels=box;") != null);
    // What this window didn't change isn't written at all.
    try std.testing.expect(std.mem.indexOf(u8, text, "font=") == null);
}

test "a settings file that can't be read is left alone" {
    const broken = "[renux\ntheme=Nord\n";
    const root = try testFolder(broken);
    defer removeTestFolder(root);
    load();
    try std.testing.expect(problem != null);
    try std.testing.expectEqualStrings("", current.theme);
    current.tight = true;
    save();
    flush();
    const text = try readTestFile();
    defer gpa.free(text);
    try std.testing.expectEqualStrings(broken, text);
    // Once the file is fixed, the change waiting to be saved goes in.
    try writeTestFile("[renux]\ntheme=Nord\n");
    flush();
    try std.testing.expect(problem == null);
    const fixed = try readTestFile();
    defer gpa.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "theme=Nord") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "tight=true") != null);
}

test "labels from addresses" {
    try std.testing.expectEqualStrings("my-mac-rex", labelFor("https://my-mac-rex.tail0000.ts.net"));
    try std.testing.expectEqualStrings("127.0.0.1", labelFor("http://127.0.0.1:18765"));
    try std.testing.expectEqualStrings("box", labelFor("box:8765"));
    try std.testing.expectEqualStrings("This Computer", labelFor("unix:///run/user/1000/rex/server.sock"));
}
