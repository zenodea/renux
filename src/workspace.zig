//! The panes of one Rex window, tiled the way the server lays them out. Panes keep their
//! terminal views across layout changes, so a split or a resize doesn't reconnect anything.
const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");
const view = @import("view.zig");
const Server = @import("server.zig").Server;
const TermView = @import("termview.zig").TermView;
const icons = @import("icons.zig");
const blockicon = @import("blockicon.zig");
const glib = @import("glib");

const gpa = std.heap.c_allocator;

/// Space between pane cards.
pub var gap: f64 = 8;

const Pane = struct {
    block_id: []u8,
    /// The pane's card: its title row above the terminal.
    frame: *gtk.Widget,
    tile: *gtk.Widget,
    floating: bool = false,
    term: *TermView,
    rect: view.Rect = .{},
    seen: bool = false,
};

pub const Workspace = struct {
    root: *gtk.Widget,
    server: *Server,
    session_id: ?[]u8 = null,
    window_id: ?[]u8 = null,
    focused: ?[]u8 = null,
    panes: std.ArrayList(Pane) = .empty,

    pub fn create(server: *Server) !*Workspace {
        const ws = try gpa.create(Workspace);
        const box = gtk.Box.new(.horizontal, 0);
        const root = box.as(gtk.Widget);
        root.setHexpand(1);
        root.setVexpand(1);
        root.addCssClass("workspace");
        const layout = gtk.CustomLayout.new(null, &measure, &allocate);
        root.setLayoutManager(layout.as(gtk.LayoutManager));
        ws.* = .{ .root = root, .server = server };
        gobject.Object.setData(root.as(gobject.Object), "compy-workspace", ws);
        return ws;
    }

    /// Shows a window, or nothing when `window` is null.
    pub fn show(ws: *Workspace, session_id: []const u8, window: ?*const view.Window) void {
        const same_session = if (ws.session_id) |s| std.mem.eql(u8, s, session_id) else false;
        if (!same_session) {
            ws.clear();
            replace(&ws.session_id, session_id);
        }
        const w = window orelse return ws.clear();
        replace(&ws.window_id, w.id);
        if (w.focused_block_id) |f| replace(&ws.focused, f);

        for (ws.panes.items) |*p| p.seen = false;
        if (w.zoomed_block_id) |z| {
            ws.place(session_id, z, .{});
        } else if (w.tiled()) |layer| {
            if (layer.layout) |node| ws.placeNode(session_id, node);
        }
        // Floating layers sit over the tiles, at their bounds.
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating or layer.minimized) continue;
            if (layer.layout) |node| ws.placeNodeIn(session_id, node, layer.bounds);
        };

        var i: usize = 0;
        while (i < ws.panes.items.len) {
            if (!ws.panes.items[i].seen) {
                const p = ws.panes.orderedRemove(i);
                ws.drop(p);
            } else i += 1;
        }
        ws.markFocus();
        ws.root.queueAllocate();
    }

    pub fn clear(ws: *Workspace) void {
        for (ws.panes.items) |p| ws.drop(p);
        ws.panes.clearRetainingCapacity();
    }

    fn drop(ws: *Workspace, p: Pane) void {
        p.frame.unparent();
        ws.server.releaseTerminal(p.block_id);
        gpa.free(p.block_id);
    }

    fn placeNode(ws: *Workspace, session_id: []const u8, node: *const view.Node) void {
        switch (node.*) {
            .leaf => |l| ws.place(session_id, l.block_id, l.rect),
            .split => |s| {
                ws.placeNode(session_id, s.before);
                ws.placeNode(session_id, s.after);
            },
        }
    }

    /// Places a floating layer's panes inside its bounds.
    fn placeNodeIn(ws: *Workspace, session_id: []const u8, node: *const view.Node, bounds: view.Rect) void {
        switch (node.*) {
            .leaf => |l| ws.placeAs(session_id, l.block_id, .{
                .x = bounds.x + l.rect.x * bounds.w,
                .y = bounds.y + l.rect.y * bounds.h,
                .w = l.rect.w * bounds.w,
                .h = l.rect.h * bounds.h,
            }, true),
            .split => |s| {
                ws.placeNodeIn(session_id, s.before, bounds);
                ws.placeNodeIn(session_id, s.after, bounds);
            },
        }
    }

    fn place(ws: *Workspace, session_id: []const u8, block_id: []const u8, rect: view.Rect) void {
        ws.placeAs(session_id, block_id, rect, false);
    }

    fn placeAs(ws: *Workspace, session_id: []const u8, block_id: []const u8, rect: view.Rect, floating: bool) void {
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) {
            p.rect = rect;
            p.seen = true;
            if (p.floating != floating) {
                p.floating = floating;
                if (floating) p.frame.addCssClass("floating") else p.frame.removeCssClass("floating");
            }
            return;
        };
        const tv = TermView.create(ws.server, session_id, block_id) catch return;
        tv.on_focus = .{ .ctx = ws, .f = clicked };

        // The title row: the program's icon and title, then this pane's buttons.
        const row = gtk.Box.new(.horizontal, 2);
        row.as(gtk.Widget).addCssClass("pane-title");
        const tile = blockicon.create(ws.server, block_id, 16);
        row.append(tile);
        const label = gtk.Label.new(null);
        label.as(gtk.Widget).addCssClass("title");
        label.setEllipsize(.end);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).setMarginStart(6);
        row.append(label.as(gtk.Widget));
        const tools = gtk.Box.new(.horizontal, 0);
        tools.as(gtk.Widget).addCssClass("pane-tools");
        inline for (.{
            .{ icons.Kind.split_right, "Split right", "app.pane-split-right" },
            .{ icons.Kind.split_down, "Split down", "app.pane-split-down" },
            .{ icons.Kind.zoom, "Zoom", "app.pane-zoom" },
            .{ icons.Kind.close, "Close pane", "app.pane-close" },
        }) |b| {
            const button = icons.button(b[0], b[1], b[2]);
            const target = gpa.dupeSentinel(u8, block_id, 0) catch return;
            defer gpa.free(target);
            button.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(target.ptr));
            tools.append(button.as(gtk.Widget));
        }
        row.append(tools.as(gtk.Widget));
        const handle = gtk.WindowHandle.new();
        handle.setChild(row.as(gtk.Widget));

        const card = gtk.Box.new(.vertical, 0);
        const frame = card.as(gtk.Widget);
        frame.addCssClass("pane-card");
        if (floating) frame.addCssClass("floating");
        frame.setOverflow(.hidden);
        card.append(handle.as(gtk.Widget));
        card.append(tv.widget());
        tv.setTitleLabel(label);
        frame.setParent(ws.root);
        ws.panes.append(gpa, .{
            .block_id = gpa.dupe(u8, block_id) catch return,
            .frame = frame,
            .tile = tile,
            .term = tv,
            .rect = rect,
            .floating = floating,
            .seen = true,
        }) catch {};
    }

    fn clicked(ctx: *anyopaque, block_id: []const u8) void {
        const ws: *Workspace = @ptrCast(@alignCast(ctx));
        ws.server.clearAttention(block_id);
        replace(&ws.focused, block_id);
        ws.markFocus();
        if (ws.session_id) |s| ws.server.focusBlock(s, block_id);
    }

    fn markFocus(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            const on = if (ws.focused) |f| std.mem.eql(u8, f, p.block_id) else false;
            if (on) p.frame.addCssClass("focused") else p.frame.removeCssClass("focused");
        }
    }

    /// Gives the keyboard to the focused pane.
    pub fn grabFocus(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            if (ws.focused) |f| if (std.mem.eql(u8, f, p.block_id)) {
                _ = p.term.widget().grabFocus();
                return;
            };
        }
        if (ws.panes.items.len > 0) _ = ws.panes.items[0].term.widget().grabFocus();
    }

    /// Marks a pane focused here and on the server, such as before acting on it.
    pub fn focus(ws: *Workspace, block_id: []const u8) void {
        clicked(ws, block_id);
    }

    /// The focused pane's terminal view.
    pub fn focusedView(ws: *Workspace) ?*TermView {
        for (ws.panes.items) |p| if (ws.focused) |f| if (std.mem.eql(u8, f, p.block_id)) return p.term;
        return if (ws.panes.items.len > 0) ws.panes.items[0].term else null;
    }

    /// The pane with the keyboard, or the one the server says is focused.
    pub fn focusedBlock(ws: *Workspace) ?[]const u8 {
        return ws.focused;
    }

    /// A block's details changed: redraw its tile and title.
    pub fn blockChanged(ws: *Workspace, block_id: []const u8) void {
        for (ws.panes.items) |p| if (std.mem.eql(u8, p.block_id, block_id)) {
            p.tile.queueDraw();
            p.term.updateTitle();
        };
    }

    pub fn isShown(ws: *Workspace, block_id: []const u8) bool {
        for (ws.panes.items) |p| if (std.mem.eql(u8, p.block_id, block_id)) return true;
        return false;
    }

    /// After reconnecting, sizes must be sent again.
    pub fn resendSizes(ws: *Workspace) void {
        for (ws.panes.items) |p| p.term.resendSize();
    }

    fn fromWidget(w: *gtk.Widget) *Workspace {
        return @ptrCast(@alignCast(gobject.Object.getData(w.as(gobject.Object), "compy-workspace").?));
    }
};

