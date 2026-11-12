//! The overview: every tab of every session at once, each drawn as its real panes, small, in a
//! grid. Opening it zooms out from the tab on screen to its place in the grid, and picking a
//! tab zooms into it.
//!
//! Each tab in the grid is a workspace of its own, a preview, which shows that tab's panes
//! live. Previews are costly to make and to draw for the first time, so none of that happens
//! while anything moves: the zoom out moves one picture, of the tab that was on screen, to
//! its place among the others, which show the pictures taken of them the last time the
//! overview was open, or plain cards. Once the grid is still the previews are made, one a
//! frame, and take over from the pictures. The zoom in moves pictures too: text drawn at a
//! new size every frame has every glyph made again each time, which is slow.
//!
//! A tab with agents in it carries a small dot for each in its top right corner, in the color
//! of what that agent is doing, so the grid can be watched in place of the panes.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");
const gsk = @import("gsk");
const graphene = @import("graphene");
const app_mod = @import("../app/app.zig");
const view = @import("../rex/view.zig");
const workspace_mod = @import("workspace.zig");
const Workspace = workspace_mod.Workspace;
const K = @import("../terminal/keys.zig");
const programs = @import("../icons/programs.zig");

const gpa = std.heap.c_allocator;

/// Room around the grid, between its tabs, under each tab for its name, and at the bottom.
const pad: f64 = 36;
const gap: f64 = 28;
const name_room: f64 = 30;
const bottom_room: f64 = 64;
const zoom_ms: f64 = 300;
/// How far the ring stands off the tab it is around.
const ring_gap: f64 = 4;
/// The most pictures of tabs kept between one opening of the overview and the next.
const max_thumbs = 40;

/// The one overview, for `previewShows`.
var current: ?*Overview = null;

/// Whether a preview shows a pane; the window then leaves the pane's terminal running when it
/// stops showing the pane itself.
fn previewShows(server: *@import("../rex/server.zig").Server, block_id: []const u8) bool {
    const o = current orelse return false;
    for (o.tiles.items) |t| if (t.ws) |ws| {
        if (t.host.server == server and ws.isShown(block_id)) return true;
    };
    return false;
}

const Tile = struct {
    host: *app_mod.Host,
    session_id: []u8,
    window_id: []u8,
    label: *gtk.Label,
    /// The host's name in the tab's top left corner, for a tab on another computer.
    host_chip: *gtk.Label,
    /// One dot for each agent in the tab, in its top right corner, and what they were made
    /// from, so they are made again only when an agent's state changes.
    badges: *gtk.Box,
    badges_for: u64 = 0,
    /// A plain card in the tab's place, shown until there is a picture or a preview of it.
    blank: *gtk.Widget,
    /// The live copy of the tab, made once the grid is still.
    ws: ?*Workspace = null,
    root: ?*gtk.Widget = null,
    /// Whether the preview has been given its place and size, and so can be drawn.
    placed: bool = false,
    /// Its place in the grid.
    rect: [4]f64 = .{ 0, 0, 0, 0 },
    /// A picture of the tab's panes at about the size they have in the grid: the one taken
    /// when the overview last closed, until a newer one is.
    picture: ?*gdk.Texture = null,
    /// For the tab the zoom goes into or comes out of: a picture as sharp as the screen.
    sharp: ?*gdk.Texture = null,
};

