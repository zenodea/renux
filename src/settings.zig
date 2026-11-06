//! Compy's settings, kept in ~/.config/compy/settings.ini. Everything here only changes this
//! app; nothing is sent to a Rex server.
const std = @import("std");
const glib = @import("glib");

const gpa = std.heap.c_allocator;

pub const ColorScheme = enum { auto, light, dark };
pub const CursorStyle = enum { program, block, bar, underline };

pub const Host = struct { label: []u8, url: []u8 };

pub const Settings = struct {
    font: []u8,
    tight: bool = false,
    show_headers: bool = true,
    color_scheme: ColorScheme = .auto,
    brand_icons: bool = true,
    cursor_style: CursorStyle = .program,
    cursor_blink: bool = true,
    alerts: bool = true,
    alert_blocked: bool = true,
    alert_error: bool = true,
    alert_done: bool = true,
    sound: bool = false,
    terminal_notifications: bool = true,
    /// Empty follows each host's theme; otherwise a built-in theme's name or `file:PATH`.
    theme: []u8,
    /// Empty uses this computer's name.
    client_label: []u8,
    hosts: std.ArrayList(Host) = .empty,
};

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
    s.alerts = boolean(kf, "alerts", true);
    s.alert_blocked = boolean(kf, "alert-blocked", true);
    s.alert_error = boolean(kf, "alert-error", true);
    s.alert_done = boolean(kf, "alert-done", true);
    s.sound = boolean(kf, "sound", false);
    s.terminal_notifications = boolean(kf, "terminal-notifications", true);

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
    }) |e| kf.setBoolean("compy", e[0], @intFromBool(e[1]));
    kf.setString("compy", "color-scheme", @tagName(s.color_scheme));
    kf.setString("compy", "cursor-style", @tagName(s.cursor_style));

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
