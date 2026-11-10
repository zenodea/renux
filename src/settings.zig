//! Compy's settings, kept in ~/.config/compy/settings.ini. Everything here only changes this
//! app; nothing is sent to a Rex server.
const std = @import("std");
const glib = @import("glib");

const gpa = std.heap.c_allocator;

pub const ColorScheme = enum { auto, light, dark };
pub const CursorStyle = enum { program, block, bar, underline };
/// Where a session's windows show as tabs: in the sidebar on the left or right, or above the panes.
pub const TabPosition = enum { left, right, above };
pub const BoldItalic = enum { fonts, plain };
pub const PaddingColor = enum { terminal, theme };

pub const Host = struct { label: []u8, url: []u8 };

/// A key sequence set in Compy for an action, over the config's own. Empty keys unbind it.
pub const Shortcut = struct { keys: []u8, action: []u8, args: []u8 };

pub const Settings = struct {
    font: []u8,
    tight: bool = false,
    show_headers: bool = true,
    color_scheme: ColorScheme = .auto,
    brand_icons: bool = true,
    cursor_style: CursorStyle = .program,
    cursor_blink: bool = true,
    /// The bar cursor's width in pixels.
    cursor_width: f64 = 2,
    /// Row height as a multiple of the font's own line height.
    line_height: f64 = 1,
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
    /// After a prefix such as ctrl+a, list the keys that can follow.
    key_hints: bool = true,
    /// Pointing at a pane gives it the keyboard.
    focus_follows_mouse: bool = false,
    /// How much panes without the keyboard fade, 0 to 0.6.
    fade_inactive: f64 = 0,
    /// Fade every pane while Compy isn't the active window.
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
    hosts: std.ArrayList(Host) = .empty,
    /// Folders panes were in lately, newest first, for Go to Anything.
    recent_paths: std.ArrayList([]u8) = .empty,
    recent_paths_shown: bool = true,
    shortcuts: std.ArrayList(Shortcut) = .empty,
};

