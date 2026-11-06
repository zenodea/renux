//! The panes of one Rex window, each a card, laid out the way the server tiles them. Panes keep
//! their terminal views across layout changes, so a split or a resize doesn't reconnect anything.
//!
//! Pointer work happens here too: dragging the gap between cards resizes, dragging a card by its
//! title moves it (an edge of another pane puts it there, the middle swaps the two, the trash can
//! closes it), and floating cards move by their title and resize by their corner.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");
const view = @import("view.zig");
const Server = @import("server.zig").Server;
const TermView = @import("termview.zig").TermView;
const icons = @import("icons.zig");
const blockicon = @import("blockicon.zig");

const gpa = std.heap.c_allocator;

/// Space between pane cards; Tight packs them edge to edge with one line between.
pub var gap: f64 = 8;
pub var tight = false;
pub var show_headers = true;

pub fn isTightNow() bool {
    return tight;
}

pub fn setTight(on: bool) void {
    tight = on;
    gap = if (on) 1 else 8;
}

const Zone = enum { none, left, right, top, bottom, swap, trash };

const Pane = struct {
    block_id: []u8,
    layer_id: []u8,
    /// The pane's card: its title row above the terminal.
    frame: *gtk.Widget,
    tile: *gtk.Widget,
    term: *TermView,
    grip: *gtk.Widget,
    title_row: *gtk.Widget,
    rect: view.Rect = .{},
    floating: bool = false,
    seen: bool = false,
};

const Divider = struct {
    horizontal: bool,
    rect: view.Rect,
    ratio: f64,
    before_id: []u8,
    after_id: []u8,
};

const Minimized = struct { layer_id: []u8, block_id: []u8, button: *gtk.Widget };

