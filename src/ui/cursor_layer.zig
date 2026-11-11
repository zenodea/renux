//! The window's one cursor, as the cursor shader draws it: a layer over every pane that follows
//! the cursor of the pane with the keyboard. When the keyboard moves to another pane, the cursor
//! moves with it, so a trail or a smear runs from one pane to the next as from one line to the
//! next. Only the region around the cursor is drawn.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const gobject = @import("gobject");
const graphene = @import("graphene");
const shader = @import("../terminal/shader.zig");
const TermView = @import("../terminal/termview.zig").TermView;

/// The pane whose cursor is the window's: the one with the keyboard, or null when no pane is
/// showing, as while the board is open.
pub var current: ?*const fn () ?*TermView = null;

/// What the cursor shader was last told, and the tick that redraws it while it moves.
var state: shader.Pane = .{};
var tick: c_uint = 0;

pub const CursorLayer = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "RenuxCursorLayer",
        .classInit = &Class.init,
    });

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.as(gtk.Widget).setCanTarget(0);
        return self;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn snapshot(self: *Self, sn: *gtk.Snapshot) callconv(.c) void {
        if (!shader.cursor.active()) return;
        const tv = (current orelse return)() orelse return;
        const canvas = tv.widget();
        const w = self.as(gtk.Widget);
        if (canvas.getMapped() == 0) return;
        // The pane's cursor box, moved into this layer's points.
        var look = tv.shader_look;
        var at: graphene.Point = undefined;
        if (canvas.computePoint(w, &.{ .f_x = look.cursor[0], .f_y = look.cursor[1] }, &at) == 0) return;
        look.cursor[0] = at.f_x;
        look.cursor[1] = at.f_y;
        const native = w.getNative() orelse return;
        const scale: f32 = if (native.getSurface()) |s| @floatCast(s.getScale()) else 1;
        shader.drawCursor(&state, @floatFromInt(w.getWidth()), @floatFromInt(w.getHeight()), scale, &look, sn);
        if (tick == 0 and shader.cursor.wantsFrames(&state)) tick = w.addTickCallback(&ticked, null, null);
    }

    fn ticked(widget: *gtk.Widget, _: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
        widget.queueDraw();
        if (shader.cursor.wantsFrames(&state)) return 1;
        // One more frame, so a fading effect doesn't stay half done.
        tick = 0;
        return 0;
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
