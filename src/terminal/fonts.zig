//! The Nerd Font symbols that come with Renux, so prompt and file icons show whatever font the
//! person picks. The font is registered for this process only; nothing is installed.
const std = @import("std");
const builtin = @import("builtin");
const glib = @import("glib");

/// The family name the bundled font registers, added after the chosen font as a fallback.
pub const symbols_family = "Symbols Nerd Font Mono";
pub var registered = false;

const file_name = "SymbolsNerdFontMono-Regular.ttf";

/// Registers the bundled font, found next to the app in PREFIX/share/renux/fonts. It must run
/// before Pango first lists fonts.
pub fn registerBundled() void {
    var exe_buf: [4096]u8 = undefined;
    const n = std.process.executableDirPath(@import("../main.zig").io, &exe_buf) catch return;
    var path_buf: [4200]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/../share/renux/fonts/{s}", .{ exe_buf[0..n], file_name }, 0) catch return;
    if (glib.fileTest(path.ptr, .{ .exists = true }) == 0) return;
    registered = if (builtin.os.tag == .macos) registerMac(path) else registerFontconfig(path);
    if (!registered) std.log.warn("couldn't register the Nerd Font symbols at {s}", .{path});
}

extern "c" fn FcConfigAppFontAddFile(config: ?*anyopaque, file: [*:0]const u8) c_int;

fn registerFontconfig(path: [:0]const u8) bool {
    if (builtin.os.tag == .macos) return false;
    return FcConfigAppFontAddFile(null, path.ptr) != 0;
}

extern "c" fn CFURLCreateFromFileSystemRepresentation(allocator: ?*anyopaque, buffer: [*]const u8, length: isize, is_directory: u8) ?*anyopaque;
extern "c" fn CTFontManagerRegisterFontsForURL(url: *anyopaque, scope: u32, err: ?*?*anyopaque) u8;
extern "c" fn CFRelease(object: ?*anyopaque) void;

fn registerMac(path: [:0]const u8) bool {
    if (builtin.os.tag != .macos) return false;
    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return false;
    defer CFRelease(url);
    // 1 is kCTFontManagerScopeProcess.
    return CTFontManagerRegisterFontsForURL(url, 1, null) != 0;
}
