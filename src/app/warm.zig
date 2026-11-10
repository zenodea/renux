//! Readies the GPU's drawing programs shortly after start-up. GTK builds each one the first
//! time something needs it: a shadow, a blur, a rounded clip. On a Mac that takes tens of
//! milliseconds apiece, and they all came due in the frame a dialog first opened, which made
//! Settings and the command palette hitch on their first showing. Drawing one small sample of
//! each kind off screen, a few milliseconds at a time while nothing else is happening, builds
//! them ahead of that.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
const gsk = @import("gsk");
const gtk = @import("gtk");
const graphene = @import("graphene");

var window: ?*gtk.Window = null;
var step: usize = 0;

/// The kinds of drawing a dialog uses, each tried under the ways GTK clips: not at all, to a
/// rectangle, to a rounded one, and through a mask (as for a rounded card inside a rounded
/// dialog), alone and with a rectangle. Each pairing is a program of its own.
const kinds = 12;
const clips = 5;

/// Starts warming once the window has had time to draw its first frames.
pub fn start(win: *gtk.Window) void {
    if (window != null) return;
    window = win;
    _ = glib.timeoutAdd(700, &begin, null);
}

fn begin(_: ?*anyopaque) callconv(.c) c_int {
    _ = glib.idleAdd(&one, null);
    return 0;
}

fn box(x: f32, y: f32, w: f32, h: f32) graphene.Rect {
    return .{ .f_origin = .{ .f_x = x, .f_y = y }, .f_size = .{ .f_width = w, .f_height = h } };
}

fn ink(r: f32, g: f32, b: f32, a: f32) gdk.RGBA {
    return .{ .f_red = r, .f_green = g, .f_blue = b, .f_alpha = a };
}

/// One sample per turn of the main loop, so no turn is held up for long.
fn one(_: ?*anyopaque) callconv(.c) c_int {
    const win = window orelse return 0;
    if (step >= kinds * clips) return 0;
    const renderer = win.as(gtk.Native).getRenderer() orelse return 0;
    const kind = step / clips;
    const clip = step % clips;
    step += 1;

    const sn = gtk.Snapshot.new();
    // Every clip cuts through the sample; one that merely surrounds it is dropped by GTK and
    // would ready nothing.
    const inner = box(14.5, 12.5, 30, 31);
    var rounded: gsk.RoundedRect = undefined;
    _ = rounded.initFromRect(&inner, 9);
    var second: gsk.RoundedRect = undefined;
    _ = second.initFromRect(&box(10.5, 18.5, 30, 26), 6);
    var pushed: usize = 0;
    switch (clip) {
        0 => {},
        1 => sn.pushClip(&inner),
        2 => sn.pushRoundedClip(&rounded),
        // Two rounded clips and a rectangle make GTK clip through a mask; a further rectangle
        // inside that is the mask and a rectangle together, as for a card in a scrolling page
        // of a rounded dialog.
        else => {
            sn.pushRoundedClip(&rounded);
            sn.pushRoundedClip(&second);
            sn.pushClip(&box(16.5, 20.5, 20, 20));
            pushed = 2;
            if (clip == 4) {
                // Something drawn first, so the mask exists before the next clip arrives.
                sn.appendColor(&ink(0.2, 0.2, 0.2, 0.5), &box(8.5, 8.5, 40, 40));
                sn.pushClip(&box(19.25, 23.25, 12, 12));
                pushed = 3;
            }
        },
    }
    if (clip != 0) pushed += 1;
    sample(sn, kind, win);
    for (0..pushed) |_| sn.pop();
    const node = sn.freeToNode() orelse return 1;
    defer node.unref();
    const texture = renderer.renderTexture(node, &box(0, 0, 64, 64));
    texture.as(gobject.Object).unref();
    return 1;
}

fn sample(sn: *gtk.Snapshot, kind: usize, win: *gtk.Window) void {
    const area = box(8.5, 8.5, 40, 40);
    var shape: gsk.RoundedRect = undefined;
    _ = shape.initFromRect(&area, 7);
    const dark = ink(0.1, 0.1, 0.12, 0.8);
    const light = ink(0.9, 0.9, 0.95, 0.6);
    switch (kind) {
        0 => sn.appendColor(&dark, &area),
        1 => {
            sn.pushRoundedClip(&shape);
            sn.appendColor(&dark, &area);
            sn.pop();
        },
        2 => sn.appendBorder(&shape, &[4]f32{ 1, 1, 1, 1 }, &[4]gdk.RGBA{ light, light, light, light }),
        3 => sn.appendOutsetShadow(&shape, &dark, 0, 2, 1, 6),
        4 => sn.appendInsetShadow(&shape, &dark, 0, 1, 0, 3),
        5 => {
            const stops = [2]gsk.ColorStop{ .{ .f_offset = 0, .f_color = dark }, .{ .f_offset = 1, .f_color = light } };
            sn.appendLinearGradient(&area, &.{ .f_x = 8, .f_y = 8 }, &.{ .f_x = 48, .f_y = 48 }, &stops, stops.len);
        },
        6 => {
            // Two things drawn together at less than full strength, and smaller, as a dialog
            // is while it opens.
            sn.scale(0.96, 0.96);
            sn.pushOpacity(0.5);
            sn.appendColor(&dark, &area);
            sn.appendColor(&light, &box(20.5, 20.5, 30, 30));
            sn.pop();
        },
        7 => {
            sn.pushBlur(4);
            sn.appendColor(&dark, &area);
            sn.appendColor(&light, &box(20.5, 20.5, 30, 30));
            sn.pop();
        },
        8 => {
            sn.pushMask(.alpha);
            sn.appendColor(&dark, &box(12, 12, 20, 20));
            sn.pop();
            sn.appendColor(&light, &area);
            sn.pop();
        },
        9 => {
            sn.pushCrossFade(0.5);
            sn.appendColor(&dark, &area);
            sn.pop();
            sn.appendColor(&light, &box(20.5, 20.5, 30, 30));
            sn.pop();
        },
        10 => {
            const layout = win.as(gtk.Widget).createPangoLayout("Settings");
            defer layout.as(gobject.Object).unref();
            sn.translate(&.{ .f_x = 6, .f_y = 20 });
            sn.appendLayout(layout, &light);
        },
        else => {
            const cr = sn.appendCairo(&area);
            defer cr.destroy();
            cr.setSourceRgba(0.5, 0.5, 0.9, 0.7);
            cr.rectangle(10, 10, 30, 30);
            cr.fill();
        },
    }
}
