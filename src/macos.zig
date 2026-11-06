//! The one Mac-only touch for development builds: the Dock shows Compy's icon instead of a
//! generic one. Linux desktops take the icon from the installed desktop entry instead.
const std = @import("std");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
extern fn objc_getClass(name: [*:0]const u8) Id;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;

fn send(comptime R: type, target: Id, sel: [*:0]const u8, args: anytype) R {
    const Fn = switch (args.len) {
        0 => *const fn (Id, Sel) callconv(.c) R,
        1 => *const fn (Id, Sel, @TypeOf(args[0])) callconv(.c) R,
        else => @compileError("more arguments than needed here"),
    };
    const f: Fn = @ptrCast(&objc_msgSend);
    return if (args.len == 0) f(target, sel_registerName(sel)) else f(target, sel_registerName(sel), args[0]);
}

pub fn setDockIcon(png_path: [:0]const u8) void {
    const ns_string = objc_getClass("NSString");
    const path = send(Id, ns_string, "stringWithUTF8String:", .{@as([*:0]const u8, png_path.ptr)});
    const image = send(Id, send(Id, objc_getClass("NSImage"), "alloc", .{}), "initWithContentsOfFile:", .{path});
    if (image == null) return std.log.warn("couldn't load the Dock icon from {s}", .{png_path});
    const app = send(Id, objc_getClass("NSApplication"), "sharedApplication", .{});
    send(void, app, "setApplicationIconImage:", .{image});
}