fn measure(_: *gtk.Widget, _: gtk.Orientation, _: c_int, minimum: *c_int, natural: *c_int, min_baseline: *c_int, nat_baseline: *c_int) callconv(.c) void {
    minimum.* = 120;
    natural.* = 640;
    min_baseline.* = -1;
    nat_baseline.* = -1;
}

fn allocate(widget: *gtk.Widget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    const ws = Workspace.fromWidget(widget);
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    for (ws.panes.items) |p| {
        // Scale to the size plus one gap, then give the gap back on the far side, so panes meet
        // the card's edges and leave exactly one gap between neighbours.
        const x0 = p.rect.x * (w + gap);
        const y0 = p.rect.y * (h + gap);
        const x1 = (p.rect.x + p.rect.w) * (w + gap) - gap;
        const y1 = (p.rect.y + p.rect.h) * (h + gap) - gap;
        var a: gtk.Allocation = .{
            .f_x = @intFromFloat(@round(x0)),
            .f_y = @intFromFloat(@round(y0)),
            .f_width = @intFromFloat(@max(1, @round(x1) - @round(x0))),
            .f_height = @intFromFloat(@max(1, @round(y1) - @round(y0))),
        };
        p.frame.sizeAllocate(&a, -1);
    }
}

fn replace(slot: *?[]u8, value: []const u8) void {
    if (slot.*) |old| {
        if (std.mem.eql(u8, old, value)) return;
        gpa.free(old);
    }
    slot.* = gpa.dupe(u8, value) catch null;
}
