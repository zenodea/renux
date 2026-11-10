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
const gsk = @import("gsk");
const view = @import("view.zig");
const Server = @import("server.zig").Server;
const TermView = @import("termview.zig").TermView;
const icons = @import("icons.zig");
const blockicon = @import("blockicon.zig");
const draw = @import("draw.zig");
const programs = @import("programs.zig");
const settings = @import("settings.zig");

const gpa = std.heap.c_allocator;

/// Space between pane cards; Tight packs them edge to edge with one line between.
pub var gap: f64 = 8;
pub var tight = false;
pub var show_headers = true;

/// Where the window's corner (its buttons and the sidebar toggle) ends, in window pixels. A
/// pane title under it starts after it, which is the case while the sidebar is hidden.
pub var corner_right: f64 = 0;

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
    /// "Copied", shown for a moment after the pane's selection reaches the clipboard.
    copied: *gtk.Widget,
    copied_timer: c_uint = 0,
    copied_until: i64 = 0,
    rect: view.Rect = .{},
    floating: bool = false,
    /// A floating pane's whole layer, in window fractions; its panes move and resize together.
    bounds: view.Rect = .{},
    /// Where the pane was when a drag began.
    drag_start: view.Rect = .{},
    /// One of several panes in a floating layer, drawn joined as one card.
    joined: bool = false,
    /// The program's own background, for frames that match it.
    program_bg: u32 = 0,
    /// The background the card's style class is for now, or none.
    bg_applied: ?u32 = null,
    seen: bool = false,
    /// Where the card is drawn now, in pixels, and how fast that is moving toward `rect`.
    cur: [4]f64 = .{ 0, 0, 0, 0 },
    vel: [4]f64 = .{ 0, 0, 0, 0 },
    alpha: f64 = 0,
    /// Not placed yet: it starts slightly small and clear, then grows in.
    fresh: bool = true,
};

const Backdrop = struct { layer_id: []u8, widget: *gtk.Widget };

/// A card whose pane went away, fading out where it was.
const Leaving = struct {
    frame: *gtk.Widget,
    cur: [4]f64,
    /// The size the card keeps while it fades, so its terminal never asks for a new one.
    size: [2]f64,
    alpha: f64,
    block_id: []u8,
};

const Divider = struct {
    horizontal: bool,
    rect: view.Rect,
    ratio: f64,
    before_id: []u8,
    after_id: []u8,
};

const Minimized = struct { layer_id: []u8, block_id: []u8, button: *gtk.Widget, label: *gtk.Label };

