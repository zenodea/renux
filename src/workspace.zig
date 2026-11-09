//! The panes of one Rex window, each a card, laid out the way the server tiles them. Panes keep
//! their terminal views across layout changes, so a split or a resize doesn't reconnect anything.
//!
//! Pointer work happens here too: dragging the gap between cards resizes, dragging a card by its
//! title moves it (an edge of another pane puts it there, the middle swaps the two), and floating
//! cards move by their title and resize by their corner.
//!
//! Cards glide to their new places on a spring when the layout changes, fade in when they appear
//! and fade out when they go.
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

/// How far the window's corner (its buttons and the sidebar toggle) reaches into the top-left
/// pane while the sidebar is hidden; that pane's title starts after it.
pub var corner_room: f64 = 0;

pub fn isTightNow() bool {
    return tight;
}

pub fn setTight(on: bool) void {
    tight = on;
    gap = if (on) 1 else 8;
}

const Zone = enum { none, left, right, top, bottom, swap };

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
    /// Where the card is drawn now, in pixels, and how fast that is moving toward `rect`.
    cur: [4]f64 = .{ 0, 0, 0, 0 },
    vel: [4]f64 = .{ 0, 0, 0, 0 },
    alpha: f64 = 0,
    /// Not placed yet: it starts slightly small and clear, then grows in.
    fresh: bool = true,
};