pub const Overview = struct {
    app: *app_mod.App,
    area: *Area,
    ring: *gtk.Widget,
    button: *gtk.Button,
    tiles: std.ArrayList(Tile) = .empty,
    /// Tabs of an overview that has closed, freed once its last frame is out.
    dead: std.ArrayList(Tile) = .empty,
    reap_idle: c_uint = 0,
    /// The last picture taken of each tab, by its window's ID, for the next time it opens.
    thumbs: std.StringHashMapUnmanaged(*gdk.Texture) = .empty,
    open: bool = false,
    /// The tab the ring is on, and the one the zoom comes out of or goes into.
    selected: usize = 0,
    focus: usize = 0,
    /// How far out the view is: 0 with the focus tab filling the window, 1 at the whole grid.
    zoom: f64 = 1,
    from: f64 = 1,
    to: f64 = 1,
    started: i64 = 0,
    /// The zoom is running. The tick goes on after it, while previews are still to be made.
    animating: bool = false,
    tick: c_uint = 0,
    size: [2]f64 = .{ 0, 0 },
    /// The part of a tab's place its panes cover, as shares of that place: all of it but the
    /// margins the panes have in the window.
    content: [4]f64 = .{ 0, 0, 1, 1 },
    /// Where the pointer last was, so a still pointer doesn't steal the ring from the keys.
    pointer: [2]f64 = .{ -1, -1 },

    pub fn create(a: *app_mod.App) *Overview {
        const o = gpa.create(Overview) catch @panic("out of memory");
        const area = Area.new();
        const w = area.as(gtk.Widget);
        w.setVisible(0);
        w.setOverflow(.hidden);
        const ring = gtk.Box.new(.horizontal, 0);
        ring.as(gtk.Widget).addCssClass("overview-ring");
        ring.as(gtk.Widget).setCanTarget(0);
        ring.as(gtk.Widget).setParent(w);
        const button = gtk.Button.newWithLabel("Full screen");
        button.as(gtk.Widget).addCssClass("pill");
        button.as(gtk.Widget).addCssClass("overview-button");
        button.as(gtk.Widget).setFocusable(0);
        button.as(gtk.Actionable).setActionName("app.full-screen");
        button.as(gtk.Widget).setParent(w);
        o.* = .{ .app = a, .area = area, .ring = ring.as(gtk.Widget), .button = button };
        area.overview = o;
        current = o;
        workspace_mod.previewed = &previewShows;

        const click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.released.connect(click, *Overview, &clicked, o, .{});
        w.addController(click.as(gtk.EventController));
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *Overview, &moved, o, .{});
        w.addController(motion.as(gtk.EventController));
        return o;
    }

    pub fn widget(o: *Overview) *gtk.Widget {
        return o.area.as(gtk.Widget);
    }

    pub fn shown(o: *Overview) bool {
        return o.open;
    }

    pub fn toggle(o: *Overview) void {
        if (o.open) o.close() else o.show();
    }

    /// Opens the overview, zooming out from the tab on screen.
    pub fn show(o: *Overview) void {
        if (o.open) return;
        const a = o.app;
        a.showBoard(false);
        o.open = true;
        const stack = a.stack.as(gtk.Widget);
        // The grid is worked out now, from the room the panes have, so the zoom starts on the
        // very next frame instead of after the first layout.
        o.size = .{ @floatFromInt(stack.getWidth()), @floatFromInt(stack.getHeight()) };
        o.measureContent();
        // The tab on screen, as it is drawn now: the one picture the zoom out moves.
        const sharp: ?*gdk.Texture = if (a.workspace) |main| o.shoot(main.root, o.screenScale()) else null;
        o.widget().setVisible(1);
        o.sync();
        if (o.tiles.items.len == 0) {
            if (sharp) |p| p.unref();
            o.hideNow();
            a.toast("No tabs to show");
            return;
        }
        // The panes themselves are hidden while their small copies stand in for them.
        stack.setOpacity(0);
        o.bareChanged();
        o.pointer = .{ -1, -1 };
        const here = o.shownIndex();
        o.selected = here orelse 0;
        o.focus = o.selected;
        o.computeRects();
        o.zoom = 1;
        o.animating = false;
        if (sharp) |p| {
            if (here) |i| {
                o.tiles.items[i].sharp = p;
                o.zoom = 0;
                o.from = 0;
                o.to = 1;
                o.started = 0;
                o.animating = true;
            } else p.unref();
        }
        o.startTick();
        o.widget().queueAllocate();
    }

    /// Measures which part of a tab's place its panes cover, from the window's own panes: the
    /// margins they keep there change with the pane style and with full screen mode.
    fn measureContent(o: *Overview) void {
        const main = o.app.workspace orelse return;
        var full: graphene.Rect = undefined;
        if (o.size[0] < 1 or o.size[1] < 1) return;
        if (main.root.computeBounds(o.app.stack.as(gtk.Widget), &full) == 0 or full.f_size.f_width < 1) return;
        o.content = .{ full.f_origin.f_x / o.size[0], full.f_origin.f_y / o.size[1], full.f_size.f_width / o.size[0], full.f_size.f_height / o.size[1] };
    }

    /// Leaves the overview for the tab that was on screen, zooming back into it.
    pub fn close(o: *Overview) void {
        if (!o.open) return;
        const here = o.shownIndex() orelse return o.hideNow();
        o.zoomInto(here);
    }

    /// Goes to a tab: the window switches to it under the overview, which then zooms into it.
    fn pick(o: *Overview, index: usize) void {
        if (index >= o.tiles.items.len) return;
        const t = o.tiles.items[index];
        o.app.openTab(t.host, t.session_id, t.window_id);
        // Switching may have changed the tabs; the one picked is found again.
        for (o.tiles.items, 0..) |*now, i| if (now.label == t.label) return o.zoomInto(i);
        o.hideNow();
    }

    fn zoomInto(o: *Overview, index: usize) void {
        o.selected = index;
        o.focus = index;
        o.from = o.zoom;
        o.to = 0;
        o.started = 0;
        o.animating = true;
        o.takePictures();
        o.startTick();
    }

    /// Closes the overview at once, with no zoom.
    pub fn hideNow(o: *Overview) void {
        if (!o.open) return;
        o.open = false;
        o.animating = false;
        if (o.tick != 0) o.widget().removeTickCallback(o.tick);
        o.tick = 0;
        // Freeing a dozen previews takes a moment, which would show as a stutter in the last
        // frame of the zoom; they go once that frame is out.
        for (o.tiles.items) |t| {
            if (t.root) |root| root.setVisible(0);
            o.dead.append(gpa, t) catch {
                var gone = t;
                o.free(&gone);
            };
        }
        o.tiles.clearRetainingCapacity();
        if (o.reap_idle == 0 and o.dead.items.len > 0) o.reap_idle = glib.idleAdd(&reap, o);
        o.widget().setVisible(0);
        const a = o.app;
        if (!a.board.shown()) {
            a.stack.as(gtk.Widget).setOpacity(1);
            if (a.workspace) |ws| ws.grabFocus();
        }
    }

    fn reap(data: ?*anyopaque) callconv(.c) c_int {
        const o: *Overview = @ptrCast(@alignCast(data.?));
        o.reap_idle = 0;
        for (o.dead.items) |*t| o.free(t);
        o.dead.clearRetainingCapacity();
        return 0;
    }

    /// A key while the overview is open. Returns whether it was one of the overview's own.
    pub fn key(o: *Overview, keyval: c_uint, mods: u4) bool {
        if (mods & K.ctrl != 0) return false;
        switch (keyval) {
            0xff1b => o.close(), // Escape
            0xff0d, 0xff8d, ' ' => o.pick(o.selected), // Return, Enter on the keypad, Space
            0xff51, 'h' => o.step(-1, 0),
            0xff53, 'l' => o.step(1, 0),
            0xff52, 'k' => o.step(0, -1),
            0xff54, 'j' => o.step(0, 1),
            0xff09 => o.select((o.selected + 1) % @max(1, o.tiles.items.len)), // Tab
            0xfe20 => o.select((o.selected + o.tiles.items.len -| 1) % @max(1, o.tiles.items.len)), // Shift+Tab
            else => return false,
        }
        return true;
    }

    /// Moves the ring to the nearest tab in a direction.
    fn step(o: *Overview, dx: f64, dy: f64) void {
        if (o.selected >= o.tiles.items.len) return;
        const from = center(o.tiles.items[o.selected].rect);
        var best: ?usize = null;
        var best_cost: f64 = 0;
        for (o.tiles.items, 0..) |t, i| {
            if (i == o.selected) continue;
            const c = center(t.rect);
            const along = (c[0] - from[0]) * dx + (c[1] - from[1]) * dy;
            if (along < 1) continue;
            const across = @abs((c[0] - from[0]) * dy) + @abs((c[1] - from[1]) * dx);
            const cost = along + across * 2;
            if (best == null or cost < best_cost) {
                best = i;
                best_cost = cost;
            }
        }
        if (best) |i| o.select(i);
    }

    fn select(o: *Overview, index: usize) void {
        if (index >= o.tiles.items.len or index == o.selected) return;
        o.selected = index;
        // The ring is only seen at the grid, where the zoom comes from the tab it is on.
        if (!o.animating) o.focus = index;
        o.widget().queueAllocate();
    }

    /// The tabs changed on a server: the grid follows.
    pub fn changed(o: *Overview) void {
        if (!o.open) return;
        o.sync();
        if (o.tiles.items.len == 0) o.hideNow() else o.startTick();
    }

    /// A pane's program, title or status changed.
    pub fn blockChanged(o: *Overview, h: *app_mod.Host, block_id: []const u8) void {
        for (o.tiles.items) |*t| if (t.host == h) {
            if (t.ws) |ws| ws.blockChanged(block_id);
            const v = h.server.sessionView(t.session_id) orelse continue;
            if (v.window(t.window_id)) |w| if (w.findBlock(block_id) != null) o.markAgents(t, w);
        };
    }

    /// Makes a tab's dots say what its agents are doing now: one for each pane that runs an
    /// agent or reports a status, in the panes' order, in the colors the panes' icons use.
    fn markAgents(o: *Overview, t: *Tile, w: *const view.Window) void {
        var classes: [16][:0]const u8 = undefined;
        var n: usize = 0;
        var hash = std.hash.Wyhash.init(0);
        for (w.layers) |l| for (l.blocks) |b| {
            if (!b.isTerminal() or n == classes.len) continue;
            const info = t.host.server.blockInfo(b.id) orelse continue;
            if (!info.has_status and !programs.isAgent(info.program)) continue;
            classes[n] = if (!info.has_status) "idle" else switch (info.status) {
                .working => "working",
                .blocked => "blocked",
                .failed => "failed",
                .done => "done",
                .other => "idle",
            };
            hash.update(classes[n]);
            hash.update("/");
            n += 1;
        };
        const now = hash.final();
        if (now == t.badges_for) return;
        t.badges_for = now;
        while (t.badges.as(gtk.Widget).getFirstChild()) |old| t.badges.remove(old);
        for (classes[0..n]) |class| {
            const dot = gtk.Box.new(.horizontal, 0);
            dot.as(gtk.Widget).addCssClass("overview-dot");
            dot.as(gtk.Widget).addCssClass(class.ptr);
            dot.as(gtk.Widget).setValign(.center);
            t.badges.append(dot.as(gtk.Widget));
        }
        t.badges.as(gtk.Widget).setVisible(@intFromBool(n > 0));
        if (o.open) o.widget().queueAllocate();
    }

    /// A host is about to go: its tabs leave the grid while its server is still there.
    pub fn dropHost(o: *Overview, h: *app_mod.Host) void {
        inline for (.{ &o.tiles, &o.dead }) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].host != h) {
                    i += 1;
                    continue;
                }
                var t = list.orderedRemove(i);
                o.free(&t);
            }
        }
        o.selected = @min(o.selected, o.tiles.items.len -| 1);
        o.focus = @min(o.focus, o.tiles.items.len -| 1);
        if (!o.open) return;
        if (o.tiles.items.len == 0) o.hideNow() else o.widget().queueAllocate();
    }

    /// Pane title rows were switched on or off.
    pub fn headersChanged(o: *Overview) void {
        for (o.tiles.items) |t| if (t.ws) |ws| ws.headersChanged();
    }

    /// Full screen mode went on or off: the button says what pressing it does now.
    pub fn bareChanged(o: *Overview) void {
        o.button.setLabel(if (o.app.bare) "Leave full screen" else "Full screen");
        // The panes' margins change with the mode, and the ring and cards follow them.
        if (o.open) o.widget().queueAllocate();
    }

    /// Makes the grid hold exactly the tabs the servers have now, in the sidebar's order, and
    /// each preview there is show its tab as it is now. Tabs that are still there are kept.
    fn sync(o: *Overview) void {
        const a = o.app;
        const had_selected = if (o.selected < o.tiles.items.len) o.tiles.items[o.selected].label else null;
        const had_focus = if (o.focus < o.tiles.items.len) o.tiles.items[o.focus].label else null;
        var next: std.ArrayList(Tile) = .empty;
        for (a.hosts.items) |h| for (h.server.sessions.items) |*session| {
            const v = h.server.sessionView(session.id) orelse continue;
            for (v.windows) |*w| {
                var tile = o.take(h, session.id, w.id) orelse o.make(h, session.id, w.id);
                if (tile.ws) |ws| ws.show(session.id, w);
                var key_buf: [320]u8 = undefined;
                if (tile.picture == null) if (o.thumbs.get(thumbKey(&key_buf, h, session.id, w.id))) |kept| {
                    kept.ref();
                    tile.picture = kept;
                };
                var name: [300]u8 = undefined;
                var tab: [256]u8 = undefined;
                const tab_name = app_mod.windowLabel(h, &tab, w, v);
                const text = std.fmt.bufPrintSentinel(&name, "{s} · {s}", .{ session.label, tab_name }, 0) catch "Tab";
                tile.label.setText(text.ptr);
                o.markAgents(&tile, w);
                next.append(gpa, tile) catch o.free(&tile);
            }
        };
        // What is left belongs to tabs that are gone.
        for (o.tiles.items) |*t| o.free(t);
        o.tiles.deinit(gpa);
        o.tiles = next;
        o.selected = 0;
        o.focus = 0;
        for (o.tiles.items, 0..) |t, i| {
            if (t.label == had_selected) o.selected = i;
            if (t.label == had_focus) o.focus = i;
        }
        o.widget().queueAllocate();
    }

    fn take(o: *Overview, h: *app_mod.Host, session_id: []const u8, window_id: []const u8) ?Tile {
        for (o.tiles.items, 0..) |t, i| {
            if (t.host == h and std.mem.eql(u8, t.session_id, session_id) and std.mem.eql(u8, t.window_id, window_id)) return o.tiles.orderedRemove(i);
        }
        return null;
    }

    /// A tab's place in the grid, with its name, dots and plain card, but no preview yet.
    fn make(o: *Overview, h: *app_mod.Host, session_id: []const u8, window_id: []const u8) Tile {
        const w = o.widget();
        const blank = gtk.Box.new(.horizontal, 0);
        blank.as(gtk.Widget).addCssClass("overview-blank");
        blank.as(gtk.Widget).setCanTarget(0);
        blank.as(gtk.Widget).setParent(w);
        const label = gtk.Label.new(null);
        label.as(gtk.Widget).addCssClass("overview-name");
        label.as(gtk.Widget).setCanTarget(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setParent(w);
        // A tab on another computer says which, so it isn't taken for one on this computer.
        const chip = gtk.Label.new(null);
        var host_name: [128]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&host_name, "{s}", .{h.label}, 0)) |z| chip.setText(z.ptr) else |_| {}
        chip.as(gtk.Widget).addCssClass("overview-host");
        chip.as(gtk.Widget).setCanTarget(0);
        chip.setEllipsize(.end);
        chip.as(gtk.Widget).setVisible(@intFromBool(h.remote()));
        chip.as(gtk.Widget).setParent(w);
        const badges = gtk.Box.new(.horizontal, 5);
        badges.as(gtk.Widget).addCssClass("overview-dots");
        badges.as(gtk.Widget).setCanTarget(0);
        badges.as(gtk.Widget).setVisible(0);
        badges.as(gtk.Widget).setParent(w);
        return .{
            .host = h,
            .session_id = gpa.dupe(u8, session_id) catch @panic("out of memory"),
            .window_id = gpa.dupe(u8, window_id) catch @panic("out of memory"),
            .label = label,
            .host_chip = chip,
            .badges = badges,
            .blank = blank.as(gtk.Widget),
        };
    }

    /// Gives a tab its live preview. The preview is first drawn, and takes over from the
    /// tab's picture, once the next layout has given it its place.
    fn makePreview(o: *Overview, t: *Tile) void {
        const ws = Workspace.createPreview(t.host.server, t.host.workspace) catch return;
        ws.root.setParent(o.widget());
        t.ws = ws;
        t.root = ws.root;
        t.placed = false;
        if (t.host.server.sessionView(t.session_id)) |v| if (v.window(t.window_id)) |w| ws.show(t.session_id, w);
        o.widget().queueAllocate();
    }

    fn free(_: *Overview, t: *Tile) void {
        if (t.ws) |ws| {
            // The workspace goes while its widget is still in place; see `Workspace.destroy`.
            ws.destroy();
            if (t.root) |root| root.unparent();
        }
        t.ws = null;
        t.root = null;
        t.label.as(gtk.Widget).unparent();
        t.host_chip.as(gtk.Widget).unparent();
        t.badges.as(gtk.Widget).unparent();
        t.blank.unparent();
        inline for (.{ &t.picture, &t.sharp }) |slot| {
            if (slot.*) |p| p.unref();
            slot.* = null;
        }
        gpa.free(t.session_id);
        gpa.free(t.window_id);
    }

    /// The grid's place for the tab the window shows now.
    fn shownIndex(o: *Overview) ?usize {
        const here = o.app.shownTab() orelse return null;
        for (o.tiles.items, 0..) |t, i| {
            if (t.host == here.host and std.mem.eql(u8, t.session_id, here.session_id) and std.mem.eql(u8, t.window_id, here.window_id)) return i;
        }
        return null;
    }

    fn tileAt(o: *Overview, x: f64, y: f64) ?usize {
        for (o.tiles.items, 0..) |t, i| {
            const r = t.rect;
            if (x >= r[0] and x < r[0] + r[2] and y >= r[1] and y < r[1] + r[3] + name_room) return i;
        }
        return null;
    }

    fn clicked(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, o: *Overview) callconv(.c) void {
        // A click lands on the grid only once the grid is what is shown.
        if (o.animating) return;
        if (o.tileAt(x, y)) |i| o.pick(i) else o.close();
    }

    fn moved(_: *gtk.EventControllerMotion, x: f64, y: f64, o: *Overview) callconv(.c) void {
        const still = @abs(x - o.pointer[0]) < 1 and @abs(y - o.pointer[1]) < 1;
        const first = o.pointer[0] < 0;
        o.pointer = .{ x, y };
        // The pointer happening to be over a tab as the grid appears picks nothing.
        if (still or first or o.animating) return;
        if (o.tileAt(x, y)) |i| o.select(i);
    }

    // Layout.

    /// Works out every tab's place in the grid: as many columns as make the tabs largest, each
    /// tab the window's own shape, the last row centered.
    fn computeRects(o: *Overview) void {
        const n = o.tiles.items.len;
        const full_w = o.size[0];
        const full_h = o.size[1];
        if (full_w < 1 or full_h < 1 or n == 0) return;
        const count: f64 = @floatFromInt(n);
        var cols: usize = 1;
        var scale: f64 = 0;
        for (1..n + 1) |c| {
            const cf: f64 = @floatFromInt(c);
            const rows = @ceil(count / cf);
            const cell_w = (full_w - 2 * pad - (cf - 1) * gap) / cf;
            const cell_h = (full_h - pad - bottom_room - (rows - 1) * gap) / rows - name_room;
            const s = @min(cell_w / full_w, cell_h / full_h);
            if (s > scale) {
                scale = s;
                cols = c;
            }
        }
        scale = std.math.clamp(scale, 0.04, 0.86);
        const tile_w = full_w * scale;
        const tile_h = full_h * scale;
        const rows: f64 = @ceil(count / @as(f64, @floatFromInt(cols)));
        const grid_h = rows * (tile_h + name_room) + (rows - 1) * gap;
        const top = @max(pad, pad + (full_h - pad - bottom_room - grid_h) / 2);
        for (o.tiles.items, 0..) |*t, i| {
            const row = i / cols;
            const col = i % cols;
            const in_row: f64 = @floatFromInt(@min(cols, n - row * cols));
            const row_w = in_row * tile_w + (in_row - 1) * gap;
            const left = (full_w - row_w) / 2;
            t.rect = .{
                @round(left + @as(f64, @floatFromInt(col)) * (tile_w + gap)),
                @round(top + @as(f64, @floatFromInt(row)) * (tile_h + name_room + gap)),
                tile_w,
                tile_h,
            };
        }
    }

    /// The part of a tab's place that its panes cover.
    fn contentRect(o: *Overview, r: [4]f64) [4]f64 {
        return .{ r[0] + o.content[0] * r[2], r[1] + o.content[1] * r[3], o.content[2] * r[2], o.content[3] * r[3] };
    }

    /// Gives every child its place: the previews, the plain cards, names and dots, the ring
    /// and the button.
    fn layout(o: *Overview) void {
        const n = o.tiles.items.len;
        const full_w = o.size[0];
        const full_h = o.size[1];
        if (full_w < 1 or full_h < 1) return;
        o.computeRects();
        // The window's panes were laid out just before this, so their margins are current.
        o.measureContent();
        var min: c_int = 0;
        for (o.tiles.items) |*t| {
            const c = o.contentRect(t.rect);
            if (t.root) |root| {
                // The preview has the window's full size, so its panes are laid out exactly as
                // in the window, and is drawn small.
                place(root, full_w, full_h, t.rect[0], t.rect[1], t.rect[2] / full_w);
                t.placed = true;
            }
            place(t.blank, c[2], c[3], c[0], c[1], 1);
            const lw = t.label.as(gtk.Widget);
            var nat_w: c_int = 0;
            var nat_h: c_int = 0;
            lw.measure(.horizontal, -1, &min, &nat_w, null, null);
            lw.measure(.vertical, -1, &min, &nat_h, null, null);
            const w = @min(@as(f64, @floatFromInt(nat_w)), c[2]);
            place(lw, w, @floatFromInt(nat_h), @round(c[0] + (c[2] - w) / 2), @round(c[1] + c[3] + 10), 1);
            const bw = t.badges.as(gtk.Widget);
            var badges_w: c_int = 0;
            var badges_h: c_int = 0;
            bw.measure(.horizontal, -1, &min, &badges_w, null, null);
            bw.measure(.vertical, -1, &min, &badges_h, null, null);
            place(bw, @floatFromInt(badges_w), @floatFromInt(badges_h), @round(c[0] + c[2] - @as(f64, @floatFromInt(badges_w)) - 8), @round(c[1] + 8), 1);
            const cw = t.host_chip.as(gtk.Widget);
            var chip_w: c_int = 0;
            var chip_h: c_int = 0;
            cw.measure(.horizontal, -1, &min, &chip_w, null, null);
            cw.measure(.vertical, -1, &min, &chip_h, null, null);
            // The chip keeps clear of the dots when a narrow tab has both.
            const chip_room = @max(1, c[2] - 24 - @as(f64, @floatFromInt(badges_w)));
            place(cw, @min(@as(f64, @floatFromInt(chip_w)), chip_room), @floatFromInt(chip_h), @round(c[0] + 8), @round(c[1] + 8), 1);
        }
        // The ring goes around the panes themselves, a little off them, not around the tab's
        // whole place, which is larger by the margins the panes keep in the window.
        const sel = if (o.selected < n) o.contentRect(o.tiles.items[o.selected].rect) else [4]f64{ 0, 0, 1, 1 };
        place(o.ring, @round(sel[2]) + 2 * ring_gap, @round(sel[3]) + 2 * ring_gap, @round(sel[0]) - ring_gap, @round(sel[1]) - ring_gap, 1);
        const bw = o.button.as(gtk.Widget);
        var nat_w: c_int = 0;
        var nat_h: c_int = 0;
        bw.measure(.horizontal, -1, &min, &nat_w, null, null);
        bw.measure(.vertical, -1, &min, &nat_h, null, null);
        const button_w: f64 = @floatFromInt(nat_w);
        const button_h: f64 = @floatFromInt(nat_h);
        place(bw, button_w, button_h, @round((full_w - button_w) / 2), @round(full_h - button_h - 16), 1);
    }

    /// The part of the grid on screen now: the focus tab's place when zoomed in, all of it
    /// when zoomed out.
    fn viewRect(o: *Overview) [4]f64 {
        const whole = [4]f64{ 0, 0, o.size[0], o.size[1] };
        if (o.focus >= o.tiles.items.len) return whole;
        const r = o.tiles.items[o.focus].rect;
        const small = r[2] / @max(1, whole[2]);
        if (small > 0.98) return whole;
        // A zoom about the one point that stays put between the tab's place and the whole
        // grid, with the size changing by equal ratios in equal times: to the eye that is an
        // even speed, where sliding the edges at an even speed rushes at one end.
        const s = std.math.pow(f64, small, 1 - o.zoom);
        const still = [2]f64{ r[0] / (1 - small), r[1] / (1 - small) };
        return .{ still[0] * (1 - s), still[1] * (1 - s), whole[2] * s, whole[3] * s };
    }

    // The zoom, and the previews after it.

    fn startTick(o: *Overview) void {
        if (o.tick == 0) o.tick = o.widget().addTickCallback(&onTick, o, null);
    }

    fn onTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const o: *Overview = @ptrCast(@alignCast(data.?));
        if (o.animating) {
            const now = clock.getFrameTime();
            if (o.started == 0) o.started = now;
            const p = std.math.clamp(@as(f64, @floatFromInt(now - o.started)) / (zoom_ms * 1000), 0, 1);
            o.zoom = o.from + (o.to - o.from) * ease(p);
            o.widget().queueDraw();
            if (p < 1) return 1;
            o.animating = false;
            if (o.to == 0) {
                // Zoomed all the way in, the tab itself takes over from its copy.
                o.tick = 0;
                o.hideNow();
                return 0;
            }
            return 1;
        }
        // The grid is still: the previews are made, one a frame, the focus tab's first.
        const order = [_]?usize{ if (o.focus < o.tiles.items.len) o.focus else null, null };
        for (order) |first| {
            if (first) |i| {
                if (o.tiles.items[i].ws == null) {
                    o.makePreview(&o.tiles.items[i]);
                    return 1;
                }
            } else for (o.tiles.items) |*t| if (t.ws == null) {
                o.makePreview(t);
                return 1;
            };
        }
        // A preview that has its place is what is drawn from then on; the sharp picture the
        // zoom out left in its place has done its work.
        var waiting = false;
        for (o.tiles.items) |*t| {
            if (!t.placed) waiting = true else if (t.sharp) |p| {
                p.unref();
                t.sharp = null;
            }
        }
        if (waiting) return 1;
        o.tick = 0;
        return 0;
    }

    fn screenScale(o: *Overview) f64 {
        const native = o.widget().getNative() orelse return 1;
        return if (native.getSurface()) |s| s.getScale() else 1;
    }

    /// A picture of a widget as it was last drawn, `q` pixels to each of its own. Null for a
    /// widget that hasn't been drawn yet.
    fn shoot(o: *Overview, source: *gtk.Widget, q: f64) ?*gdk.Texture {
        const native = o.app.window.as(gtk.Native);
        const renderer = native.getRenderer() orelse return null;
        var own: graphene.Rect = undefined;
        if (source.computeBounds(source, &own) == 0) return null;
        if (own.f_size.f_width < 1 or own.f_size.f_height < 1) return null;
        const paintable = gtk.WidgetPaintable.new(source);
        defer paintable.unref();
        const sn = gtk.Snapshot.new();
        sn.scale(@floatCast(q), @floatCast(q));
        paintable.as(gdk.Paintable).snapshot(sn.as(gdk.Snapshot), own.f_size.f_width, own.f_size.f_height);
        const node = sn.freeToNode() orelse return null;
        defer node.unref();
        var viewport: graphene.Rect = .{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = @ceil(own.f_size.f_width * @as(f32, @floatCast(q))), .f_height = @ceil(own.f_size.f_height * @as(f32, @floatCast(q))) } };
        return renderer.renderTexture(node, &viewport);
    }

    /// Takes a picture of every preview, for the zoom in to move in place of the live panes,
    /// and keeps each for the next time the overview opens.
    fn takePictures(o: *Overview) void {
        const screen = o.screenScale();
        for (o.tiles.items, 0..) |*t, i| {
            const root = t.root orelse continue;
            if (!t.placed) continue;
            const small = t.rect[2] / @max(1, o.size[0]);
            if (o.shoot(root, @max(0.2, small * screen))) |picture| {
                if (t.picture) |old| old.unref();
                t.picture = picture;
                o.keep(t, picture);
            }
            if (i == o.focus) if (o.shoot(root, screen)) |sharp| {
                if (t.sharp) |old| old.unref();
                t.sharp = sharp;
            };
        }
    }

    /// Remembers a tab's picture for the next time the overview opens.
    fn keep(o: *Overview, t: *const Tile, picture: *gdk.Texture) void {
        var key_buf: [320]u8 = undefined;
        const window_id = thumbKey(&key_buf, t.host, t.session_id, t.window_id);
        if (o.thumbs.getPtr(window_id)) |slot| {
            slot.*.unref();
            picture.ref();
            slot.* = picture;
            return;
        }
        // Pictures of tabs long closed would otherwise pile up: past the limit all go, and
        // the tabs there are now are kept again as they are next pictured.
        if (o.thumbs.count() >= max_thumbs) {
            var it = o.thumbs.iterator();
            while (it.next()) |e| {
                e.value_ptr.*.unref();
                gpa.free(e.key_ptr.*);
            }
            o.thumbs.clearRetainingCapacity();
        }
        const key_copy = gpa.dupe(u8, window_id) catch return;
        picture.ref();
        o.thumbs.put(gpa, key_copy, picture) catch {
            picture.unref();
            gpa.free(key_copy);
        };
    }

    fn draw(o: *Overview, sn: *gtk.Snapshot) void {
        const w = o.widget();
        if (o.size[0] < 1 or o.tiles.items.len == 0) return;
        // In full screen mode the window draws nothing behind the panes, so the grid would lie
        // straight on the desktop, where a bright wallpaper swallows the names: it is dimmed.
        if (o.app.bare and o.zoom > 0.01) {
            sn.appendColor(&.{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = @floatCast(0.34 * o.zoom) }, &.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = @floatCast(o.size[0]), .f_height = @floatCast(o.size[1]) } });
        }
        const v = o.viewRect();
        const k: f32 = @floatCast(o.size[0] / @max(1, v[2]));
        sn.save();
        sn.scale(k, k);
        sn.translate(&.{ .f_x = @floatCast(-v[0]), .f_y = @floatCast(-v[1]) });
        for (o.tiles.items) |t| {
            // At rest a tab is its live preview, once there is one. While the zoom runs, and
            // until then, it is a picture, or failing that a plain card.
            if (!o.animating and t.placed) {
                if (t.root) |root| {
                    w.snapshotChild(root, sn);
                    continue;
                }
            }
            const c = o.contentRect(t.rect);
            const bounds: graphene.Rect = .{ .f_origin = .{ .f_x = @floatCast(c[0]), .f_y = @floatCast(c[1]) }, .f_size = .{ .f_width = @floatCast(c[2]), .f_height = @floatCast(c[3]) } };
            if (t.sharp) |sharp| {
                if (t.picture) |picture| {
                    // The sharp picture while the tab is large, the grid's own as it nears
                    // its place there, so neither end of the zoom shows a change of picture.
                    sn.pushCrossFade(std.math.pow(f64, o.zoom, 2));
                    sn.appendScaledTexture(sharp, .trilinear, &bounds);
                    sn.pop();
                    sn.appendScaledTexture(picture, .linear, &bounds);
                    sn.pop();
                } else sn.appendScaledTexture(sharp, .trilinear, &bounds);
            } else if (t.picture) |picture| {
                sn.appendScaledTexture(picture, .linear, &bounds);
            } else w.snapshotChild(t.blank, sn);
        }
        // The names, dots and ring belong to the grid, and fade as a tab comes to fill the
        // window.
        if (o.zoom > 0.01) {
            sn.pushOpacity(o.zoom);
            for (o.tiles.items) |t| {
                w.snapshotChild(t.label.as(gtk.Widget), sn);
                inline for (.{ t.badges.as(gtk.Widget), t.host_chip.as(gtk.Widget) }) |mark| {
                    if (mark.getVisible() != 0) w.snapshotChild(mark, sn);
                }
            }
            w.snapshotChild(o.ring, sn);
            sn.pop();
        }
        sn.restore();
        if (o.zoom > 0.01) {
            sn.pushOpacity(o.zoom);
            w.snapshotChild(o.button.as(gtk.Widget), sn);
            sn.pop();
        }
    }
};