pub const Workspace = struct {
    pub fn isTight() bool {
        return tight;
    }

    bg_idle: c_uint = 0,
    /// The colors of frames that match their programs, and the text last loaded into it.
    bg_css: ?*gtk.CssProvider = null,
    bg_css_text: std.ArrayList(u8) = .empty,
    root: *gtk.Widget,
    /// While a tiled pane is carried: a small card under the pointer, and where it would land.
    ghost: *gtk.Widget,
    target: *gtk.Widget,
    swap_arrows: *gtk.Widget,
    target_cur: [4]f64 = .{ 0, 0, 0, 0 },
    target_vel: [4]f64 = .{ 0, 0, 0, 0 },
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
    /// Where a floating layer started, for moving and resizing it.
    float_start: view.Rect = .{},
    /// The ratio under the pointer while a divider is dragged; the panes follow it here at once.
    local_ratio: f64 = 0,
    float_resizing: bool = false,
    /// The card behind each floating layer of several panes, which joins them.
    backdrops: std.ArrayList(Backdrop) = .empty,

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

        // Above the cards while one is carried. They are plain widgets the GPU moves around,
        // so carrying never repaints the whole window.
        const ghost = gtk.Box.new(.horizontal, 0);
        ghost.as(gtk.Widget).addCssClass("carry-ghost");
        ghost.as(gtk.Widget).setCanTarget(0);
        ghost.as(gtk.Widget).setVisible(0);
        const target = gtk.Box.new(.horizontal, 0);
        target.as(gtk.Widget).addCssClass("drop-target");
        target.as(gtk.Widget).setCanTarget(0);
        target.as(gtk.Widget).setVisible(0);
        const arrows = gtk.DrawingArea.new();
        arrows.setContentWidth(40);
        arrows.setContentHeight(28);
        arrows.setDrawFunc(&drawSwap, null, null);
        arrows.as(gtk.Widget).setHexpand(1);
        arrows.as(gtk.Widget).setHalign(.center);
        arrows.as(gtk.Widget).setValign(.center);
        arrows.as(gtk.Widget).setVisible(0);
        target.append(arrows.as(gtk.Widget));
        const tray = gtk.Box.new(.horizontal, 6);
        tray.as(gtk.Widget).addCssClass("tray");

        // The workspace owns these, since it moves them above the cards by re-parenting.
        _ = ghost.as(gobject.Object).refSink();
        _ = target.as(gobject.Object).refSink();
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

        ws.* = .{ .root = root, .ghost = ghost.as(gtk.Widget), .target = target.as(gtk.Widget), .swap_arrows = arrows.as(gtk.Widget), .tray = tray, .empty = ew, .server = server };
        gobject.Object.setData(root.as(gobject.Object), "compy-workspace", ws);

        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Workspace, &dividerBegin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Workspace, &dividerUpdate, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Workspace, &dividerEnd, ws, .{});
        _ = gtk.Gesture.signals.cancel.connect(drag, *Workspace, &dividerCancel, ws, .{});
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
        ws.empty.setVisible(@intFromBool(window == null));
        const w = window orelse return ws.clear();
        ws.clearDividers();
        if (ws.window_id) |old| {
            if (!std.mem.eql(u8, old, w.id)) ws.snap = true;
        } else ws.snap = true;
        replace(&ws.window_id, w.id);
        if (w.focused_block_id) |f| replace(&ws.focused, f);

        for (ws.panes.items) |*p| p.seen = false;
        // A drag in progress follows its pane by block, since the list can change under it.
        const dragged: ?[*]const u8 = if (ws.moving) |m| (if (m < ws.panes.items.len) ws.panes.items[m].block_id.ptr else null) else null;
        if (w.zoomed_block_id) |z| {
            ws.place(session_id, z, "", .{}, null);
        } else if (w.tiled()) |layer| {
            if (layer.layout) |node| ws.placeNode(session_id, node, layer.id, null);
        }
        // Floating layers sit over the tiles, at their bounds; minimized ones wait in the tray.
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating or layer.minimized) continue;
            if (layer.layout) |node| ws.placeNode(session_id, node, layer.id, layer.bounds);
        };
        ws.syncTray(w);

        var i: usize = 0;
        while (i < ws.panes.items.len) {
            if (!ws.panes.items[i].seen) {
                const p = ws.panes.orderedRemove(i);
                if (ws.snap) ws.drop(p) else ws.leave(p);
            } else i += 1;
        }
        // Another window's cards must not fade out over this one.
        if (ws.snap) ws.flushLeaving();
        if (ws.moving != null) {
            ws.moving = null;
            if (dragged) |d| for (ws.panes.items, 0..) |p, k| if (p.block_id.ptr == d) {
                ws.moving = k;
            };
            if (ws.moving == null) {
                // The pane under the pointer is gone, and its carried card with it.
                ws.float_resizing = false;
                ws.move_armed = false;
                ws.zone = .none;
                ws.zone_pane = null;
                ws.showCarry();
            }
        }
        if (ws.zone_pane) |z| if (z >= ws.panes.items.len) {
            ws.zone_pane = null;
            ws.zone = .none;
        };
        ws.restack(w);
        if (ws.resizing != null) ws.followDivider();
        ws.joinLayers();
        ws.markFocus();
        ws.cornerChanged();
        ws.root.queueAllocate();
    }

    /// The top-left pane's title starts after the window's corner while the sidebar is hidden.
    pub fn cornerChanged(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            const top_left = !p.floating and p.rect.x < 0.001 and p.rect.y < 0.001;
            var room: f64 = 0;
            if (top_left) if (p.frame.getRoot()) |root| {
                var x: f64 = 0;
                var y: f64 = 0;
                // The title starts 13 pixels in: the card's border and the title's padding.
                // Only a pane whose title is level with the corner; tabs above push panes down.
                if (p.frame.translateCoordinates(root.as(gtk.Widget), 0, 0, &x, &y) != 0 and y < 30) room = @max(0, corner_right + 6 - (x + 13));
            };
            const want: c_int = @intFromFloat(@round(room));
            if (p.title_row.getMarginStart() != want) p.title_row.setMarginStart(want);
        }
    }

    /// Floating layers draw over every tiled pane, in the server's order, back to front; the
    /// drop target, the carried card and the tray stay above them all. Children only move when
    /// that order isn't already the one on screen, since moving one lays the workspace out again.
    fn restack(ws: *Workspace, w: *const view.Window) void {
        var want: std.ArrayList(*gtk.Widget) = .empty;
        defer want.deinit(gpa);
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating or layer.minimized) continue;
            for (ws.panes.items) |p| if (p.floating and std.mem.eql(u8, p.layer_id, layer.id)) want.append(gpa, p.frame) catch {};
        };
        want.appendSlice(gpa, &.{ ws.target, ws.ghost, ws.tray.as(gtk.Widget) }) catch {};
        // Compare with the children at the top, skipping the cards behind joined layers, which
        // `joinLayers` places itself.
        var child = ws.root.getLastChild();
        var k = want.items.len;
        while (k > 0) {
            const c = child orelse break;
            child = c.getPrevSibling();
            if (ws.isBackdrop(c)) continue;
            if (c != want.items[k - 1]) break;
            k -= 1;
        }
        if (k == 0) return;
        for (want.items) |x| {
            if (x.getParent() == null) x.setParent(ws.root) else x.insertBefore(ws.root, null);
        }
    }

    fn isBackdrop(ws: *Workspace, w: *gtk.Widget) bool {
        for (ws.backdrops.items) |bd| if (bd.widget == w) return true;
        return false;
    }

    /// Forgets any drag in progress, such as when the panes under it are gone.
    fn resetDrag(ws: *Workspace) void {
        ws.resizing = null;
        ws.moving = null;
        ws.move_armed = false;
        ws.float_resizing = false;
        ws.zone = .none;
        ws.zone_pane = null;
        ws.ghost.setVisible(0);
        ws.target.setVisible(0);
        ws.swap_arrows.setVisible(0);
        ws.root.setCursorFromName(null);
    }

    fn flushLeaving(ws: *Workspace) void {
        // Emptied first: `gone` asks whether a pane is shown, never whether one is leaving.
        var leaving = ws.leaving;
        ws.leaving = .empty;
        defer leaving.deinit(gpa);
        for (leaving.items) |l| ws.gone(l);
    }

    pub fn clear(ws: *Workspace) void {
        // Drag state points at panes by index, so it goes with them.
        ws.resetDrag();
        for (ws.panes.items) |p| ws.drop(p);
        ws.panes.clearRetainingCapacity();
        ws.flushLeaving();
        for (ws.backdrops.items) |bd| {
            bd.widget.unparent();
            gpa.free(bd.layer_id);
        }
        ws.backdrops.clearRetainingCapacity();
        ws.clearDividers();
        ws.clearTray();
        ws.root.queueAllocate();
    }

    /// Frees the workspace. Call it while `root` is still alive (before it leaves its parent)
    /// and while the server is: dropping the panes releases their terminals.
    pub fn destroy(ws: *Workspace) void {
        ws.clear();
        if (ws.bg_idle != 0) _ = glib.Source.remove(ws.bg_idle);
        if (ws.tick != 0) {
            ws.root.removeTickCallback(ws.tick);
            ticking -|= 1;
        }
        if (ws.bg_css) |pr| {
            if (gdk.Display.getDefault()) |d| gtk.StyleContext.removeProviderForDisplay(d, pr.as(gtk.StyleProvider));
            pr.unref();
        }
        ws.bg_css_text.deinit(gpa);
        // The layout and the gestures on `root` find the workspace through this.
        gobject.Object.setData(ws.root.as(gobject.Object), "compy-workspace", null);
        ws.empty.unparent();
        inline for (.{ ws.ghost, ws.target, ws.tray.as(gtk.Widget) }) |w| {
            if (w.getParent() != null) w.unparent();
            w.as(gobject.Object).unref();
        }
        // The gestures on `root` hold this pointer; without their widget they never fire again.
        ws.root.setCanTarget(0);
        ws.panes.deinit(gpa);
        ws.dividers.deinit(gpa);
        ws.minimized.deinit(gpa);
        ws.backdrops.deinit(gpa);
        ws.leaving.deinit(gpa);
        inline for (.{ ws.session_id, ws.window_id, ws.focused }) |slot| if (slot) |v| gpa.free(v);
        gpa.destroy(ws);
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

    /// Shows a chip for each minimized layer. Chips that are already right stay as they are,
    /// keeping their hover and their place; only a change to the set rebuilds them.
    fn syncTray(ws: *Workspace, w: *const view.Window) void {
        var same = true;
        var n: usize = 0;
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (!layer.floating or !layer.minimized or layer.blocks.len == 0) continue;
            if (n >= ws.minimized.items.len or !std.mem.eql(u8, ws.minimized.items[n].layer_id, layer.id) or !std.mem.eql(u8, ws.minimized.items[n].block_id, layer.blocks[0].id)) same = false;
            n += 1;
        };
        if (same and n == ws.minimized.items.len) {
            for (ws.minimized.items) |m| ws.refreshChip(m);
            return;
        }
        ws.clearTray();
        if (w.zoomed_block_id == null) for (w.layers) |layer| {
            if (layer.floating and layer.minimized and layer.blocks.len > 0) ws.addToTray(layer.id, layer.blocks[0].id);
        };
    }

    fn refreshChip(ws: *Workspace, m: Minimized) void {
        var buf: [256]u8 = undefined;
        const title = chipTitle(ws.server, m.block_id, &buf);
        if (!std.mem.eql(u8, std.mem.span(m.label.getText()), title)) m.label.setText(title.ptr);
    }

    /// Lets a card fade out where it was before it goes.
    fn leave(ws: *Workspace, p: Pane) void {
        if (p.copied_timer != 0) _ = glib.Source.remove(p.copied_timer);
        p.frame.setCanTarget(0);
        gpa.free(p.layer_id);
        // The terminal stays until the card has faded, so it fades with its text.
        const r = ws.paneRect(&p);
        ws.leaving.append(gpa, .{ .frame = p.frame, .cur = p.cur, .size = .{ @round(r[2]), @round(r[3]) }, .alpha = p.alpha, .block_id = p.block_id }) catch {
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
        if (p.copied_timer != 0) _ = glib.Source.remove(p.copied_timer);
        p.frame.unparent();
        ws.server.releaseTerminal(p.block_id);
        gpa.free(p.block_id);
        gpa.free(p.layer_id);
    }

    /// Places a layer's panes; `bounds` is set for a floating layer.
    fn placeNode(ws: *Workspace, session_id: []const u8, node: *const view.Node, layer_id: []const u8, bounds: ?view.Rect) void {
        switch (node.*) {
            // Leaf rectangles are already in window fractions, floating layers included.
            .leaf => |l| ws.place(session_id, l.block_id, layer_id, l.rect, bounds),
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

    fn place(ws: *Workspace, session_id: []const u8, block_id: []const u8, layer_id: []const u8, rect: view.Rect, bounds: ?view.Rect) void {
        const floating = bounds != null;
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) {
            // A floating layer being dragged here keeps its place until the server hears the drop.
            if (ws.draggingLayer(p.layer_id)) {
                p.seen = true;
                return;
            }
            p.rect = rect;
            p.bounds = bounds orelse .{};
            p.seen = true;
            replace2(&p.layer_id, layer_id);
            if (p.floating != floating) {
                p.floating = floating;
                if (floating) p.frame.addCssClass("floating") else p.frame.removeCssClass("floating");
                p.term.floating = floating;
                p.term.widget().queueDraw();
                p.grip.setVisible(@intFromBool(floating));
            }
            return;
        };
        const tv = TermView.create(ws.server, session_id, block_id) catch return;
        tv.floating = floating;
        tv.on_bg = .{ .ctx = ws, .f = programBg };
        tv.on_focus = .{ .ctx = ws, .f = clicked };
        tv.on_copied = .{ .ctx = ws, .f = showCopied };
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
            fn cancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, w: *Workspace) callconv(.c) void {
                w.moveCancel();
            }
        };
        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Workspace, &PaneDrag.begin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Workspace, &PaneDrag.update, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *Workspace, &PaneDrag.end, ws, .{});
        _ = gtk.Gesture.signals.cancel.connect(drag, *Workspace, &PaneDrag.cancel, ws, .{});
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
            fn cancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, w: *Workspace) callconv(.c) void {
                w.gripEnd();
            }
        };
        const gdrag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(gdrag, *Workspace, &GripDrag.begin, ws, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(gdrag, *Workspace, &GripDrag.update, ws, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(gdrag, *Workspace, &GripDrag.end, ws, .{});
        _ = gtk.Gesture.signals.cancel.connect(gdrag, *Workspace, &GripDrag.cancel, ws, .{});
        gw.addController(gdrag.as(gtk.EventController));
        gobject.Object.setData(gw.as(gobject.Object), "compy-block", owned.ptr);

        const frame_overlay = gtk.Overlay.new();
        frame_overlay.setChild(card.as(gtk.Widget));
        frame_overlay.addOverlay(gw);
        const copied = gtk.Label.new("Copied");
        const cw = copied.as(gtk.Widget);
        cw.addCssClass("copied-chip");
        cw.setHalign(.end);
        cw.setValign(.start);
        cw.setMarginTop(if (show_headers) 46 else 10);
        cw.setMarginEnd(14);
        cw.setCanTarget(0);
        frame_overlay.addOverlay(cw);
        const frame = frame_overlay.as(gtk.Widget);
        frame.addCssClass("pane-card");
        frame.setOverflow(.hidden);
        gobject.Object.setData(frame.as(gobject.Object), "compy-block", owned.ptr);
        // Focus follows the mouse when that's on: pointing at a pane gives it the keyboard.
        const enter = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.enter.connect(enter, *Workspace, &pointerEntered, ws, .{});
        frame.addController(enter.as(gtk.EventController));
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
            .copied = cw,
            .rect = rect,
            .floating = floating,
            .bounds = bounds orelse .{},
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
            .label = label,
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

    /// Fades "Copied" in on the pane, then out again; CSS does the easing.
    fn showCopied(ctx: *anyopaque, block_id: []const u8) void {
        const ws: *Workspace = @ptrCast(@alignCast(ctx));
        const p = ws.paneOf(block_id) orelse return;
        if (!settings.current.copy_animation) return;
        p.copied.addCssClass("shown");
        if (p.copied_timer != 0) _ = glib.Source.remove(p.copied_timer);
        const Hide = struct {
            fn run(data: ?*anyopaque) callconv(.c) c_int {
                const w: *Workspace = @ptrCast(@alignCast(data.?));
                // Only the pane whose timer this is: another pane's stays its own to remove, or
                // it would be left running after its pane, and the workspace, are gone.
                const id = if (glib.mainCurrentSource()) |source| source.getId() else 0;
                for (w.panes.items) |*q| if (q.copied_timer != 0 and q.copied_timer == id) {
                    q.copied.removeCssClass("shown");
                    q.copied_timer = 0;
                };
                return 0;
            }
        };
        p.copied_until = glib.getMonotonicTime() + 900_000;
        p.copied_timer = glib.timeoutAdd(900, &Hide.run, ws);
    }

    fn markFocus(ws: *Workspace) void {
        for (ws.panes.items) |p| {
            const on = if (ws.focused) |f| std.mem.eql(u8, f, p.block_id) else false;
            if (on) p.frame.addCssClass("focused") else p.frame.removeCssClass("focused");
            if (p.term.active_pane != on) {
                p.term.active_pane = on;
                p.term.widget().queueDraw();
            }
        }
        ws.markBackdropFocus();
    }

    /// The card behind a joined layer is lit while one of its panes has the focus.
    fn markBackdropFocus(ws: *Workspace) void {
        const layer: ?[]const u8 = if (ws.focused) |f| (if (ws.paneOf(f)) |p| p.layer_id else null) else null;
        for (ws.backdrops.items) |bd| {
            const on = if (layer) |l| std.mem.eql(u8, l, bd.layer_id) else false;
            if (on) bd.widget.addCssClass("focused") else bd.widget.removeCssClass("focused");
        }
    }

    pub fn paneOf(ws: *Workspace, block_id: []const u8) ?*Pane {
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) return p;
        return null;
    }

    /// The pane next to the focused one in a direction (left, right, up or down): the nearest
    /// one beside it, preferring the one that overlaps it most.
    pub fn neighbor(ws: *Workspace, direction: []const u8) ?[]const u8 {
        const cur = ws.paneOf(ws.focused orelse return null) orelse return null;
        const c = cur.rect;
        const eps = 0.001;
        var best: ?[]const u8 = null;
        var best_dist: f64 = std.math.inf(f64);
        var best_overlap: f64 = -1;
        for (ws.panes.items) |p| {
            if (p.floating != cur.floating or std.mem.eql(u8, p.block_id, cur.block_id)) continue;
            const r = p.rect;
            const horizontal = std.mem.eql(u8, direction, "left") or std.mem.eql(u8, direction, "right");
            const dist = if (std.mem.eql(u8, direction, "left")) c.x - (r.x + r.w) else if (std.mem.eql(u8, direction, "right")) r.x - (c.x + c.w) else if (std.mem.eql(u8, direction, "up")) c.y - (r.y + r.h) else r.y - (c.y + c.h);
            if (dist < -eps) continue;
            const overlap = if (horizontal) @min(c.y + c.h, r.y + r.h) - @max(c.y, r.y) else @min(c.x + c.w, r.x + r.w) - @max(c.x, r.x);
            if (overlap <= eps) continue;
            if (dist < best_dist - eps or (@abs(dist - best_dist) <= eps and overlap > best_overlap)) {
                best = p.block_id;
                best_dist = dist;
                best_overlap = overlap;
            }
        }
        return best;
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

    fn fromWidget(w: *gtk.Widget) ?*Workspace {
        return @ptrCast(@alignCast(gobject.Object.getData(w.as(gobject.Object), "compy-workspace") orelse return null));
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
        return ws.pixelsGap(r, gap);
    }

    fn pixelsGap(ws: *Workspace, r: view.Rect, g: f64) [4]f64 {
        const w = ws.width();
        const h = ws.height();
        const x0 = r.x * (w + g);
        const y0 = r.y * (h + g);
        return .{ x0, y0, (r.x + r.w) * (w + g) - g - x0, (r.y + r.h) * (h + g) - g - y0 };
    }

    /// Where a pane's card goes: joined panes keep one line between them.
    fn paneRect(ws: *Workspace, p: *const Pane) [4]f64 {
        return ws.pixelsGap(p.rect, if (p.joined) 1 else gap);
    }

    /// Marks the panes of each floating layer of several as joined, with rounded corners only
    /// where the layer's are, and puts one card behind them.
    fn joinLayers(ws: *Workspace) void {
        var keep: std.ArrayList([]const u8) = .empty;
        defer keep.deinit(gpa);
        for (ws.panes.items) |*p| {
            var n: usize = 0;
            if (p.floating) for (ws.panes.items) |q| {
                if (q.floating and std.mem.eql(u8, q.layer_id, p.layer_id)) n += 1;
            };
            p.joined = n > 1;
            // The layer's outer edges, from its panes: the server's bounds can differ slightly.
            var b = p.rect;
            if (p.floating) for (ws.panes.items) |q| {
                if (!q.floating or !std.mem.eql(u8, q.layer_id, p.layer_id)) continue;
                const x1 = @max(b.x + b.w, q.rect.x + q.rect.w);
                const y1 = @max(b.y + b.h, q.rect.y + q.rect.h);
                b.x = @min(b.x, q.rect.x);
                b.y = @min(b.y, q.rect.y);
                b.w = x1 - b.x;
                b.h = y1 - b.y;
            };
            const eps = 0.01;
            const l = @abs(p.rect.x - b.x) < eps;
            const t = @abs(p.rect.y - b.y) < eps;
            const r = @abs(p.rect.x + p.rect.w - (b.x + b.w)) < eps;
            const bt = @abs(p.rect.y + p.rect.h - (b.y + b.h)) < eps;
            inline for (.{ .{ "joined", p.joined }, .{ "c-tl", p.joined and l and t }, .{ "c-tr", p.joined and r and t }, .{ "c-bl", p.joined and l and bt }, .{ "c-br", p.joined and r and bt } }) |e| {
                if (e[1]) p.frame.addCssClass(e[0]) else p.frame.removeCssClass(e[0]);
            }
            // One resize corner for the whole layer.
            p.grip.setVisible(@intFromBool(p.floating and (!p.joined or (r and bt))));
            if (p.joined) {
                var seen = false;
                for (keep.items) |k| if (std.mem.eql(u8, k, p.layer_id)) {
                    seen = true;
                };
                if (!seen) keep.append(gpa, p.layer_id) catch {};
            }
        }
        // Drop the cards of layers that are gone or down to one pane, then add the new ones.
        var i: usize = 0;
        while (i < ws.backdrops.items.len) {
            const bd = ws.backdrops.items[i];
            var wanted = false;
            for (keep.items) |k| if (std.mem.eql(u8, k, bd.layer_id)) {
                wanted = true;
            };
            if (wanted) {
                i += 1;
                continue;
            }
            bd.widget.unparent();
            gpa.free(bd.layer_id);
            _ = ws.backdrops.orderedRemove(i);
        }
        for (keep.items) |k| {
            var have = false;
            for (ws.backdrops.items) |bd| if (std.mem.eql(u8, bd.layer_id, k)) {
                have = true;
            };
            if (have) continue;
            const card = gtk.Box.new(.horizontal, 0);
            card.as(gtk.Widget).addCssClass("layer-card");
            card.as(gtk.Widget).setCanTarget(0);
            card.as(gtk.Widget).setParent(ws.root);
            ws.backdrops.append(gpa, .{ .layer_id = gpa.dupe(u8, k) catch continue, .widget = card.as(gtk.Widget) }) catch {};
        }
        // Each card sits just under its layer's first pane.
        for (ws.backdrops.items) |bd| {
            var child = ws.root.getFirstChild();
            while (child) |c| : (child = c.getNextSibling()) {
                if (c == bd.widget) continue;
                const is_layer = for (ws.panes.items) |p| {
                    if (p.frame == c) break std.mem.eql(u8, p.layer_id, bd.layer_id);
                } else false;
                if (is_layer) {
                    if (c.getPrevSibling() != bd.widget) bd.widget.insertBefore(ws.root, c);
                    break;
                }
            }
        }
        ws.markBackdropFocus();
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
        ws.local_ratio = ws.dividers.items[ws.resizing.?].ratio;
        for (ws.panes.items) |*p| p.drag_start = p.rect;
    }

    /// Lays the panes out for the ratio under the pointer straight away, from where they were when
    /// the drag began, without waiting for the server's answer.
    fn followDivider(ws: *Workspace) void {
        const i = ws.resizing orelse return;
        if (i >= ws.dividers.items.len) return;
        const d = ws.dividers.items[i];
        const eps = 0.0005;
        const start = if (d.horizontal) d.rect.x else d.rect.y;
        const size = if (d.horizontal) d.rect.w else d.rect.h;
        const old_at = start + size * d.ratio;
        const new_at = start + size * ws.local_ratio;
        for (ws.panes.items) |*p| {
            if (p.floating) continue;
            const r = p.drag_start;
            if (r.x < d.rect.x - eps or r.y < d.rect.y - eps or r.x + r.w > d.rect.x + d.rect.w + eps or r.y + r.h > d.rect.y + d.rect.h + eps) continue;
            const pos = if (d.horizontal) r.x else r.y;
            const len = if (d.horizontal) r.w else r.h;
            var np: f64 = 0;
            var nl: f64 = 0;
            if (pos + len <= old_at + eps) {
                const k = (new_at - start) / @max(old_at - start, eps);
                np = start + (pos - start) * k;
                nl = len * k;
            } else {
                const end = start + size;
                const k = (end - new_at) / @max(end - old_at, eps);
                np = new_at + (pos - old_at) * k;
                nl = len * k;
            }
            if (d.horizontal) {
                p.rect.x = np;
                p.rect.w = nl;
            } else {
                p.rect.y = np;
                p.rect.h = nl;
            }
        }
        ws.root.queueAllocate();
    }

    fn sendDivider(ws: *Workspace, dx: f64, dy: f64, force: bool) void {
        const i = ws.resizing orelse return;
        if (i >= ws.dividers.items.len) return;
        const d = &ws.dividers.items[i];
        const w = ws.width();
        const h = ws.height();
        // The ratio under the pointer, within the split's own rectangle.
        const ratio = if (d.horizontal)
            ((ws.move_origin[0] + dx + gap / 2) / (w + gap) - d.rect.x) / d.rect.w
        else
            ((ws.move_origin[1] + dy + gap / 2) / (h + gap) - d.rect.y) / d.rect.h;
        ws.local_ratio = std.math.clamp(ratio, 0.05, 0.95);
        ws.followDivider();
        // Each change makes programs redraw, so send at most every 60 ms while dragging.
        const now = glib.getMonotonicTime();
        if (!force and now - ws.last_resize < 60_000) return;
        ws.last_resize = now;
        if (ws.session_id) |s| ws.server.resizePane(s, d.horizontal, d.before_id, d.after_id, ws.local_ratio);
    }

    fn dividerUpdate(_: *gtk.GestureDrag, dx: f64, dy: f64, ws: *Workspace) callconv(.c) void {
        ws.sendDivider(dx, dy, false);
    }

    fn dividerEnd(_: *gtk.GestureDrag, dx: f64, dy: f64, ws: *Workspace) callconv(.c) void {
        if (ws.resizing == null) return;
        ws.sendDivider(dx, dy, true);
        ws.resizing = null;
    }

    /// The drag was taken away (a dialog opened, the compositor took the pointer) and no end
    /// follows. The split stays where it was let go, and the server hears that ratio.
    fn dividerCancel(_: *gtk.GestureDrag, _: ?*gdk.EventSequence, ws: *Workspace) callconv(.c) void {
        const i = ws.resizing orelse return;
        ws.resizing = null;
        if (i >= ws.dividers.items.len) return;
        const d = ws.dividers.items[i];
        if (ws.session_id) |s| ws.server.resizePane(s, d.horizontal, d.before_id, d.after_id, ws.local_ratio);
        ws.root.queueAllocate();
    }

    // Carrying a pane by its title.

    fn pointerEntered(ctl: *gtk.EventControllerMotion, _: f64, _: f64, ws: *Workspace) callconv(.c) void {
        if (!settings.current.focus_follows_mouse) return;
        if (ws.moving != null or ws.resizing != null) return;
        const w = ctl.as(gtk.EventController).getWidget() orelse return;
        const i = ws.paneOfWidget(w) orelse return;
        const p = ws.panes.items[i];
        if (ws.focused) |f| if (std.mem.eql(u8, f, p.block_id)) return;
        ws.focus(p.block_id);
        _ = p.term.widget().grabFocus();
    }

    /// A program changed its background; with frames matching programs, the card follows it.
    fn programBg(ctx: *anyopaque, block_id: []const u8, bg: u32) void {
        const ws: *Workspace = @ptrCast(@alignCast(ctx));
        var wanted = false;
        for (ws.panes.items) |*p| if (std.mem.eql(u8, p.block_id, block_id)) {
            p.program_bg = bg;
            if (!std.meta.eql(p.bg_applied, wantedBg(p))) wanted = true;
        };
        // Styles can't change while drawing, so this waits for the next idle moment. Nothing
        // waits at all when no card would change, which is always so with the setting off.
        if (wanted and ws.bg_idle == 0) ws.bg_idle = glib.idleAdd(&applyProgramBgs, ws);
    }

    fn applyProgramBgs(data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        ws.bg_idle = 0;
        ws.refreshProgramBgs();
        return 0;
    }

    /// The background a card should take from its program, or none.
    fn wantedBg(p: *const Pane) ?u32 {
        if (!settings.current.match_program_bg or p.program_bg == 0) return null;
        return p.program_bg & 0xffffff;
    }

    /// Gives each card the style class of its program's background, named after the color, and
    /// loads the rules for the colors in use. Nothing is touched when nothing changed.
    pub fn refreshProgramBgs(ws: *Workspace) void {
        var css: std.ArrayList(u8) = .empty;
        defer css.deinit(gpa);
        for (ws.panes.items, 0..) |*p, i| {
            const want = wantedBg(p);
            if (!std.meta.eql(p.bg_applied, want)) {
                var old_buf: [16]u8 = undefined;
                if (p.bg_applied) |old| p.frame.removeCssClass(bgClass(&old_buf, old).ptr);
                if (want) |c| p.frame.addCssClass(bgClass(&old_buf, c).ptr);
                p.bg_applied = want;
            }
            const c = want orelse continue;
            // One rule per color, however many panes share it.
            const listed = for (ws.panes.items[0..i]) |q| {
                if (q.bg_applied) |qc| if (qc == c) break true;
            } else false;
            if (listed) continue;
            var name_buf: [16]u8 = undefined;
            const name = bgClass(&name_buf, c);
            css.print(gpa, ".pane-card.{s}, .pane-card.{s} .pane-title {{ background-color: #{x:0>6}; }}\n", .{ name, name, c }) catch {};
        }
        if (std.mem.eql(u8, css.items, ws.bg_css_text.items)) return;
        ws.bg_css_text.clearRetainingCapacity();
        ws.bg_css_text.appendSlice(gpa, css.items) catch {};
        css.append(gpa, 0) catch return;
        const provider = ws.bg_css orelse blk: {
            const display = gdk.Display.getDefault() orelse return;
            const pr = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(display, pr.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
            ws.bg_css = pr;
            break :blk pr;
        };
        provider.loadFromString(@ptrCast(css.items.ptr));
    }

    fn bgClass(buf: *[16]u8, color: u32) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "pbg-{x:0>6}", .{color & 0xffffff}, 0) catch "pbg";
    }

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
        ws.startLayerDrag(i);
        clicked(ws, ws.panes.items[i].block_id);
    }

    fn moveUpdate(ws: *Workspace, dx: f64, dy: f64) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing or i >= ws.panes.items.len) return;
        if (!ws.move_armed and @abs(dx) < 6 and @abs(dy) < 6) return;
        ws.move_armed = true;
        ws.pointer = .{ ws.move_origin[0] + dx, ws.move_origin[1] + dy };
        const p = &ws.panes.items[i];
        if (p.floating) {
            // A floating layer follows the pointer, all its panes together; the server hears
            // where it lands.
            var b = ws.float_start;
            b.x = view.clampWithin(b.x + dx / @max(ws.width(), 1), 0, 1 - b.w);
            b.y = view.clampWithin(b.y + dy / @max(ws.height(), 1), 0, 1 - b.h);
            ws.setLayerBounds(i, b);
            return;
        }
        ws.updateZone();
        ws.showCarry();
    }

    /// Notes where a pane's floating layer and its panes are as a drag begins.
    fn startLayerDrag(ws: *Workspace, i: usize) void {
        const p = ws.panes.items[i];
        ws.float_start = if (p.bounds.w > 0) p.bounds else p.rect;
        for (ws.panes.items) |*q| if (std.mem.eql(u8, q.layer_id, p.layer_id)) {
            q.drag_start = q.rect;
        };
    }

    /// Moves or resizes a pane's floating layer, scaling each of its panes with it.
    fn setLayerBounds(ws: *Workspace, i: usize, b: view.Rect) void {
        const sb = ws.float_start;
        const layer = ws.panes.items[i].layer_id;
        const sx = b.w / @max(sb.w, 0.0001);
        const sy = b.h / @max(sb.h, 0.0001);
        for (ws.panes.items) |*q| if (std.mem.eql(u8, q.layer_id, layer)) {
            const r = q.drag_start;
            q.rect = .{ .x = b.x + (r.x - sb.x) * sx, .y = b.y + (r.y - sb.y) * sy, .w = r.w * sx, .h = r.h * sy };
            q.bounds = b;
        };
        ws.root.queueAllocate();
    }

    /// Whether this floating layer is under the pointer being moved or resized.
    fn draggingLayer(ws: *Workspace, layer_id: []const u8) bool {
        const m = ws.moving orelse return false;
        if (m >= ws.panes.items.len) return false;
        const p = ws.panes.items[m];
        if (!p.floating or !(ws.float_resizing or ws.move_armed)) return false;
        return std.mem.eql(u8, p.layer_id, layer_id);
    }

    /// Shows the carried card under the pointer and where it would land.
    fn showCarry(ws: *Workspace) void {
        const carrying = if (ws.moving) |i| i < ws.panes.items.len and ws.move_armed and !ws.panes.items[i].floating else false;
        ws.ghost.setVisible(@intFromBool(carrying));
        const shown = carrying and ws.zone_pane != null;
        if (shown and ws.target.getVisible() == 0) {
            // It appears where it belongs, then glides between targets.
            ws.target_cur = ws.targetRect();
            ws.target_vel = .{ 0, 0, 0, 0 };
        }
        ws.target.setVisible(@intFromBool(shown));
        ws.swap_arrows.setVisible(@intFromBool(shown and ws.zone == .swap));
        ws.root.queueAllocate();
        if (shown) ws.startTick();
    }

    /// Where the carried pane would land, in pixels.
    fn targetRect(ws: *Workspace) [4]f64 {
        const t = ws.zone_pane orelse return .{ 0, 0, 0, 0 };
        if (t >= ws.panes.items.len) return .{ 0, 0, 0, 0 };
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
        return .{ x + 4, y + 4, w - 8, h - 8 };
    }

    fn moveEnd(ws: *Workspace) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing) return;
        defer {
            ws.moving = null;
            ws.zone = .none;
            ws.zone_pane = null;
            ws.showCarry();
        }
        if (!ws.move_armed) return;
        const sid = ws.session_id orelse return;
        if (i >= ws.panes.items.len) return;
        const p = ws.panes.items[i];
        if (p.floating) return ws.server.resizeLayer(sid, p.layer_id, p.bounds);
        const t = ws.zone_pane orelse return;
        if (t >= ws.panes.items.len) return;
        switch (ws.zone) {
            .none => {},
            .swap => ws.server.swapBlocks(sid, p.block_id, ws.panes.items[t].block_id),
            .left, .right, .top, .bottom => ws.server.moveBlock(
                sid,
                p.block_id,
                ws.panes.items[t].block_id,
                ws.zone == .left or ws.zone == .right,
                ws.zone == .left or ws.zone == .top,
            ),
        }
    }

    /// The drag was taken away and no end follows. A floating layer stays where it was let go
    /// and the server hears that; a carried pane is put down where it came from.
    fn moveCancel(ws: *Workspace) void {
        const i = ws.moving orelse return;
        if (ws.float_resizing) return;
        if (i < ws.panes.items.len and ws.panes.items[i].floating) return ws.moveEnd();
        ws.moving = null;
        ws.zone = .none;
        ws.zone_pane = null;
        ws.showCarry();
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
        ticking += 1;
    }

    fn onTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const ws: *Workspace = @ptrCast(@alignCast(data.?));
        const now = clock.getFrameTime();
        const dt: f64 = if (ws.last_time == 0) 1.0 / 60.0 else std.math.clamp(@as(f64, @floatFromInt(now - ws.last_time)) / 1e6, 0, 0.05);
        ws.last_time = now;
        const decay = @exp(-spring * dt);
        var busy = false;
        for (ws.panes.items, 0..) |*p, i| {
            // A card under the pointer is placed directly, but still fades in if it is new.
            const still = ws.pinned(i) or springStep(&p.cur, &p.vel, ws.paneRect(p), dt, decay);
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
        if (ws.target.getVisible() != 0 and !springStep(&ws.target_cur, &ws.target_vel, ws.targetRect(), dt, decay)) busy = true;
        ws.root.queueAllocate();
        if (!busy) {
            ws.tick = 0;
            ticking -|= 1;
            return 0;
        }
        return 1;
    }

    fn springStep(cur: *[4]f64, vel: *[4]f64, target: [4]f64, dt: f64, decay: f64) bool {
        var still = true;
        for (0..4) |k| {
            const d = cur[k] - target[k];
            const v = vel[k];
            const nd = (d + (v + spring * d) * dt) * decay;
            vel[k] = (v - spring * (v + spring * d) * dt) * decay;
            cur[k] = target[k] + nd;
            if (@abs(nd) > 0.4 or @abs(vel[k]) > 4) still = false;
        }
        if (still) {
            cur.* = target;
            vel.* = .{ 0, 0, 0, 0 };
        }
        return still;
    }

    /// A card under the pointer, moved or resized directly, follows it without easing.
    fn pinned(ws: *Workspace, i: usize) bool {
        if (ws.resizing != null) return !ws.panes.items[i].floating;
        return ws.draggingLayer(ws.panes.items[i].layer_id);
    }

    // For the development script: drive the same paths a pointer would.

    pub fn simulateCarry(ws: *Workspace, block_id: []const u8, x: f64, y: f64) void {
        const i = ws.indexOf(block_id) orelse return;
        const r = ws.pixels(ws.panes.items[i].rect);
        ws.moving = i;
        ws.move_armed = false;
        ws.move_origin = .{ r[0] + 40, r[1] + 16 };
        ws.startLayerDrag(i);
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
        ws.startLayerDrag(i);
    }

    fn gripUpdate(ws: *Workspace, dx: f64, dy: f64) void {
        if (!ws.float_resizing) return;
        const i = ws.moving orelse return;
        if (i >= ws.panes.items.len) return;
        var b = ws.float_start;
        b.w = view.clampWithin(b.w + dx / @max(ws.width(), 1), 0.15, 1 - b.x);
        b.h = view.clampWithin(b.h + dy / @max(ws.height(), 1), 0.15, 1 - b.y);
        ws.setLayerBounds(i, b);
    }

    /// Also where a cancelled resize ends, so it does nothing unless one is under way.
    fn gripEnd(ws: *Workspace) void {
        if (!ws.float_resizing) return;
        ws.float_resizing = false;
        const i = ws.moving orelse return;
        ws.moving = null;
        if (i >= ws.panes.items.len) return;
        const p = ws.panes.items[i];
        if (ws.session_id) |s| ws.server.resizeLayer(s, p.layer_id, p.bounds);
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
    const ws = Workspace.fromWidget(widget) orelse return;
    // When the window itself changes size, cards keep up with it instead of easing behind.
    const size = [2]f64{ @floatFromInt(width), @floatFromInt(height) };
    const resized = size[0] != ws.last_size[0] or size[1] != ws.last_size[1];
    ws.last_size = size;
    var moving = false;
    for (ws.panes.items, 0..) |*p, i| {
        const target = ws.paneRect(p);
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
        // A leaving card keeps its size, so its terminal never asks the server for a new one.
        allocateAt(l.frame, .{ l.cur[0] + (l.cur[2] - l.size[0]) / 2, l.cur[1] + (l.cur[3] - l.size[1]) / 2, l.size[0], l.size[1] });
    }
    // A joined layer's card wraps its panes where they are drawn now, a pixel outside them.
    for (ws.backdrops.items) |bd| {
        var lo = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
        var hi = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
        var alpha: f64 = 0;
        for (ws.panes.items) |p| if (std.mem.eql(u8, p.layer_id, bd.layer_id)) {
            lo = .{ @min(lo[0], p.cur[0]), @min(lo[1], p.cur[1]) };
            hi = .{ @max(hi[0], p.cur[0] + p.cur[2]), @max(hi[1], p.cur[1] + p.cur[3]) };
            alpha = @max(alpha, p.alpha);
        };
        if (lo[0] > hi[0]) continue;
        bd.widget.setOpacity(alpha);
        var a: gtk.Allocation = .{
            .f_x = @intFromFloat(@round(lo[0] - 1)),
            .f_y = @intFromFloat(@round(lo[1] - 1)),
            .f_width = @intFromFloat(@max(1, @round(hi[0] - lo[0] + 2))),
            .f_height = @intFromFloat(@max(1, @round(hi[1] - lo[1] + 2))),
        };
        bd.widget.sizeAllocate(&a, -1);
    }
    if (ws.target.getVisible() != 0) allocateAt(ws.target, ws.target_cur);
    if (ws.ghost.getVisible() != 0) allocateAt(ws.ghost, .{ ws.pointer[0] - 75, ws.pointer[1] - 46, 150, 92 });
    ws.snap = false;
    if (moving or ws.leaving.items.len > 0) ws.startTick();
    var all: gtk.Allocation = .{ .f_x = 0, .f_y = 0, .f_width = width, .f_height = height };
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

/// How many workspaces are animating, for COMPY_PERF.
pub var ticking: u32 = 0;

/// Places a card at its animated rect. The card takes that size rather than being scaled: scaling
/// makes the GPU redraw every glyph at a new size each frame, which cost 6 to 300 ms a frame.
/// The terminal inside keeps its grid until the size settles, since resizes are debounced.
fn allocateAt(w: *gtk.Widget, r: [4]f64) void {
    const cw: c_int = @intFromFloat(@max(1, @round(r[2])));
    const ch: c_int = @intFromFloat(@max(1, @round(r[3])));
    const fx = @round(r[0]);
    const fy = @round(r[1]);
    if (@abs(r[0] - fx) < 0.01 and @abs(r[1] - fy) < 0.01) {
        var a: gtk.Allocation = .{ .f_x = @intFromFloat(fx), .f_y = @intFromFloat(fy), .f_width = cw, .f_height = ch };
        w.sizeAllocate(&a, -1);
        return;
    }
    // Moving by fractions of a pixel keeps slow glides smooth on HiDPI screens.
    const t = gsk.Transform.new().translate(&.{ .f_x = @floatCast(r[0]), .f_y = @floatCast(r[1]) }) orelse return;
    w.allocate(cw, ch, -1, t);
}

/// Two arrows passing each other, on a drop target that swaps.
fn drawSwap(area: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, _: ?*anyopaque) callconv(.c) void {
    var ink: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&ink);
    setRgba(cr, ink, 0.9);
    const cx = @as(f64, @floatFromInt(w)) / 2;
    const cy = @as(f64, @floatFromInt(h)) / 2;
    cr.setLineWidth(2);
    cr.setLineCap(.round);
    cr.setLineJoin(.round);
    cr.moveTo(cx - 14, cy - 5);
    cr.lineTo(cx + 14, cy - 5);
    cr.lineTo(cx + 8, cy - 11);
    cr.moveTo(cx + 14, cy + 5);
    cr.lineTo(cx - 14, cy + 5);
    cr.lineTo(cx - 8, cy + 11);
    cr.stroke();
}

/// A minimized pane's name, as its title row would show it, such as "zsh ~/Work/bundle".
fn chipTitle(server: *Server, block_id: []const u8, out: *[256]u8) [:0]const u8 {
    const info = server.blockInfo(block_id) orelse return "Pane";
    const program = info.program orelse "";
    // Anything but a shell goes by the title it set.
    if (!TermView.isShell(programs.programName(program))) if (info.title) |t| if (t.len > 0) return std.fmt.bufPrintSentinel(out, "{s}", .{t}, 0) catch "Pane";
    if (info.program == null) return "Pane";
    var buf: [255]u8 = undefined;
    return std.fmt.bufPrintSentinel(out, "{s}", .{programs.displayTitle(&buf, program, info.folder)}, 0) catch "Pane";
}

const setRgba = draw.setRgba;

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