/// A card whose pane went away, fading out where it was.
const Leaving = struct { frame: *gtk.Widget, cur: [4]f64, alpha: f64, block_id: []u8 };

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
    empty: *gtk.Widget,
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
    // Animation.
    leaving: std.ArrayList(Leaving) = .empty,
    tick: c_uint = 0,
    last_time: i64 = 0,
    last_size: [2]f64 = .{ 0, 0 },
    /// Put every card straight where it belongs on the next layout, such as for another window.
    snap: bool = false,

    pub fn create(server: *Server) !*Workspace {
        const ws = try gpa.create(Workspace);
        const box = gtk.Box.new(.horizontal, 0);
        const root = box.as(gtk.Widget);
        root.setHexpand(1);
        root.setVexpand(1);
        root.addCssClass("workspace");
        const layout = gtk.CustomLayout.new(null, &measure, &allocate);
        root.setLayoutManager(layout.as(gtk.LayoutManager));

        // Drawn above the cards: drop targets and the card being carried.
        const overlay = gtk.DrawingArea.new();
        overlay.as(gtk.Widget).setCanTarget(0);
        const tray = gtk.Box.new(.horizontal, 6);
        tray.as(gtk.Widget).addCssClass("tray");

        // The workspace owns these, since it moves them above the cards by re-parenting.
        _ = overlay.as(gobject.Object).refSink();
        _ = tray.as(gobject.Object).refSink();

        // What a session without windows shows: a way to open one.
        const empty = gtk.Box.new(.vertical, 12);
        const ew = empty.as(gtk.Widget);
        ew.setHalign(.center);
        ew.setValign(.center);
        ew.addCssClass("empty-session");
        const note = gtk.Label.new("No windows in this session");
        note.as(gtk.Widget).addCssClass("dim-label");
        empty.append(note.as(gtk.Widget));
        const open_one = gtk.Button.newWithLabel("New Window");
        open_one.as(gtk.Actionable).setActionName("app.new-window");
        open_one.as(gtk.Widget).addCssClass("pill");
        open_one.as(gtk.Widget).setHalign(.center);
        empty.append(open_one.as(gtk.Widget));
        ew.setVisible(0);
        ew.setParent(root);

        ws.* = .{ .root = root, .overlay = overlay.as(gtk.Widget), .tray = tray, .empty = ew, .server = server };
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
            ws.snap = true;
        }
        ws.clearDividers();
        ws.clearTray();
        ws.empty.setVisible(@intFromBool(window == null));
        const w = window orelse return ws.clear();
        if (ws.window_id) |old| {
            if (!std.mem.eql(u8, old, w.id)) ws.snap = true;
        } else ws.snap = true;
        replace(&ws.window_id, w.id);
        if (w.focused_block_id) |f| replace(&ws.focused, f);

        for (ws.panes.items) |*p| p.seen = false;
        // A drag in progress follows its pane by block, since the list can change under it.
        const dragged: ?[*]const u8 = if (ws.moving) |m| (if (m < ws.panes.items.len) ws.panes.items[m].block_id.ptr else null) else null;
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
                if (ws.snap) ws.drop(p) else ws.leave(p);
            } else i += 1;
        }
        if (ws.moving != null) {
            ws.moving = null;
            if (dragged) |d| for (ws.panes.items, 0..) |p, k| if (p.block_id.ptr == d) {
                ws.moving = k;
            };
            if (ws.moving == null) {
                ws.float_resizing = false;
                ws.zone = .none;
                ws.zone_pane = null;
            }
        }
        if (ws.zone_pane) |z| if (z >= ws.panes.items.len) {
            ws.zone_pane = null;
            ws.zone = .none;
        };
        // Keep the overlay and tray above the cards.
        ws.overlay.unparent();
        ws.overlay.setParent(ws.root);
        ws.tray.as(gtk.Widget).unparent();
        ws.tray.as(gtk.Widget).setParent(ws.root);
        ws.markFocus();
        ws.cornerChanged();
        ws.root.queueAllocate();
    }

    /// The top-left pane's title starts after the window's corner while the sidebar is hidden.
    pub fn cornerChanged(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            const top_left = !p.floating and p.rect.x < 0.001 and p.rect.y < 0.001;
            p.title_row.setMarginStart(if (top_left) @intFromFloat(corner_room) else 0);
        }
    }

    pub fn clear(ws: *Workspace) void {
        for (ws.panes.items) |p| ws.drop(p);
        ws.panes.clearRetainingCapacity();
        for (ws.leaving.items) |l| ws.gone(l);
        ws.leaving.clearRetainingCapacity();
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

    /// Lets a card fade out where it was before it goes.
    fn leave(ws: *Workspace, p: Pane) void {
        p.frame.setCanTarget(0);
        gpa.free(p.layer_id);
        // The terminal stays until the card has faded, so it fades with its text.
        ws.leaving.append(gpa, .{ .frame = p.frame, .cur = p.cur, .alpha = p.alpha, .block_id = p.block_id }) catch {
            p.frame.unparent();
            ws.server.releaseTerminal(p.block_id);
            gpa.free(p.block_id);
            return;
        };
        ws.startTick();
    }

    /// A faded card goes for good, and its terminal too unless the pane came back meanwhile.
    fn gone(ws: *Workspace, l: Leaving) void {
        l.frame.unparent();
        if (ws.paneOf(l.block_id) == null) ws.server.releaseTerminal(l.block_id);
        gpa.free(l.block_id);
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
            .{ icons.Kind.float, "Float or dock", "app.pane-float" },
            .{ icons.Kind.minimize, "Minimize", "app.pane-minimize" },
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
        frame.setOpacity(0);
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
        var buf: [256]u8 = undefined;
        const label = gtk.Label.new(chipTitle(ws.server, block_id, &buf).ptr);
        label.setEllipsize(.middle);
        label.setMaxWidthChars(32);
        line.append(label.as(gtk.Widget));
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

    fn updateZone(ws: *Workspace) void {
        const x = ws.pointer[0];
        const y = ws.pointer[1];
        ws.zone = .none;
        ws.zone_pane = null;
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

    // Animation. Each card's place follows its target on a critically damped spring, so it starts
    // gently, never overshoots and settles in about a quarter of a second.

    const spring = 20.0;

    fn startTick(ws: *Workspace) void {
        if (ws.tick != 0) return;
        ws.last_time = 0;
        ws.tick = ws.root.addTickCallback(&onTick, ws, null);
    }

    fn onTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        const now = clock.getFrameTime();
        const dt: f64 = if (ws.last_time == 0) 1.0 / 60.0 else std.math.clamp(@as(f64, @floatFromInt(now - ws.last_time)) / 1e6, 0, 0.05);
        ws.last_time = now;
        const decay = @exp(-spring * dt);
        var busy = false;
        for (ws.panes.items, 0..) |*p, i| {
            if (ws.pinned(i)) continue;
            const target = ws.pixels(p.rect);
            var still = true;
            for (0..4) |k| {
                const d = p.cur[k] - target[k];
                const v = p.vel[k];
                const nd = (d + (v + spring * d) * dt) * decay;
                p.vel[k] = (v - spring * (v + spring * d) * dt) * decay;
                p.cur[k] = target[k] + nd;
                if (@abs(nd) > 0.4 or @abs(p.vel[k]) > 4) still = false;
            }
            if (still) {
                p.cur = target;
                p.vel = .{ 0, 0, 0, 0 };
            }
            p.alpha += (1 - p.alpha) * (1 - @exp(-14 * dt));
            if (p.alpha > 0.995) p.alpha = 1;
            if (!still or p.alpha < 1) busy = true;
        }
        var i: usize = 0;
        while (i < ws.leaving.items.len) {
            const l = &ws.leaving.items[i];
            l.alpha -= dt / 0.16;
            // Shrinks a little toward its middle as it fades.
            const s = 1 - 0.25 * dt;
            l.cur = .{ l.cur[0] + l.cur[2] * (1 - s) / 2, l.cur[1] + l.cur[3] * (1 - s) / 2, l.cur[2] * s, l.cur[3] * s };
            if (l.alpha <= 0) {
                ws.gone(ws.leaving.orderedRemove(i));
            } else i += 1;
        }
        if (ws.leaving.items.len > 0) busy = true;
        ws.root.queueAllocate();
        if (!busy) {
            ws.tick = 0;
            return 0;
        }
        return 1;
    }

    /// A card under the pointer, moved or resized directly, follows it without easing.
    fn pinned(ws: *Workspace, i: usize) bool {
        const m = ws.moving orelse return false;
        return m == i and (ws.float_resizing or (ws.move_armed and ws.panes.items[i].floating));
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
    // When the window itself changes size, cards keep up with it instead of easing behind.
    const size = [2]f64{ @floatFromInt(width), @floatFromInt(height) };
    const resized = size[0] != ws.last_size[0] or size[1] != ws.last_size[1];
    ws.last_size = size;
    var moving = false;
    for (ws.panes.items, 0..) |*p, i| {
        const target = ws.pixels(p.rect);
        if (p.fresh) {
            p.fresh = false;
            if (ws.snap or resized) {
                p.cur = target;
                p.alpha = 1;
            } else {
                // A new card grows in from a little smaller than its place.
                const inset_x = target[2] * 0.04;
                const inset_y = target[3] * 0.04;
                p.cur = .{ target[0] + inset_x, target[1] + inset_y, target[2] - 2 * inset_x, target[3] - 2 * inset_y };
                p.alpha = 0;
            }
        } else if (ws.snap or resized or ws.pinned(i)) {
            p.cur = target;
            p.vel = .{ 0, 0, 0, 0 };
            if (ws.snap) p.alpha = 1;
        }
        for (0..4) |k| if (p.cur[k] != target[k]) {
            moving = true;
        };
        if (p.alpha < 1) moving = true;
        p.frame.setOpacity(p.alpha);
        allocateAt(p.frame, p.cur);
    }
    for (ws.leaving.items) |l| {
        l.frame.setOpacity(@max(0, l.alpha));
        allocateAt(l.frame, l.cur);
    }
    ws.snap = false;
    if (moving or ws.leaving.items.len > 0) ws.startTick();
    var all: gtk.Allocation = .{ .f_x = 0, .f_y = 0, .f_width = width, .f_height = height };
    ws.overlay.sizeAllocate(&all, -1);
    if (ws.empty.getVisible() != 0) ws.empty.sizeAllocate(&all, -1);
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

fn allocateAt(w: *gtk.Widget, r: [4]f64) void {
    var a: gtk.Allocation = .{
        .f_x = @intFromFloat(@round(r[0])),
        .f_y = @intFromFloat(@round(r[1])),
        .f_width = @intFromFloat(@max(1, @round(r[2]))),
        .f_height = @intFromFloat(@max(1, @round(r[3]))),
    };
    w.sizeAllocate(&a, -1);
}

/// A minimized pane's name, as its title row would show it, such as "zsh ~/Work/bundle".
fn chipTitle(server: *Server, block_id: []const u8, out: []u8) [:0]const u8 {
    const programs = @import("programs.zig");
    const info = server.blockInfo(block_id) orelse return "Pane";
    var folder_buf: [256]u8 = undefined;
    const folder: ?[]const u8 = if (info.folder) |f| programs.shortFolder(&folder_buf, f) else null;
    const program: ?[]const u8 = if (info.program) |p| std.mem.trimStart(u8, p[0 .. std.mem.indexOfScalar(u8, p, '/') orelse p.len], "-") else null;
    const shell = if (program) |p| TermView.isShell(p) else false;
    if (!shell) if (info.title) |t| if (t.len > 0) return std.fmt.bufPrintSentinel(out, "{s}", .{t}, 0) catch "Pane";
    const p = program orelse return "Pane";
    if (folder) |f| return std.fmt.bufPrintSentinel(out, "{s} {s}", .{ p, f }, 0) catch "Pane";
    return std.fmt.bufPrintSentinel(out, "{s}", .{p}, 0) catch "Pane";
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
        const w = 150.0;
        const h = 92.0;
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