/// Sets (or, with `keys` null, removes) Compy's own shortcut for an action and its arguments.
pub fn setShortcut(action: []const u8, args: []const u8, keys: ?[]const u8) void {
    const list = &current.shortcuts;
    for (list.items, 0..) |sc, i| if (std.mem.eql(u8, sc.action, action) and std.mem.eql(u8, sc.args, args)) {
        gpa.free(sc.keys);
        gpa.free(sc.action);
        gpa.free(sc.args);
        _ = list.orderedRemove(i);
        break;
    };
    if (keys) |k| list.append(gpa, .{
        .keys = gpa.dupe(u8, k) catch return,
        .action = gpa.dupe(u8, action) catch return,
        .args = gpa.dupe(u8, args) catch return,
    }) catch {};
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

fn dir() ?[:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/compy", .{std.mem.span(glib.getUserConfigDir())}, 0) catch null;
}

fn file() ?[:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/compy/settings.ini", .{std.mem.span(glib.getUserConfigDir())}, 0) catch null;
}

fn str(kf: *glib.KeyFile, key: [*:0]const u8, default: []const u8) []u8 {
    const v = kf.getString("compy", key, null) orelse return gpa.dupe(u8, default) catch unreachable;
    defer glib.free(v);
    return gpa.dupe(u8, std.mem.span(v)) catch unreachable;
}

fn boolean(kf: *glib.KeyFile, key: [*:0]const u8, default: bool) bool {
    var err: ?*glib.Error = null;
    const v = kf.getBoolean("compy", key, &err);
    if (err) |e| {
        e.free();
        return default;
    }
    return v != 0;
}

fn number(kf: *glib.KeyFile, key: [*:0]const u8, default: f64, min: f64, max: f64) f64 {
    var err: ?*glib.Error = null;
    const v = kf.getDouble("compy", key, &err);
    if (err) |e| {
        e.free();
        return default;
    }
    return if (std.math.isFinite(v)) std.math.clamp(v, min, max) else default;
}

fn enumOf(comptime E: type, kf: *glib.KeyFile, key: [*:0]const u8, default: E) E {
    const v = str(kf, key, @tagName(default));
    defer gpa.free(v);
    return std.meta.stringToEnum(E, v) orelse default;
}

pub fn load() void {
    const kf = glib.KeyFile.new();
    defer kf.unref();
    if (file()) |f| {
        defer gpa.free(f);
        _ = kf.loadFromFile(f.ptr, .{}, null);
    }
    current = .{
        .font = str(kf, "font", "Monospace 11"),
        .theme = str(kf, "theme", ""),
        .client_label = str(kf, "client-label", ""),
    };
    const s = &current;
    s.tight = boolean(kf, "tight", false);
    s.show_headers = boolean(kf, "show-headers", true);
    s.color_scheme = enumOf(ColorScheme, kf, "color-scheme", .auto);
    s.brand_icons = boolean(kf, "brand-icons", true);
    s.cursor_style = enumOf(CursorStyle, kf, "cursor-style", .program);
    s.cursor_blink = boolean(kf, "cursor-blink", true);
    s.cursor_width = number(kf, "cursor-width", 2, 1, 6);
    s.line_height = number(kf, "line-height", 1, 0.8, 2);
    s.letter_spacing = number(kf, "letter-spacing", 0, -2, 6);
    s.window_opacity = number(kf, "window-opacity", 1, 0.2, 1);
    s.terminal_opacity = number(kf, "terminal-opacity", 1, 0.2, 1);
    s.blur = boolean(kf, "blur", true);
    s.sidebar_width = number(kf, "sidebar-width", 250, 180, 480);
    s.key_hints = boolean(kf, "key-hints", true);
    s.focus_follows_mouse = boolean(kf, "focus-follows-mouse", false);
    s.fade_inactive = number(kf, "fade-inactive", 0, 0, 0.6);
    s.fade_inactive_window = boolean(kf, "fade-inactive-window", false);
    s.highlight_border = boolean(kf, "highlight-border", true);
    s.highlight_opacity = number(kf, "highlight-opacity", 0.85, 0.1, 1);
    s.highlight_animate = boolean(kf, "highlight-animate", true);
    s.highlight_color = @intFromFloat(number(kf, "highlight-color", 0, 0, 0xffffff));
    s.autobalance = boolean(kf, "autobalance", false);
    s.match_program_bg = boolean(kf, "match-program-bg", false);
    s.rounded_selection = boolean(kf, "rounded-selection", true);
    s.ligatures = boolean(kf, "ligatures", true);
    s.font_smoothing = boolean(kf, "font-smoothing", true);
    s.bold_italic = enumOf(BoldItalic, kf, "bold-italic", .fonts);
    s.cursor_blink_ms = number(kf, "cursor-blink-ms", 530, 200, 2000);
    s.cursor_text_color = @intFromFloat(number(kf, "cursor-text-color", 0, 0, 0xffffff));
    s.selection_bg = @intFromFloat(number(kf, "selection-bg", 0, 0, 0xffffff));
    s.selection_fg = @intFromFloat(number(kf, "selection-fg", 0, 0, 0xffffff));
    s.pad_x = number(kf, "padding-x", 8, 0, 40);
    s.pad_y = number(kf, "padding-y", 8, 0, 40);
    s.padding_color = enumOf(PaddingColor, kf, "padding-color", .terminal);
    s.extended_palette = boolean(kf, "extended-palette", false);
    s.copy_animation = boolean(kf, "copy-animation", true);
    {
        var n: usize = 0;
        if (kf.getStringList("links", "trusted", &n, null)) |list| {
            defer glib.strfreev(@ptrCast(list));
            for (0..n) |i| if (std.mem.span(list[i])) |t| {
                s.trusted_schemes.append(gpa, gpa.dupe(u8, t) catch continue) catch {};
            };
        }
    }
    s.tab_position = enumOf(TabPosition, kf, "tab-position", .left);
    s.tab_fill = boolean(kf, "tab-fill", true);
    s.tab_processes = boolean(kf, "tab-processes", false);
    s.alerts = boolean(kf, "alerts", true);
    s.alert_blocked = boolean(kf, "alert-blocked", true);
    s.alert_error = boolean(kf, "alert-error", true);
    s.alert_done = boolean(kf, "alert-done", true);
    s.sound = boolean(kf, "sound", false);
    s.terminal_notifications = boolean(kf, "terminal-notifications", true);
    s.improve_contrast = boolean(kf, "improve-contrast", true);
    s.visual_bell = boolean(kf, "visual-bell", true);
    s.paste_warning = boolean(kf, "paste-warning", true);
    s.copy_on_select = boolean(kf, "copy-on-select", true);
    s.recent_paths_shown = boolean(kf, "recent-paths", true);
    {
        // Each one is "keys<TAB>action<TAB>args".
        var n: usize = 0;
        if (kf.getStringList("shortcuts", "bindings", &n, null)) |list| {
            defer glib.strfreev(@ptrCast(list));
            for (0..n) |i| if (std.mem.span(list[i])) |line| {
                var parts = std.mem.splitScalar(u8, line, '\t');
                const k = parts.next() orelse continue;
                const act = parts.next() orelse continue;
                const args = parts.next() orelse "";
                s.shortcuts.append(gpa, .{ .keys = gpa.dupe(u8, k) catch continue, .action = gpa.dupe(u8, act) catch continue, .args = gpa.dupe(u8, args) catch continue }) catch {};
            };
        }
    }
    {
        var n: usize = 0;
        if (kf.getStringList("paths", "recent", &n, null)) |list| {
            defer glib.strfreev(@ptrCast(list));
            for (0..n) |i| if (std.mem.span(list[i])) |p| {
                s.recent_paths.append(gpa, gpa.dupe(u8, p) catch continue) catch {};
            };
        }
    }

    // Hosts are stored as matching lists of labels and addresses.
    var n_labels: usize = 0;
    var n_urls: usize = 0;
    const labels = kf.getStringList("hosts", "labels", &n_labels, null);
    const urls = kf.getStringList("hosts", "urls", &n_urls, null);
    if (labels != null and urls != null) {
        for (0..@min(n_labels, n_urls)) |i| {
            const l = std.mem.span(labels.?[i]) orelse continue;
            const u = std.mem.span(urls.?[i]) orelse continue;
            addHostNoSave(l, u);
        }
    }
    if (labels) |l| glib.strfreev(@ptrCast(l));
    if (urls) |u| glib.strfreev(@ptrCast(u));
    migrateOldServer();
}

/// The first version kept one server address in ~/.config/compy/server.
fn migrateOldServer() void {
    if (current.hosts.items.len > 0) return;
    const old = std.fmt.allocPrintSentinel(gpa, "{s}/compy/server", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return;
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
    save();
}

pub fn removeHost(index: usize) void {
    if (index >= current.hosts.items.len) return;
    const h = current.hosts.orderedRemove(index);
    gpa.free(h.label);
    gpa.free(h.url);
    save();
}

pub fn setString(slot: *[]u8, value: []const u8) void {
    const copy = gpa.dupe(u8, value) catch return;
    gpa.free(slot.*);
    slot.* = copy;
    save();
}

pub fn save() void {
    const kf = glib.KeyFile.new();
    defer kf.unref();
    const s = &current;
    inline for (.{ .{ "font", s.font }, .{ "theme", s.theme }, .{ "client-label", s.client_label } }) |e| {
        const z = gpa.dupeSentinel(u8, e[1], 0) catch return;
        defer gpa.free(z);
        kf.setString("compy", e[0], z.ptr);
    }
    inline for (.{
        .{ "tight", s.tight },                 .{ "show-headers", s.show_headers },
        .{ "brand-icons", s.brand_icons },     .{ "cursor-blink", s.cursor_blink },
        .{ "alerts", s.alerts },               .{ "alert-blocked", s.alert_blocked },
        .{ "alert-error", s.alert_error },     .{ "alert-done", s.alert_done },
        .{ "sound", s.sound },                 .{ "terminal-notifications", s.terminal_notifications },
        .{ "improve-contrast", s.improve_contrast }, .{ "visual-bell", s.visual_bell },
        .{ "paste-warning", s.paste_warning }, .{ "copy-on-select", s.copy_on_select },
        .{ "key-hints", s.key_hints },         .{ "focus-follows-mouse", s.focus_follows_mouse },
        .{ "fade-inactive-window", s.fade_inactive_window }, .{ "highlight-border", s.highlight_border },
        .{ "highlight-animate", s.highlight_animate }, .{ "autobalance", s.autobalance },
        .{ "match-program-bg", s.match_program_bg }, .{ "rounded-selection", s.rounded_selection },
        .{ "ligatures", s.ligatures },         .{ "font-smoothing", s.font_smoothing },
        .{ "extended-palette", s.extended_palette }, .{ "copy-animation", s.copy_animation },         .{ "recent-paths", s.recent_paths_shown },         .{ "tab-fill", s.tab_fill },
        .{ "tab-processes", s.tab_processes },
    }) |e| kf.setBoolean("compy", e[0], @intFromBool(e[1]));
    kf.setString("compy", "color-scheme", @tagName(s.color_scheme));
    kf.setString("compy", "cursor-style", @tagName(s.cursor_style));
    kf.setString("compy", "tab-position", @tagName(s.tab_position));
    kf.setDouble("compy", "cursor-width", s.cursor_width);
    kf.setDouble("compy", "line-height", s.line_height);
    kf.setDouble("compy", "letter-spacing", s.letter_spacing);
    kf.setDouble("compy", "window-opacity", s.window_opacity);
    kf.setDouble("compy", "terminal-opacity", s.terminal_opacity);
    kf.setBoolean("compy", "blur", @intFromBool(s.blur));
    kf.setDouble("compy", "sidebar-width", s.sidebar_width);
    kf.setDouble("compy", "fade-inactive", s.fade_inactive);
    kf.setDouble("compy", "highlight-opacity", s.highlight_opacity);
    kf.setDouble("compy", "highlight-color", @floatFromInt(s.highlight_color));
    kf.setDouble("compy", "cursor-blink-ms", s.cursor_blink_ms);
    kf.setDouble("compy", "cursor-text-color", @floatFromInt(s.cursor_text_color));
    kf.setDouble("compy", "selection-bg", @floatFromInt(s.selection_bg));
    kf.setDouble("compy", "selection-fg", @floatFromInt(s.selection_fg));
    kf.setDouble("compy", "padding-x", s.pad_x);
    kf.setDouble("compy", "padding-y", s.pad_y);
    kf.setString("compy", "bold-italic", @tagName(s.bold_italic));
    kf.setString("compy", "padding-color", @tagName(s.padding_color));

    var labels: std.ArrayList(?[*:0]const u8) = .empty;
    var urls: std.ArrayList(?[*:0]const u8) = .empty;
    var owned: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned.items) |o| gpa.free(o);
        owned.deinit(gpa);
        labels.deinit(gpa);
        urls.deinit(gpa);
    }
    for (s.hosts.items) |h| {
        const l = gpa.dupeSentinel(u8, h.label, 0) catch return;
        const u = gpa.dupeSentinel(u8, h.url, 0) catch return;
        owned.append(gpa, l) catch return;
        owned.append(gpa, u) catch return;
        labels.append(gpa, l.ptr) catch return;
        urls.append(gpa, u.ptr) catch return;
    }
    kf.setStringList("hosts", "labels", @ptrCast(labels.items.ptr), labels.items.len);
    kf.setStringList("hosts", "urls", @ptrCast(urls.items.ptr), urls.items.len);

    var recent: std.ArrayList(?[*:0]const u8) = .empty;
    defer recent.deinit(gpa);
    for (s.recent_paths.items) |p| {
        const z = gpa.dupeSentinel(u8, p, 0) catch return;
        owned.append(gpa, z) catch return;
        recent.append(gpa, z.ptr) catch return;
    }
    kf.setStringList("paths", "recent", @ptrCast(recent.items.ptr), recent.items.len);
    var trusted: std.ArrayList(?[*:0]const u8) = .empty;
    defer trusted.deinit(gpa);
    for (s.trusted_schemes.items) |t| {
        const z = gpa.dupeSentinel(u8, t, 0) catch return;
        owned.append(gpa, z) catch return;
        trusted.append(gpa, z.ptr) catch return;
    }
    kf.setStringList("links", "trusted", @ptrCast(trusted.items.ptr), trusted.items.len);
    var shortcut_lines: std.ArrayList(?[*:0]const u8) = .empty;
    defer shortcut_lines.deinit(gpa);
    for (s.shortcuts.items) |sc| {
        const z = std.fmt.allocPrintSentinel(gpa, "{s}\t{s}\t{s}", .{ sc.keys, sc.action, sc.args }, 0) catch return;
        owned.append(gpa, z) catch return;
        shortcut_lines.append(gpa, z.ptr) catch return;
    }
    kf.setStringList("shortcuts", "bindings", @ptrCast(shortcut_lines.items.ptr), shortcut_lines.items.len);

    const d = dir() orelse return;
    defer gpa.free(d);
    _ = glib.mkdirWithParents(d.ptr, 0o700);
    const f = file() orelse return;
    defer gpa.free(f);
    _ = kf.saveToFile(f.ptr, null);
}

test "labels from addresses" {
    try std.testing.expectEqualStrings("my-mac-rex", labelFor("https://my-mac-rex.tail0000.ts.net"));
    try std.testing.expectEqualStrings("127.0.0.1", labelFor("http://127.0.0.1:18765"));
    try std.testing.expectEqualStrings("box", labelFor("box:8765"));
}