pub const Workspace = struct {
    pub fn isTight() bool {
        return tight;
    }

    root: *gtk.Widget,
    overlay: *gtk.Widget,
    tray: *gtk.Box,
    server: *Server,
    session_id: ?[]u8 = null,
    window_id: ?[]u8 = null,
    focused: ?[]u8 = null,
    panes: std.ArrayList(Pane) = .empty,
    dividers: std.ArrayList(Divider) = .empty,
    minimized: std.ArrayList(Minimized) = .empty,

    // Dragging.
    resizing: ?usize = null,
    last_resize: i64 = 0,
    moving: ?usize = null,
    move_armed: bool = false,
    move_origin: [2]f64 = .{ 0, 0 },
    pointer: [2]f64 = .{ 0, 0 },
    zone: Zone = .none,
    zone_pane: ?usize = null,
    /// Where a floating card started, for moving and resizing it.
    float_start: view.Rect = .{},
    float_resizing: bool = false,
    /// 0 to 1: how far the trash can has come up, and how open its lid is.
    trash_shown: f64 = 0,
    trash_open: f64 = 0,
    tick: c_uint = 0,

    pub fn create(server: *Server) !*Workspace {
        const ws = try gpa.create(Workspace);
        const box = gtk.Box.new(.horizontal, 0);
        const root = box.as(gtk.Widget);
        root.setHexpand(1);
        root.setVexpand(1);
        root.addCssClass("workspace");
        const layout = gtk.CustomLayout.new(null, &measure, &allocate);
        root.setLayoutManager(layout.as(gtk.LayoutManager));

        // Drawn above the cards: drop targets, the card being carried, and the trash can.
        const overlay = gtk.DrawingArea.new();
        overlay.as(gtk.Widget).setCanTarget(0);
        const tray = gtk.Box.new(.horizontal, 6);
        tray.as(gtk.Widget).addCssClass("tray");

        // The workspace owns these, since it moves them above the cards by re-parenting.
        _ = overlay.as(gobject.Object).refSink();
        _ = tray.as(gobject.Object).refSink();
        ws.* = .{ .root = root, .overlay = overlay.as(gtk.Widget), .tray = tray, .server = server };
        overlay.setDrawFunc(&drawOverlay, ws, null);
        gobject.Object.setData(root.as(gobject.Object), "compy-workspace", ws);

        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Workspace, &dividerBegin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Workspace, &dividerUpdate, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Workspace, &dividerEnd, ws, .{});
        root.addController(drag.as(gtk.EventController));
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Workspace, &hover, ws, .{});
        root.addController(motion.as(gtk.EventController));
        return ws;
    }

    /// Shows a window, or nothing when `window` is null.
    pub fn show(ws: *Workspace, session_id: []const u8, window: ?*const view.Window) void {
        const same_session = if (ws.session_id) |s| std.mem.eql(u8, s, session_id) else false;
        if (!same_session) {
            ws.clear();
            replace(&ws.session_id, session_id);
        }
        ws.clearDividers();
        ws.clearTray();
        const w = window orelse return ws.clear();
        replace(&ws.window_id, w.id);
        if (w.focused_block_id) |f| replace(&ws.focused, f);

        for (ws.panes.items) |*p| p.seen = false;
        if (w.zoomed_block_id) |z| {
            ws.place(session_id, z, "", .{}, false);
        } else if (w.tiled()) |layer| {
            if (layer.layout) |node| ws.placeNode(session_id, node, layer.id, null);
        }
        // Floating layers sit over the tiles, at their bounds; minimized ones wait in the tray.
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating) continue;
            if (layer.minimized) {
                if (layer.blocks.len > 0) ws.addToTray(layer.id, layer.blocks[0].id);
                continue;
            }
            if (layer.layout) |node| ws.placeNode(session_id, node, layer.id, layer.bounds);
        };

        var i: usize = 0;
        while (i < ws.panes.items.len) {
            if (!ws.panes.items[i].seen) {
                const p = ws.panes.orderedRemove(i);
                ws.drop(p);
            } else i += 1;
        }
        // Keep the overlay and tray above the cards.
        ws.overlay.unparent();
        ws.overlay.setParent(ws.root);
        ws.tray.as(gtk.Widget).unparent();
        ws.tray.as(gtk.Widget).setParent(ws.root);
        ws.markFocus();
        ws.root.queueAllocate();
    }

    pub fn clear(ws: *Workspace) void {
        for (ws.panes.items) |p| ws.drop(p);
        ws.panes.clearRetainingCapacity();
        ws.clearDividers();
        ws.clearTray();
    }

    fn clearDividers(ws: *Workspace) void {
        if (ws.resizing != null) return; // keep them while one is being dragged
        for (ws.dividers.items) |d| {
            gpa.free(d.before_id);
            gpa.free(d.after_id);
        }
        ws.dividers.clearRetainingCapacity();
    }

    fn clearTray(ws: *Workspace) void {
        for (ws.minimized.items) |m| {
            ws.tray.remove(m.button);
            gpa.free(m.layer_id);
            gpa.free(m.block_id);
        }
        ws.minimized.clearRetainingCapacity();
    }

    fn drop(ws: *Workspace, p: Pane) void {
        p.frame.unparent();
        ws.server.releaseTerminal(p.block_id);
        gpa.free(p.block_id);
        gpa.free(p.layer_id);
    }

    /// Places a layer's panes; `bounds` is set for a floating layer.
    fn placeNode(ws: *Workspace, session_id: []const u8, node: *const view.Node, layer_id: []const u8, bounds: ?view.Rect) void {
        switch (node.*) {
            // Leaf rectangles are already in window fractions, floating layers included.
            .leaf => |l| ws.place(session_id, l.block_id, layer_id, l.rect, bounds != null),
            .split => |s| {
                if (bounds == null and ws.resizing == null) ws.dividers.append(gpa, .{
                    .horizontal = s.horizontal,
                    .rect = s.rect,
                    .ratio = s.ratio,
                    .before_id = gpa.dupe(u8, firstLeaf(s.before)) catch return,
                    .after_id = gpa.dupe(u8, firstLeaf(s.after)) catch return,
                }) catch {};
                ws.placeNode(session_id, s.before, layer_id, bounds);
                ws.placeNode(session_id, s.after, layer_id, bounds);
            },
        }
    }

    fn place(ws: *Workspace, session_id: []const u8, block_id: []const u8, layer_id: []const u8, rect: view.Rect, floating: bool) void {
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) {
            p.rect = rect;
            p.seen = true;
            replace2(&p.layer_id, layer_id);
            if (p.floating != floating) {
                p.floating = floating;
                if (floating) p.frame.addCssClass("floating") else p.frame.removeCssClass("floating");
                p.grip.setVisible(@intFromBool(floating));
            }
            return;
        };
        const tv = TermView.create(ws.server, session_id, block_id) catch return;
        tv.on_focus = .{ .ctx = ws, .f = clicked };
        const owned = gpa.dupe(u8, block_id) catch return;

        // The title row: the program's tile and title, then this pane's buttons.
        const row = gtk.Box.new(.horizontal, 2);
        row.as(gtk.Widget).addCssClass("pane-title");
        row.as(gtk.Widget).setVisible(@intFromBool(show_headers));
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
        const target = gpa.dupeSentinel(u8, block_id, 0) catch return;
        defer gpa.free(target);
        inline for (.{
            .{ icons.Kind.split_right, "Split right", "app.pane-split-right" },
            .{ icons.Kind.split_down, "Split down", "app.pane-split-down" },
            .{ icons.Kind.float, "Float or minimize", "app.pane-float" },
            .{ icons.Kind.zoom, "Zoom", "app.pane-zoom" },
            .{ icons.Kind.close, "Close pane", "app.pane-close" },
        }) |b| {
            const button = icons.button(b[0], b[1], b[2]);
            button.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(target.ptr));
            tools.append(button.as(gtk.Widget));
        }
        row.append(tools.as(gtk.Widget));
        const PaneDrag = struct {
            fn begin(g: *gtk.GestureDrag, x: f64, y: f64, w: *Workspace) callconv(.c) void {
                w.moveBegin(g.as(gtk.EventController).getWidget() orelse return, x, y);
            }
            fn update(g: *gtk.GestureDrag, dx: f64, dy: f64, w: *Workspace) callconv(.c) void {
                const d = w.steadyOffset(g, dx, dy) orelse return;
                w.moveUpdate(d[0], d[1]);
            }
            fn end(_: *gtk.GestureDrag, _: f64, _: f64, w: *Workspace) callconv(.c) void {
                w.moveEnd();
            }
        };
        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Workspace, &PaneDrag.begin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Workspace, &PaneDrag.update, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Workspace, &PaneDrag.end, ws, .{});
        row.as(gtk.Widget).addController(drag.as(gtk.EventController));
        // The drag handlers find their pane by the widget, so tag it with the block.
        gobject.Object.setData(row.as(gobject.Object), "compy-block", owned.ptr);

        const card = gtk.Box.new(.vertical, 0);
        card.as(gtk.Widget).setOverflow(.hidden);
        card.append(row.as(gtk.Widget));
        card.append(tv.widget());
        tv.setTitleLabel(label);

        // Floating cards resize from their bottom-right corner.
        const grip = gtk.DrawingArea.new();
        grip.setContentWidth(16);
        grip.setContentHeight(16);
        grip.setDrawFunc(&drawGrip, null, null);
        const gw = grip.as(gtk.Widget);
        gw.setHalign(.end);
        gw.setValign(.end);
        gw.setCursorFromName("se-resize");
        gw.setVisible(@intFromBool(floating));
        const GripDrag = struct {
            fn begin(g: *gtk.GestureDrag, x: f64, y: f64, w: *Workspace) callconv(.c) void {
                const handle = g.as(gtk.EventController).getWidget() orelse return;
                var px: f64 = 0;
                var py: f64 = 0;
                _ = handle.translateCoordinates(w.root, x, y, &px, &py);
                w.move_origin = .{ px, py };
                w.gripBegin(handle);
            }
            fn update(g: *gtk.GestureDrag, dx: f64, dy: f64, w: *Workspace) callconv(.c) void {
                const d = w.steadyOffset(g, dx, dy) orelse return;
                w.gripUpdate(d[0], d[1]);
            }
            fn end(_: *gtk.GestureDrag, _: f64, _: f64, w: *Workspace) callconv(.c) void {
                w.gripEnd();
            }
        };
        const gdrag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(gdrag, *Workspace, &GripDrag.begin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(gdrag, *Workspace, &GripDrag.update, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(gdrag, *Workspace, &GripDrag.end, ws, .{});
        gw.addController(gdrag.as(gtk.EventController));
        gobject.Object.setData(gw.as(gobject.Object), "compy-block", owned.ptr);

        const frame_overlay = gtk.Overlay.new();
        frame_overlay.setChild(card.as(gtk.Widget));
        frame_overlay.addOverlay(gw);
        const frame = frame_overlay.as(gtk.Widget);
        frame.addCssClass("pane-card");
        frame.setOverflow(.hidden);
        if (floating) frame.addCssClass("floating");
        frame.setParent(ws.root);
        ws.panes.append(gpa, .{
            .block_id = owned,
            .layer_id = gpa.dupe(u8, layer_id) catch return,
            .frame = frame,
            .tile = tile,
            .term = tv,
            .grip = gw,
            .title_row = row.as(gtk.Widget),
            .rect = rect,
            .floating = floating,
            .seen = true,
        }) catch {};
    }

    fn addToTray(ws: *Workspace, layer_id: []const u8, block_id: []const u8) void {
        const button = gtk.Button.new();
        const line = gtk.Box.new(.horizontal, 6);
        line.append(blockicon.create(ws.server, block_id, 14));
        var buf: [128]u8 = undefined;
        const info = ws.server.blockInfo(block_id);
        const name = if (info) |b| if (b.program) |p| p[0 .. std.mem.indexOfScalar(u8, p, '/') orelse p.len] else "Pane" else "Pane";
        const text = std.fmt.bufPrintSentinel(&buf, "{s}", .{std.mem.trimStart(u8, name, "-")}, 0) catch "Pane";
        line.append(gtk.Label.new(text.ptr).as(gtk.Widget));
        button.setChild(line.as(gtk.Widget));
        button.as(gtk.Widget).addCssClass("tray-chip");
        button.as(gtk.Widget).setTooltipText("Bring back");
        const target = gpa.dupeSentinel(u8, layer_id, 0) catch return;
        defer gpa.free(target);
        button.as(gtk.Actionable).setActionName("app.restore-layer");
        button.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(target.ptr));
        ws.tray.append(button.as(gtk.Widget));
        ws.minimized.append(gpa, .{
            .layer_id = gpa.dupe(u8, layer_id) catch return,
            .block_id = gpa.dupe(u8, block_id) catch return,
            .button = button.as(gtk.Widget),
        }) catch {};
    }

    fn clicked(ctx: *anyopaque, block_id: []const u8) void {
        const ws: *Workspace = @ptrCast(@alignCast(ctx));
        ws.server.clearAttention(block_id);
        replace(&ws.focused, block_id);
        ws.markFocus();
        if (ws.session_id) |s| {
            ws.server.focusBlock(s, block_id);
            if (ws.paneOf(block_id)) |p| if (p.floating) ws.server.raiseLayer(s, p.layer_id);
        }
    }

    fn markFocus(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            const on = if (ws.focused) |f| std.mem.eql(u8, f, p.block_id) else false;
            if (on) p.frame.addCssClass("focused") else p.frame.removeCssClass("focused");
        }
    }

    pub fn paneOf(ws: *Workspace, block_id: []const u8) ?*Pane {
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) return p;
        return null;
    }

    /// Marks a pane focused here and on the server, such as before acting on it.
    pub fn focus(ws: *Workspace, block_id: []const u8) void {
        clicked(ws, block_id);
    }

    /// Gives the keyboard to the focused pane.
    pub fn grabFocus(ws: *Workspace) void {
        if (ws.focusedView()) |tv| _ = tv.widget().grabFocus();
    }

    /// The focused pane's terminal view.
    pub fn focusedView(ws: *Workspace) ?*TermView {
        if (ws.focused) |f| if (ws.paneOf(f)) |p| return p.term;
        return if (ws.panes.items.len > 0) ws.panes.items[0].term else null;
    }

    /// The pane with the keyboard, or the one the server says is focused.
    pub fn focusedBlock(ws: *Workspace) ?[]const u8 {
        return ws.focused;
    }

    /// A block's details changed: redraw its tile and title.
    pub fn blockChanged(ws: *Workspace, block_id: []const u8) void {
        if (ws.paneOf(block_id)) |p| {
            p.tile.queueDraw();
            p.term.updateTitle();
        }
    }

    pub fn isShown(ws: *Workspace, block_id: []const u8) bool {
        return ws.paneOf(block_id) != null;
    }

    pub fn headersChanged(ws: *Workspace) void {
        for (ws.panes.items) |p| p.title_row.setVisible(@intFromBool(show_headers));
    }

    pub fn redraw(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            p.term.widget().queueDraw();
            p.tile.queueDraw();
        }
    }

    /// The terminal font changed: every pane measures its cells again and refits.
    pub fn fontChanged(ws: *Workspace) void {
        for (ws.panes.items) |p| p.term.fontChanged();
    }

    /// After reconnecting, sizes must be sent again.
    pub fn resendSizes(ws: *Workspace) void {
        for (ws.panes.items) |p| p.term.resendSize();
    }

    fn fromWidget(w: *gtk.Widget) *Workspace {
        return @ptrCast(@alignCast(gobject.Object.getData(w.as(gobject.Object), "compy-workspace").?));
    }

    // Geometry. Fractions of the window become pixels with one gap between neighbours and none at
    // the edges.

    fn width(ws: *Workspace) f64 {
        return @floatFromInt(ws.root.getWidth());
    }

    fn height(ws: *Workspace) f64 {
        return @floatFromInt(ws.root.getHeight());
    }

    fn pixels(ws: *Workspace, r: view.Rect) [4]f64 {
        const w = ws.width();
        const h = ws.height();
        const x0 = r.x * (w + gap);
        const y0 = r.y * (h + gap);
        return .{ x0, y0, (r.x + r.w) * (w + gap) - gap - x0, (r.y + r.h) * (h + gap) - gap - y0 };
    }

    // Dividers.

    fn dividerAt(ws: *Workspace, x: f64, y: f64) ?usize {
        const w = ws.width();
        const h = ws.height();
        const reach = @max(gap / 2 + 3, 5);
        for (ws.dividers.items, 0..) |d, i| {
            const r = ws.pixels(d.rect);
            if (d.horizontal) {
                const at = (d.rect.x + d.rect.w * d.ratio) * (w + gap) - gap / 2;
                if (@abs(x - at) <= reach and y >= r[1] and y <= r[1] + r[3]) return i;
            } else {
                const at = (d.rect.y + d.rect.h * d.ratio) * (h + gap) - gap / 2;
                if (@abs(y - at) <= reach and x >= r[0] and x <= r[0] + r[2]) return i;
            }
        }
        return null;
    }

    fn hover(_: *gtk.EventControllerMotion, x: f64, y: f64, ws: *Workspace) callconv(.c) void {
        if (ws.resizing != null or ws.moving != null) return;
        const cursor: ?[*:0]const u8 = if (ws.dividerAt(x, y)) |i| (if (ws.dividers.items[i].horizontal) "col-resize" else "row-resize") else null;
        ws.root.setCursorFromName(cursor);
    }

    fn dividerBegin(g: *gtk.GestureDrag, x: f64, y: f64, ws: *Workspace) callconv(.c) void {
        ws.resizing = ws.dividerAt(x, y);
        if (ws.resizing == null) {
            _ = g.as(gtk.Gesture).setState(.denied);
            return;
        }
        _ = g.as(gtk.Gesture).setState(.claimed);
        ws.move_origin = .{ x, y };
    }

    fn sendDivider(ws: *Workspace, dx: f64, dy: f64, force: bool) void {
        const i = ws.resizing orelse return;
        const d = &ws.dividers.items[i];
        const w = ws.width();
        const h = ws.height();
        // The ratio under the pointer, within the split's own rectangle.
        const ratio = if (d.horizontal)
            ((ws.move_origin[0] + dx + gap / 2) / (w + gap) - d.rect.x) / d.rect.w
        else
            ((ws.move_origin[1] + dy + gap / 2) / (h + gap) - d.rect.y) / d.rect.h;
        // Each change makes programs redraw, so send at most every 60 ms while dragging.
        const now = glib.getMonotonicTime();
        if (!force and now - ws.last_resize < 60_000) return;
        ws.last_resize = now;
        if (ws.session_id) |s| ws.server.resizePane(s, d.horizontal, d.before_id, d.after_id, std.math.clamp(ratio, 0.05, 0.95));
    }

    fn dividerUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, ws: *Workspace) callconv(.c) void {
        ws.sendDivider(dx, dy, false);
    }

    fn dividerEnd(_: *gtk.GestureDrag, dx: f64, dy: f64, ws: *Workspace) callconv(.c) void {
        if (ws.resizing == null) return;
        ws.sendDivider(dx, dy, true);
        ws.resizing = null;
    }

    // Carrying a pane by its title.

    fn paneOfWidget(ws: *Workspace, w: *gtk.Widget) ?usize {
        const data = gobject.Object.getData(w.as(gobject.Object), "compy-block") orelse return null;
        for (ws.panes.items, 0..) |p, i| if (@intFromPtr(p.block_id.ptr) == @intFromPtr(data)) return i;
        return null;
    }

    /// A drag's offset measured in the workspace, which stays put. GTK measures it in the dragged
    /// widget's own space, and that widget moves with the card, so the raw offset would fight the
    /// pointer and stutter.
    fn steadyOffset(ws: *Workspace, g: *gtk.GestureDrag, dx: f64, dy: f64) ?[2]f64 {
        const w = g.as(gtk.EventController).getWidget() orelse return null;
        var sx: f64 = 0;
        var sy: f64 = 0;
        if (g.getStartPoint(&sx, &sy) == 0) return null;
        var px: f64 = 0;
        var py: f64 = 0;
        if (w.translateCoordinates(ws.root, sx + dx, sy + dy, &px, &py) == 0) return null;
        return .{ px - ws.move_origin[0], py - ws.move_origin[1] };
    }

    fn moveBegin(ws: *Workspace, title: *gtk.Widget, x: f64, y: f64) void {
        const i = ws.paneOfWidget(title) orelse return;
        ws.moving = i;
        ws.move_armed = false;
        var px: f64 = 0;
        var py: f64 = 0;
        _ = title.translateCoordinates(ws.root, x, y, &px, &py);
        ws.move_origin = .{ px, py };
        ws.pointer = .{ px, py };
        ws.float_start = ws.panes.items[i].rect;
        clicked(ws, ws.panes.items[i].block_id);
    }

    fn moveUpdate(ws: *Workspace, dx: f64, dy: f64) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing) return;
        if (!ws.move_armed and @abs(dx) < 6 and @abs(dy) < 6) return;
        ws.move_armed = true;
        ws.pointer = .{ ws.move_origin[0] + dx, ws.move_origin[1] + dy };
        const p = &ws.panes.items[i];
        if (p.floating) {
            // A floating card follows the pointer; the server hears where it lands.
            p.rect.x = std.math.clamp(ws.float_start.x + dx / ws.width(), 0, 1 - p.rect.w);
            p.rect.y = std.math.clamp(ws.float_start.y + dy / ws.height(), 0, 1 - p.rect.h);
            ws.root.queueAllocate();
            return;
        }
        ws.updateZone();
        ws.startTick();
        ws.overlay.queueDraw();
    }

    fn moveEnd(ws: *Workspace) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing) return;
        defer {
            ws.moving = null;
            ws.zone = .none;
            ws.zone_pane = null;
            ws.overlay.queueDraw();
        }
        if (!ws.move_armed) return;
        const sid = ws.session_id orelse return;
        const p = ws.panes.items[i];
        if (p.floating) return ws.server.resizeLayer(sid, p.layer_id, p.rect);
        switch (ws.zone) {
            .none => {},
            .trash => ws.server.closeBlock(sid, p.block_id),
            .swap => if (ws.zone_pane) |t| ws.server.swapBlocks(sid, p.block_id, ws.panes.items[t].block_id),
            .left, .right, .top, .bottom => if (ws.zone_pane) |t| ws.server.moveBlock(
                sid,
                p.block_id,
                ws.panes.items[t].block_id,
                ws.zone == .left or ws.zone == .right,
                ws.zone == .left or ws.zone == .top,
            ),
        }
    }

    fn trashRect(ws: *Workspace) [4]f64 {
        const size = 56.0;
        return .{ ws.width() - size - 18, ws.height() - size - 18, size, size };
    }

    fn updateZone(ws: *Workspace) void {
        const x = ws.pointer[0];
        const y = ws.pointer[1];
        const t = ws.trashRect();
        ws.zone = .none;
        ws.zone_pane = null;
        if (x >= t[0] - 20 and y >= t[1] - 20) {
            ws.zone = .trash;
            return;
        }
        for (ws.panes.items, 0..) |p, i| {
            if (p.floating or i == ws.moving.?) continue;
            const r = ws.pixels(p.rect);
            if (x < r[0] or y < r[1] or x > r[0] + r[2] or y > r[1] + r[3]) continue;
            // The nearest edge, unless the pointer is in the middle, which swaps.
            const fx = (x - r[0]) / r[2];
            const fy = (y - r[1]) / r[3];
            ws.zone_pane = i;
            if (fx > 0.3 and fx < 0.7 and fy > 0.3 and fy < 0.7) {
                ws.zone = .swap;
            } else {
                const d = [_]f64{ fx, 1 - fx, fy, 1 - fy };
                var best: usize = 0;
                for (d, 0..) |v, k| if (v < d[best]) {
                    best = k;
                };
                ws.zone = switch (best) {
                    0 => .left,
                    1 => .right,
                    2 => .top,
                    else => .bottom,
                };
            }
            return;
        }
    }

    // The trash can eases toward where it should be on each frame.

    fn startTick(ws: *Workspace) void {
        if (ws.tick != 0) return;
        ws.tick = ws.overlay.addTickCallback(&onTick, ws, null);
    }

    fn onTick(_: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        const carrying = if (ws.moving) |i| ws.move_armed and !ws.panes.items[i].floating else false;
        const show_target: f64 = if (carrying) 1 else 0;
        const open_target: f64 = if (ws.zone == .trash) 1 else 0;
        ws.trash_shown += (show_target - ws.trash_shown) * 0.22;
        ws.trash_open += (open_target - ws.trash_open) * 0.28;
        ws.overlay.queueDraw();
        const settled = @abs(show_target - ws.trash_shown) < 0.005 and @abs(open_target - ws.trash_open) < 0.005;
        if (settled and show_target == 0) {
            ws.trash_shown = 0;
            ws.trash_open = 0;
            ws.tick = 0;
            return 0;
        }
        return 1;
    }

    // For the development script: drive the same paths a pointer would.

    pub fn simulateCarry(ws: *Workspace, block_id: []const u8, x: f64, y: f64) void {
        const i = ws.indexOf(block_id) orelse return;
        const r = ws.pixels(ws.panes.items[i].rect);
        ws.moving = i;
        ws.move_armed = false;
        ws.move_origin = .{ r[0] + 40, r[1] + 16 };
        ws.float_start = ws.panes.items[i].rect;
        ws.moveUpdate(x - ws.move_origin[0], y - ws.move_origin[1]);
    }

    pub fn simulateDrop(ws: *Workspace) void {
        ws.moveEnd();
    }

    pub fn simulateDivider(ws: *Workspace, dx: f64) void {
        if (ws.dividers.items.len == 0) return;
        const d = ws.dividers.items[0];
        const w = ws.width();
        const h = ws.height();
        ws.resizing = 0;
        ws.move_origin = if (d.horizontal)
            .{ (d.rect.x + d.rect.w * d.ratio) * (w + gap) - gap / 2, 10 }
        else
            .{ 10, (d.rect.y + d.rect.h * d.ratio) * (h + gap) - gap / 2 };
        ws.sendDivider(if (d.horizontal) dx else 0, if (d.horizontal) 0 else dx, true);
        ws.resizing = null;
    }

    fn indexOf(ws: *Workspace, block_id: []const u8) ?usize {
        for (ws.panes.items, 0..) |p, i| if (std.mem.eql(u8, p.block_id, block_id)) return i;
        return null;
    }

    // Floating cards resize from their corner.

    fn gripBegin(ws: *Workspace, grip: *gtk.Widget) void {
        const i = ws.paneOfWidget(grip) orelse return;
        ws.moving = i;
        ws.float_resizing = true;
        ws.float_start = ws.panes.items[i].rect;
    }

    fn gripUpdate(ws: *Workspace, dx: f64, dy: f64) void {
        if (!ws.float_resizing) return;
        const p = &ws.panes.items[ws.moving orelse return];
        p.rect.w = std.math.clamp(ws.float_start.w + dx / ws.width(), 0.15, 1 - p.rect.x);
        p.rect.h = std.math.clamp(ws.float_start.h + dy / ws.height(), 0.15, 1 - p.rect.y);
        ws.root.queueAllocate();
    }

    fn gripEnd(ws: *Workspace) void {
        defer {
            ws.float_resizing = false;
            ws.moving = null;
        }
        const p = ws.panes.items[ws.moving orelse return];
        if (ws.session_id) |s| ws.server.resizeLayer(s, p.layer_id, p.rect);
    }
};

