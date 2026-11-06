//! Settings kept between runs, in ~/.config/compy. $COMPY_SERVER and $COMPY_FONT override them,
//! which helps when testing.
const std = @import("std");
const glib = @import("glib");

const gpa = std.heap.c_allocator;

fn path(name: []const u8) ?[:0]u8 {
    const dir = std.mem.span(glib.getUserConfigDir());
    return std.fmt.allocPrintSentinel(gpa, "{s}/compy/{s}", .{ dir, name }, 0) catch null;
}

/// The saved server address, owned by the caller, or null when none is saved.
pub fn serverUrl() ?[]u8 {
    if (std.c.getenv("COMPY_SERVER")) |env| return gpa.dupe(u8, std.mem.span(env)) catch null;
    const p = path("server") orelse return null;
    defer gpa.free(p);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(p.ptr, &contents, &len, null) == 0) return null;
    defer glib.free(contents);
    const text = std.mem.trim(u8, contents[0..len], " \n\r\t");
    if (text.len == 0) return null;
    return gpa.dupe(u8, text) catch null;
}

pub fn saveServerUrl(url: []const u8) void {
    const dir = std.fmt.allocPrintSentinel(gpa, "{s}/compy", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return;
    defer gpa.free(dir);
    _ = glib.mkdirWithParents(dir.ptr, 0o700);
    const p = path("server") orelse return;
    defer gpa.free(p);
    _ = glib.fileSetContents(p.ptr, url.ptr, @intCast(url.len), null);
}

pub fn fontName() [:0]const u8 {
    if (std.c.getenv("COMPY_FONT")) |f| return std.mem.span(f);
    return "Monospace 11";
}

/// Small on/off settings live in their own files under ~/.config/compy.
fn flag(name: []const u8) bool {
    const p = path(name) orelse return false;
    defer gpa.free(p);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(p.ptr, &contents, &len, null) == 0) return false;
    defer glib.free(contents);
    return std.mem.startsWith(u8, std.mem.trim(u8, contents[0..len], " \n"), "1");
}

fn saveFlag(name: []const u8, on: bool) void {
    const dir = std.fmt.allocPrintSentinel(gpa, "{s}/compy", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return;
    defer gpa.free(dir);
    _ = glib.mkdirWithParents(dir.ptr, 0o700);
    const p = path(name) orelse return;
    defer gpa.free(p);
    _ = glib.fileSetContents(p.ptr, if (on) "1" else "0", 1, null);
}

pub fn tight() bool {
    return flag("tight");
}

pub fn saveTight(on: bool) void {
    saveFlag("tight", on);
}
