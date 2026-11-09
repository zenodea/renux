//! The Mac-only touches for development builds: the Dock shows Compy's icon, and the window can
//! be frosted glass behind see-through panes. Linux desktops take the icon from the desktop
//! entry and blur see-through windows themselves.
const std = @import("std");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
extern fn objc_getClass(name: [*:0]const u8) Id;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;
extern fn gdk_macos_surface_get_native_window(surface: *anyopaque) Id;

const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };

fn send(comptime R: type, target: Id, sel: [*:0]const u8, args: anytype) R {
    const s = sel_registerName(sel);
    switch (args.len) {
        0 => {
            const f: *const fn (Id, Sel) callconv(.c) R = @ptrCast(&objc_msgSend);
            return f(target, s);
        },
        1 => {
            const f: *const fn (Id, Sel, @TypeOf(args[0])) callconv(.c) R = @ptrCast(&objc_msgSend);
            return f(target, s, args[0]);
        },
        3 => {
            const f: *const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) R = @ptrCast(&objc_msgSend);
            return f(target, s, args[0], args[1], args[2]);
        },
        else => @compileError("unsupported argument count"),
    }
}

pub fn setDockIcon(png_path: [:0]const u8) void {
    const ns_string = objc_getClass("NSString");
    const path = send(Id, ns_string, "stringWithUTF8String:", .{@as([*:0]const u8, png_path.ptr)});
    const image = send(Id, send(Id, objc_getClass("NSImage"), "alloc", .{}), "initWithContentsOfFile:", .{path});
    if (image == null) return std.log.warn("couldn't load the Dock icon from {s}", .{png_path});
    const app = send(Id, objc_getClass("NSApplication"), "sharedApplication", .{});
    send(void, app, "setApplicationIconImage:", .{image});
}

var effect: Id = null;

/// Puts the system's frosted glass behind the window's content, or takes it away. `surface` is
/// the window's GdkSurface; `radius` matches the window's rounded corners.
pub fn setBlur(surface: *anyopaque, on: bool, radius: f64) void {
    const window = gdk_macos_surface_get_native_window(surface) orelse return;
    if (effect == null) {
        if (!on) return;
        const content = send(Id, window, "contentView", .{});
        const frame_view = send(Id, content, "superview", .{}) orelse return;
        const bounds = send(Rect, content, "bounds", .{});
        const v = send(Id, send(Id, objc_getClass("NSVisualEffectView"), "alloc", .{}), "initWithFrame:", .{bounds}) orelse return;
        send(void, v, "setBlendingMode:", .{@as(isize, 0)}); // behind the window
        send(void, v, "setMaterial:", .{@as(isize, 21)}); // under the window background
        send(void, v, "setState:", .{@as(isize, 1)}); // always active
        send(void, v, "setAutoresizingMask:", .{@as(usize, 2 | 16)}); // follows width and height
        send(void, v, "setWantsLayer:", .{true});
        const layer = send(Id, v, "layer", .{});
        send(void, layer, "setCornerRadius:", .{radius});
        send(void, layer, "setMasksToBounds:", .{true});
        send(void, frame_view, "addSubview:positioned:relativeTo:", .{ v, @as(isize, -1), content });
        send(void, window, "setOpaque:", .{false});
        send(void, window, "setBackgroundColor:", .{send(Id, objc_getClass("NSColor"), "clearColor", .{})});
        effect = v;
    }
    send(void, effect, "setHidden:", .{!on});
}