fn firstLeaf(n: *const view.Node) []const u8 {
    return switch (n.*) {
        .leaf => |l| l.block_id,
        .split => |s| firstLeaf(s.before),
    };
}

fn measure(_: *gtk.Widget, _: gtk.Orientation, _: c_int, minimum: *c_int, natural: *c_int, min_baseline: *c_int, nat_baseline: *c_int) callconv(.c) void {
    minimum.* = 120;
    natural.* = 640;
    min_baseline.* = -1;
    nat_baseline.* = -1;
}

fn allocate(widget: *gtk.Widget, width: c_int, height: c_int, _: c_int) callconv(.c) void {
    const ws = Workspace.fromWidget(widget);
    for (ws.panes.items) |p| {
        const r = ws.pixels(p.rect);
        var a: gtk.Allocation = .{
            .f_x = @intFromFloat(@round(r[0])),
            .f_y = @intFromFloat(@round(r[1])),
            .f_width = @intFromFloat(@max(1, @round(r[2]))),
            .f_height = @intFromFloat(@max(1, @round(r[3]))),
        };
        p.frame.sizeAllocate(&a, -1);
    }
    var all: gtk.Allocation = .{ .f_x = 0, .f_y = 0, .f_width = width, .f_height = height };
    ws.overlay.sizeAllocate(&all, -1);
    // The tray sits at the bottom left, as wide as its chips.
    var min: c_int = 0;
    var nat: c_int = 0;
    ws.tray.as(gtk.Widget).measure(.horizontal, -1, &min, &nat, null, null);
    var th_min: c_int = 0;
    var th: c_int = 0;
    ws.tray.as(gtk.Widget).measure(.vertical, -1, &th_min, &th, null, null);
    var tray: gtk.Allocation = .{ .f_x = 10, .f_y = height - th - 10, .f_width = @max(0, @min(nat, width - 20)), .f_height = th };
    ws.tray.as(gtk.Widget).sizeAllocate(&tray, -1);
}

