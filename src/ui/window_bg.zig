//! The window's background while it is see-through: one even layer of the window's color behind
//! everything, the panes included. The sidebar, the board and the gaps between panes all show
//! this one layer, so they match, and each pane lays its own over it, so a pane is frosted more
//! than the window around it, as a pane on a window.
const std = @import("std");
const gtk = @import("gtk");
const gsk = @import("gsk");
const gdk = @import("gdk");
const gobject = @import("gobject");
const graphene = @import("graphene");

/// A card's place, with the radius of its corners.
pub const Hole = struct { rect: graphene.Rect, radius: f32 };

/// The corners of floating cards, which what's cut from under them matches.
pub var floating_radius: f32 = 11;

/// Starts drawing what follows with `holes` cut out of it, until the second `pop`: the holes,
/// drawn solid, are the mask, taken inverted. The caller draws, then pops.
pub fn pushCut(sn: *gtk.Snapshot, cut: []const Hole) void {
    sn.pushMask(.inverted_alpha);
    const solid: gdk.RGBA = .{ .f_red = 1, .f_green = 1, .f_blue = 1, .f_alpha = 1 };
    for (cut) |*h| {
        var rounded: gsk.RoundedRect = undefined;
        _ = rounded.initFromRect(&h.rect, h.radius);
        sn.pushRoundedClip(&rounded);
        sn.appendColor(&solid, &h.rect);
        sn.pop();
    }
    sn.pop();
}

pub const WindowBackground = extern struct {
    parent_instance: Parent,
    /// The color itself, a plain box styled by `.window-background`, so it comes from the theme.
    fill: ?*gtk.Widget,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "RenuxWindowBackground",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const w = self.as(gtk.Widget);
        w.setLayoutManager(gtk.BinLayout.new().as(gtk.LayoutManager));
        w.setCanTarget(0);
        const fill = gtk.Box.new(.vertical, 0);
        fill.as(gtk.Widget).addCssClass("window-background");
        fill.as(gtk.Widget).setParent(w);
        self.fill = fill.as(gtk.Widget);
        return self;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn snapshot(self: *Self, sn: *gtk.Snapshot) callconv(.c) void {
        const fill = self.fill orelse return;
        self.as(gtk.Widget).snapshotChild(fill, sn);
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (self.fill) |f| f.unparent();
        self.fill = null;
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