/// How far along the zoom is at a share `p` of its time: off quickly, then a long, gentle
/// arrival. The curve is cubic-bezier(0.2, 0, 0, 1).
fn ease(p: f64) f64 {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    // The curve gives time and progress for a parameter t; t is found for this time.
    var t = p;
    for (0..8) |_| {
        const u = 1 - t;
        const x = 3 * u * u * t * 0.2 + t * t * t;
        const slope = 3 * u * u * 0.2 - 6 * u * t * 0.2 + 3 * t * t;
        if (@abs(slope) < 1e-6) break;
        t = std.math.clamp(t - (x - p) / slope, 0, 1);
    }
    const u = 1 - t;
    return 3 * u * t * t + t * t * t;
}

/// What a tab's kept picture is filed under. Window IDs are only one server's own, so the
/// host and session are part of it.
fn thumbKey(buf: []u8, h: *app_mod.Host, session_id: []const u8, window_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x}/{s}/{s}", .{ @intFromPtr(h), session_id, window_id }) catch window_id;
}

fn center(r: [4]f64) [2]f64 {
    return .{ r[0] + r[2] / 2, r[1] + r[3] / 2 };
}

/// Gives a child its size, at a place in the grid and drawn at `scale`.
fn place(w: *gtk.Widget, width: f64, height: f64, x: f64, y: f64, scale: f64) void {
    var t: ?*gsk.Transform = gsk.Transform.new();
    if (t) |now| t = now.translate(&.{ .f_x = @floatCast(x), .f_y = @floatCast(y) });
    if (scale != 1) if (t) |now| {
        t = now.scale(@floatCast(scale), @floatCast(scale));
    };
    w.allocate(@intFromFloat(@max(1, @round(width))), @intFromFloat(@max(1, @round(height))), -1, t);
}

/// The overview's widget: it lays its children out in the grid and draws them through the
/// zoom, which nothing GTK has ready does.
const Area = extern struct {
    parent_instance: Parent,
    overview: ?*Overview,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "RenuxOverview",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.overview = null;
        return self;
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn sizeAllocate(self: *Self, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        const o = self.overview orelse return;
        o.size = .{ @floatFromInt(width), @floatFromInt(height) };
        o.layout();
    }

    fn snapshot(self: *Self, sn: *gtk.Snapshot) callconv(.c) void {
        if (self.overview) |o| o.draw(sn);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const w = self.as(gtk.Widget);
        while (w.getFirstChild()) |child| child.unparent();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