fn setRgba(cr: *cairo.Context, c: gdk.RGBA, alpha: f64) void {
    cr.setSourceRgba(c.f_red, c.f_green, c.f_blue, c.f_alpha * alpha);
}

fn roundRect(cr: *cairo.Context, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const pi: f64 = std.math.pi;
    cr.newSubPath();
    cr.arc(x + w - r, y + r, r, -pi / 2, 0);
    cr.arc(x + w - r, y + h - r, r, 0, pi / 2);
    cr.arc(x + r, y + h - r, r, pi / 2, pi);
    cr.arc(x + r, y + r, r, pi, 3 * pi / 2);
    cr.closePath();
}

fn drawOverlay(area: *gtk.DrawingArea, cr: *cairo.Context, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const ws: *Workspace = @ptrCast(@alignCast(data.?));
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    const accent: gdk.RGBA = .{ .f_red = 0.35, .f_green = 0.62, .f_blue = 1, .f_alpha = 1 };

    // Where the pane would land.
    if (ws.moving != null and ws.move_armed) if (ws.zone_pane) |t| {
        const r = ws.pixels(ws.panes.items[t].rect);
        var x = r[0];
        var y = r[1];
        var w = r[2];
        var h = r[3];
        switch (ws.zone) {
            .left => w /= 2,
            .right => {
                x += w / 2;
                w /= 2;
            },
            .top => h /= 2,
            .bottom => {
                y += h / 2;
                h /= 2;
            },
            else => {},
        }
        setRgba(cr, accent, 0.18);
        roundRect(cr, x + 4, y + 4, w - 8, h - 8, 9);
        cr.fillPreserve();
        setRgba(cr, accent, 0.8);
        cr.setLineWidth(1.5);
        cr.stroke();
        if (ws.zone == .swap) {
            // Two arrows passing each other.
            const cx = x + w / 2;
            const cy = y + h / 2;
            cr.setLineWidth(2);
            cr.setLineCap(.round);
            cr.moveTo(cx - 14, cy - 5);
            cr.lineTo(cx + 14, cy - 5);
            cr.lineTo(cx + 8, cy - 11);
            cr.moveTo(cx + 14, cy + 5);
            cr.lineTo(cx - 14, cy + 5);
            cr.lineTo(cx - 8, cy + 11);
            cr.stroke();
        }
    };

    // The card being carried, small, under the pointer.
    if (ws.moving) |i| if (ws.move_armed and !ws.panes.items[i].floating) {
        const shrink = 1 - 0.35 * ws.trash_open;
        const w = 150 * shrink;
        const h = 92 * shrink;
        const x = ws.pointer[0] - w / 2;
        const y = ws.pointer[1] - h / 2;
        cr.setSourceRgba(0, 0, 0, 0.35);
        roundRect(cr, x + 2, y + 5, w, h, 10);
        cr.fill();
        setRgba(cr, ink, 0.14);
        roundRect(cr, x, y, w, h, 10);
        cr.fill();
        setRgba(cr, accent, 0.9);
        cr.setLineWidth(1.5);
        roundRect(cr, x, y, w, h, 10);
        cr.stroke();
    };

    // The trash can rises from the corner while a pane is carried, and opens its lid over it.
    if (ws.trash_shown > 0.01) {
        const t = ws.trashRect();
        const rise = (1 - ws.trash_shown) * 40;
        const cx = t[0] + t[2] / 2;
        const cy = t[1] + t[3] / 2 + rise;
        const danger = ws.trash_open;
        cr.setSourceRgba(0.95 * danger + 0.22 * (1 - danger), 0.27 * danger + 0.22 * (1 - danger), 0.25 * danger + 0.24 * (1 - danger), ws.trash_shown);
        cr.arc(cx, cy, t[2] / 2 * (1 + 0.12 * danger), 0, 2 * std.math.pi);
        cr.fill();
        cr.setSourceRgba(1, 1, 1, ws.trash_shown * (0.75 + 0.25 * danger));
        cr.setLineWidth(1.8);
        cr.setLineCap(.round);
        cr.setLineJoin(.round);
        // The can.
        cr.moveTo(cx - 8, cy - 4);
        cr.lineTo(cx - 6.5, cy + 10);
        cr.lineTo(cx + 6.5, cy + 10);
        cr.lineTo(cx + 8, cy - 4);
        cr.stroke();
        cr.moveTo(cx - 2.5, cy - 1);
        cr.lineTo(cx - 2.2, cy + 7);
        cr.moveTo(cx + 2.5, cy - 1);
        cr.lineTo(cx + 2.2, cy + 7);
        cr.stroke();
        // The lid tips open around its right end.
        cr.save();
        cr.translate(cx + 10, cy - 7 - 3 * danger);
        cr.rotate(-0.6 * danger);
        cr.moveTo(-20, 0);
        cr.lineTo(0, 0);
        cr.moveTo(-13, 0);
        cr.lineTo(-12.5, -3);
        cr.lineTo(-7.5, -3);
        cr.lineTo(-7, 0);
        cr.stroke();
        cr.restore();
    }
}

fn drawGrip(area: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, _: ?*anyopaque) callconv(.c) void {
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    setRgba(cr, ink, 0.45);
    cr.setLineWidth(1.3);
    cr.setLineCap(.round);
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    for ([_]f64{ 4, 8 }) |o| {
        cr.moveTo(fw - 3, fh - 3 - o);
        cr.lineTo(fw - 3 - o, fh - 3);
        cr.stroke();
    }
}

fn replace(slot: *?[]u8, value: []const u8) void {
    if (slot.*) |old| {
        if (std.mem.eql(u8, old, value)) return;
        gpa.free(old);
    }
    slot.* = gpa.dupe(u8, value) catch null;
}

fn replace2(slot: *[]u8, value: []const u8) void {
    if (std.mem.eql(u8, slot.*, value)) return;
    const copy = gpa.dupe(u8, value) catch return;
    gpa.free(slot.*);
    slot.* = copy;
}
