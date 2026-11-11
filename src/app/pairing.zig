//! Pair a phone: the server's address as a QR code, for Compy on Android to scan.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const cairo = @import("cairo");
const qr = @import("../util/qr.zig");

const gpa = std.heap.c_allocator;

var shown: ?qr.Code = null;

/// For this computer's server, reached by its socket, which a phone can't use: shows the
/// server's tailnet address instead, which Rex gives once the server's Tailscale node is on.
pub fn openLocal(a: *@import("app.zig").App, socket_url: [:0]const u8) void {
    const H = struct {
        fn answered(data: ?*anyopaque, output: ?[]const u8) void {
            const app: *@import("app.zig").App = @ptrCast(@alignCast(data.?));
            // `rex server tailscale pair --json` names the address; it prints nothing on stdout
            // while Tailscale is off.
            const text = output orelse "";
            const start = std.mem.indexOf(u8, text, "\"https://") orelse
                return app.toastText("Turn on Tailscale for this server first: run rex server tailscale on, then sign in with the link it gives.");
            const rest = text[start + 1 ..];
            const url = rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse rest.len];
            open(app.window.as(gtk.Widget), url);
        }
    };
    if (!@import("../util/proc.zig").run(&.{ "rex", "--autostart=false", "-S", socket_url, "server", "tailscale", "pair", "--json" }, a, &H.answered)) a.toastText("Couldn't run rex");
}

pub fn open(parent: *gtk.Widget, url: []const u8) void {
    shown = qr.encode(url) orelse return;
    const dialog = adw.Dialog.new();
    dialog.setTitle("Pair Device");
    dialog.setContentWidth(380);
    const box = gtk.Box.new(.vertical, 14);
    box.as(gtk.Widget).setMarginTop(24);
    box.as(gtk.Widget).setMarginBottom(24);
    box.as(gtk.Widget).setMarginStart(24);
    box.as(gtk.Widget).setMarginEnd(24);
    const code = gtk.DrawingArea.new();
    code.setContentWidth(260);
    code.setContentHeight(260);
    code.setDrawFunc(&draw, null, null);
    code.as(gtk.Widget).setHalign(.center);
    box.append(code.as(gtk.Widget));
    const z = gpa.dupeSentinel(u8, url, 0) catch return;
    defer gpa.free(z);
    const label = gtk.Label.new(z.ptr);
    label.setSelectable(1);
    label.setWrap(1);
    label.as(gtk.Widget).addCssClass("monospace");
    box.append(label.as(gtk.Widget));
    const note = gtk.Label.new("In Compy on your phone, add a server and choose Scan pairing code. The phone needs to reach this address, such as over Tailscale.");
    note.setWrap(1);
    note.setJustify(.center);
    note.as(gtk.Widget).addCssClass("dim-label");
    box.append(note.as(gtk.Widget));
    dialog.setChild(box.as(gtk.Widget));
    dialog.present(parent);
}

/// The code in black on white with a quiet zone, which scanners need whatever the theme.
fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, _: ?*anyopaque) callconv(.c) void {
    const c = shown orelse return;
    const side: f64 = @floatFromInt(@min(w, h));
    const quiet = 4;
    const cells: f64 = @floatFromInt(@as(u32, c.size) + 2 * quiet);
    const unit = @floor(side / cells);
    const origin = (side - unit * cells) / 2;
    cr.setSourceRgb(1, 1, 1);
    cr.rectangle(0, 0, side, side);
    cr.fill();
    cr.setSourceRgb(0, 0, 0);
    for (0..c.size) |y| for (0..c.size) |x| if (c.modules[y][x]) {
        cr.rectangle(origin + (@as(f64, @floatFromInt(x)) + quiet) * unit, origin + (@as(f64, @floatFromInt(y)) + quiet) * unit, unit, unit);
    };
    cr.fill();
}
