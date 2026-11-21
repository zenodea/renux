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
//! The zoom runs on a spring, so it settles a touch past the grid and comes back, and a key
//! pressed part-way turns it around from where it is. The tabs around the one zoomed out of
//! land after it, the farthest last. The ring slides from tab to tab on a quicker spring of
//! its own, and gives a little when a key has nowhere to send it. Names, dots, ring and foot
//! come in over the second half of the zoom, and a preview fades in over the plain card that
//! stood for it.
//!
//! A frame of the zoom is kept to what costs next to nothing to draw: pictures at another
//! size, and text at the size it already has. So the tabs land by size alone, with no fade
//! of their own, and the names, dots and hosts follow their tabs through the zoom at their
//! own size instead of growing and shrinking with the grid.
//!
//! A tab with agents in it carries a small dot for each in its top right corner, in the color
//! of what that agent is doing, so the grid can be watched in place of the panes.
const std = @import("std");
const builtin = @import("builtin");
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
const settings = @import("../settings/settings.zig");
const wayland = @import("../platform/wayland.zig");

const gpa = std.heap.c_allocator;

/// Room around the grid, between its tabs, under each tab for its name, and at the bottom.
const pad: f64 = 36;
const gap: f64 = 28;
const name_room: f64 = 30;
const bottom_room: f64 = 64;
/// Room under a tab for its name inside a session's group, where there is less to spare.
const group_name_room: f64 = 26;
/// The zoom's spring: how stiff it is, and how damped. At 1 it would never pass where it is
/// going; a little under, it settles a touch past the grid and comes back.
const zoom_stiffness: f64 = 210;
const zoom_damping: f64 = 0.8;
/// The ring's spring, quicker, and the push a key with no tab in its direction gives the
/// ring, in pixels a second.
const ring_stiffness: f64 = 1100;
const ring_damping: f64 = 0.86;
const ring_nudge: f64 = 420;
/// How long a preview takes to fade in over the card or picture in its place.
const fade_ms: f64 = 200;
/// The tabs around the one zoomed out of land after it: the share of the zoom the farthest
/// waits before it starts, and the size they land from.
const land_wait: f64 = 0.3;
const land_from: f64 = 0.88;
/// How far the names and the foot rise into place as the grid appears.
const name_rise: f64 = 6;
const foot_rise: f64 = 16;
/// How far the ring stands off the tab it is around.
const ring_gap: f64 = 4;
/// The most pictures of tabs kept between one opening of the overview and the next.
const max_thumbs = 24;
/// How much finer than its size in the grid a tab's picture is taken, up to the screen's own
/// sharpness: the zoom enlarges the tabs beside the one it goes into.
const picture_detail: f64 = 1.7;

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
    /// The live copy of the tab, made once the grid is still, and what holds the last frame
    /// drawn of it, for taking its picture.
    ws: ?*Workspace = null,
    root: ?*gtk.Widget = null,
    shot: ?*gtk.WidgetPaintable = null,
    /// Whether the preview has been given its place and size, and so can be drawn.
    placed: bool = false,
    /// How far the preview has faded in over what stood for it, 0 to 1.
    live: f64 = 0,
    /// Its place in the grid, and where it is drawn now: on its way there after the grid has
    /// changed, growing in when it is new, shrinking away when its tab has closed.
    rect: [4]f64 = .{ 0, 0, 0, 0 },
    cur: [4]f64 = .{ 0, 0, 0, 0 },
    alpha: f64 = 1,
    seen: bool = false,
    /// A picture of the tab's panes at about the size they have in the grid: the one taken
    /// when the overview last closed, until a newer one is.
    picture: ?*gdk.Texture = null,
    /// For the tab the zoom goes into or comes out of: a picture as sharp as the screen.
    sharp: ?*gdk.Texture = null,
};

/// The tabs of one session, shown together with the session's name while tabs are grouped.
const Group = struct {
    /// Its tabs: `count` of them in `tiles`, from `first`.
    first: usize,
    count: usize,
    rect: [4]f64 = .{ 0, 0, 0, 0 },
    card: *gtk.Widget,
    label: *gtk.Label,
};

/// A new tab was asked for in a session. It is gone to when the server shows it: the first tab
/// of that session that isn't one of those it had.
const Awaited = struct {
    host: *app_mod.Host,
    session_id: []u8,
    had: std.ArrayList([]u8) = .empty,

    fn deinit(w: *Awaited) void {
        gpa.free(w.session_id);
        for (w.had.items) |id| gpa.free(id);
        w.had.deinit(gpa);
    }
};

pub const Overview = struct {
    app: *app_mod.App,
    area: *Area,
    ring: *gtk.Widget,
    /// Groups the tabs by session, or not; the keys the overview answers to, said once.
    group_button: *gtk.ToggleButton,
    hint: *gtk.Label,
    tiles: std.ArrayList(Tile) = .empty,
    /// One for each session while tabs are grouped by session, none otherwise.
    groups: std.ArrayList(Group) = .empty,
    awaited: ?Awaited = null,
    /// Tabs that have closed, fading out of the grid.
    leaving: std.ArrayList(Tile) = .empty,
    /// The grid changed while open, and its tabs are gliding to their new places.
    gliding: bool = false,
    last_frame: i64 = 0,
    /// The grid has been shown: tabs added from now on grow in, and the grid's changes glide.
    settled: bool = false,
    /// A new tab to go to once it has grown in, by its name's widget.
    go_after: ?*gtk.Label = null,
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
    /// It is on its way to `to` at speed `vel`, and passes 1 a little before it settles.
    zoom: f64 = 1,
    to: f64 = 1,
    vel: f64 = 0,
    /// The zoom is running. The tick goes on after it, while previews are still to be made.
    animating: bool = false,
    tick: c_uint = 0,
    /// The ring on its way to the tab it is on: how far off its place it is and how fast it
    /// moves, where it was last drawn, and whether it is to start from there, set when the
    /// tab it is on changes.
    ring_off: [2]f64 = .{ 0, 0 },
    ring_vel: [2]f64 = .{ 0, 0 },
    ring_at: [2]f64 = .{ 0, 0 },
    ring_moved: bool = false,
    /// Development: the clock is stopped, and moved on by hand; see `hold`.
    held: bool = false,
    size: [2]f64 = .{ 0, 0 },
    /// The part of a tab's place its panes cover, as shares of that place: all of it but the
    /// margins the panes have in the window.
    content: [4]f64 = .{ 0, 0, 1, 1 },
    /// Where the pointer last was, so a still pointer doesn't steal the ring from the keys.
    pointer: [2]f64 = .{ -1, -1 },
    /// The parts of the window the desktop was last asked to blur, and no others; see `frost`.
    frosted: std.ArrayList(wayland.Part) = .empty,
    frosting: bool = false,

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
        const group_button = gtk.ToggleButton.newWithLabel("By session");
        group_button.as(gtk.Widget).addCssClass("pill");
        group_button.as(gtk.Widget).addCssClass("overview-button");
        group_button.as(gtk.Widget).setFocusable(0);
        group_button.setActive(@intFromBool(settings.current.overview_by_session));
        group_button.as(gtk.Widget).setParent(w);
        const hint = gtk.Label.new("Enter  open     X  close     C  new tab     S  by session");
        hint.as(gtk.Widget).addCssClass("overview-hint");
        hint.as(gtk.Widget).setCanTarget(0);
        hint.as(gtk.Widget).setParent(w);
        o.* = .{ .app = a, .area = area, .ring = ring.as(gtk.Widget), .group_button = group_button, .hint = hint };
        _ = gtk.ToggleButton.signals.toggled.connect(group_button, *Overview, &groupToggled, o, .{});
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
        if (!o.open) return o.show();
        // Asked for again on its way into a tab, it turns around and comes back out.
        if (o.animating and o.to == 0) {
            o.to = 1;
            return;
        }
        o.close();
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
        const sharp: ?*gdk.Texture = if (a.current) |h| o.shoot(h.shot, h.workspace.root, o.screenScale()) else null;
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
        for (o.tiles.items) |*t| {
            t.cur = t.rect;
            t.alpha = 1;
            t.seen = true;
        }
        o.settled = true;
        o.gliding = false;
        o.zoom = 1;
        o.to = 1;
        o.vel = 0;
        o.animating = false;
        o.ring_off = .{ 0, 0 };
        o.ring_vel = .{ 0, 0 };
        o.ring_moved = false;
        o.markChosen();
        if (sharp) |p| {
            if (here) |i| {
                o.tiles.items[i].sharp = p;
                o.zoom = 0;
                o.animating = true;
            } else p.unref();
        }
        o.startTick();
        o.widget().queueAllocate();
    }

    /// Measures which part of a tab's place its panes cover, from the window's own panes: the
    /// margins they keep there change with the pane style and with the window's background.
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
        // The zoom keeps the speed it has, so one turned around part-way doesn't stop first.
        o.to = 0;
        o.animating = true;
        o.gliding = false;
        o.go_after = null;
        o.ring_off = .{ 0, 0 };
        o.ring_vel = .{ 0, 0 };
        o.ring_moved = false;
        for (o.tiles.items) |*t| {
            t.cur = t.rect;
            t.alpha = 1;
        }
        o.markChosen();
        o.takePictures(true);
        o.startTick();
    }

    /// Closes the overview at once, with no zoom.
    pub fn hideNow(o: *Overview) void {
        if (!o.open) return;
        o.open = false;
        o.animating = false;
        o.vel = 0;
        o.gliding = false;
        o.settled = false;
        o.go_after = null;
        for (o.leaving.items) |*t| o.free(t);
        o.leaving.clearRetainingCapacity();
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
        o.regroup();
        if (o.awaited) |*w| w.deinit();
        o.awaited = null;
        if (o.reap_idle == 0 and o.dead.items.len > 0) o.reap_idle = glib.idleAdd(&reap, o);
        o.widget().setVisible(0);
        // The window's panes are back, and what is blurred is theirs to say again.
        o.frosting = false;
        o.app.frost();
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
            0xff09 => o.cycle(1), // Tab
            0xfe20 => o.cycle(-1), // Shift+Tab
            'x' => o.closeSelected(),
            'c' => o.newTab(),
            's' => o.setGrouped(!settings.current.overview_by_session),
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
        if (best) |i| return o.select(i);
        // Nowhere to go that way: the ring gives a little, and comes back.
        o.ring_vel[0] += dx * ring_nudge;
        o.ring_vel[1] += dy * ring_nudge;
        o.startTick();
    }

    /// Moves the ring to the next or the previous tab.
    fn cycle(o: *Overview, by: isize) void {
        const n: isize = @intCast(o.tiles.items.len);
        if (n > 0) o.select(@intCast(@mod(@as(isize, @intCast(o.selected)) + by, n)));
    }

    /// Closes the tab the ring is on, with every pane in it.
    fn closeSelected(o: *Overview) void {
        if (o.selected >= o.tiles.items.len) return;
        const t = o.tiles.items[o.selected];
        t.host.server.closeWindow(t.session_id, t.window_id);
    }

    /// Opens a new tab in the session of the tab the ring is on, and goes to it once the
    /// server has made it.
    fn newTab(o: *Overview) void {
        if (o.selected >= o.tiles.items.len) return;
        const t = o.tiles.items[o.selected];
        if (o.awaited) |*old| old.deinit();
        var w: Awaited = .{ .host = t.host, .session_id = gpa.dupe(u8, t.session_id) catch return };
        for (o.tiles.items) |other| if (other.host == t.host and std.mem.eql(u8, other.session_id, t.session_id)) {
            w.had.append(gpa, gpa.dupe(u8, other.window_id) catch continue) catch {};
        };
        o.awaited = w;
        t.host.server.newWindow(t.session_id, t.window_id);
    }

    /// Goes to the tab that was asked for, if it is among the tabs now.
    fn followNew(o: *Overview) void {
        const w = &(o.awaited orelse return);
        for (o.tiles.items, 0..) |t, i| {
            if (t.host != w.host or !std.mem.eql(u8, t.session_id, w.session_id)) continue;
            const old = for (w.had.items) |id| {
                if (std.mem.eql(u8, id, t.window_id)) break true;
            } else false;
            if (old) continue;
            w.deinit();
            o.awaited = null;
            // The ring goes to the new tab, which is gone to once it has grown into its place.
            o.selected = i;
            o.focus = i;
            o.go_after = t.label;
            o.ring_moved = true;
            o.markChosen();
            return o.startGlide();
        }
    }

    /// Starts the tabs moving to the places the grid has for them now. They are drawn from
    /// pictures while they move, as in the zoom.
    fn startGlide(o: *Overview) void {
        if (!o.open or o.animating) return;
        if (!o.gliding) o.takePictures(false);
        o.gliding = true;
        o.startTick();
        o.widget().queueAllocate();
    }

    /// Moves every tab a step toward its place, new ones toward full size and closed ones
    /// away. False once nothing is left to move.
    fn glide(o: *Overview, dt: f64) bool {
        const k = 1 - @exp(-dt / 0.06);
        var moving = false;
        for (o.tiles.items) |*t| {
            for (0..4) |i| {
                const d = t.rect[i] - t.cur[i];
                if (@abs(d) > 0.4) {
                    t.cur[i] += d * k;
                    moving = true;
                } else t.cur[i] = t.rect[i];
            }
            if (t.alpha < 0.99) {
                t.alpha += (1 - t.alpha) * k;
                moving = true;
            } else t.alpha = 1;
        }
        var i: usize = 0;
        while (i < o.leaving.items.len) {
            const t = &o.leaving.items[i];
            t.alpha *= 1 - k;
            t.cur = shrunk(t.cur, 1 - 0.1 * k);
            if (t.alpha > 0.03) {
                moving = true;
                i += 1;
                continue;
            }
            var gone = o.leaving.orderedRemove(i);
            o.free(&gone);
        }
        return moving;
    }

    fn groupToggled(button: *gtk.ToggleButton, o: *Overview) callconv(.c) void {
        o.setGrouped(button.getActive() != 0);
    }

    /// Shows the tabs one by one, or together by session, each session under its name.
    fn setGrouped(o: *Overview, on: bool) void {
        if (settings.current.overview_by_session != on) {
            settings.current.overview_by_session = on;
            settings.save();
        }
        // Setting the button runs `groupToggled`, which comes back here with nothing to save.
        if ((o.group_button.getActive() != 0) != on) return o.group_button.setActive(@intFromBool(on));
        if (!o.open) return;
        // The tabs' names change with the grouping, and the tabs glide to their new places.
        o.sync();
        o.startGlide();
    }

    /// Makes the groups match the tabs: one for each session, in order, while grouping is on.
    fn regroup(o: *Overview) void {
        for (o.groups.items) |g| {
            g.card.unparent();
            g.label.as(gtk.Widget).unparent();
        }
        o.groups.clearRetainingCapacity();
        if (!settings.current.overview_by_session) return;
        var i: usize = 0;
        while (i < o.tiles.items.len) {
            const first = o.tiles.items[i];
            var j = i + 1;
            while (j < o.tiles.items.len and o.tiles.items[j].host == first.host and std.mem.eql(u8, o.tiles.items[j].session_id, first.session_id)) j += 1;
            const card = gtk.Box.new(.horizontal, 0);
            card.as(gtk.Widget).addCssClass("overview-group");
            card.as(gtk.Widget).setCanTarget(0);
            card.as(gtk.Widget).setParent(o.widget());
            const label = gtk.Label.new(null);
            label.as(gtk.Widget).addCssClass("overview-name");
            // A session's name is told from its tabs' where there is no card around them.
            label.as(gtk.Widget).addCssClass("overview-session");
            // A session's name is lit like the name of the tab the ring is on, not dimmed.
            label.as(gtk.Widget).addCssClass("chosen");
            label.as(gtk.Widget).setCanTarget(0);
            label.setEllipsize(.end);
            var name: [200]u8 = undefined;
            const session = for (first.host.server.sessions.items) |se| {
                if (std.mem.eql(u8, se.id, first.session_id)) break se.label;
            } else "Session";
            if (std.fmt.bufPrintSentinel(&name, "{s}", .{session}, 0)) |z| label.setText(z.ptr) else |_| {}
            label.as(gtk.Widget).setParent(o.widget());
            o.groups.append(gpa, .{ .first = i, .count = j - i, .card = card.as(gtk.Widget), .label = label }) catch {
                card.as(gtk.Widget).unparent();
                label.as(gtk.Widget).unparent();
            };
            i = j;
        }
    }

    fn select(o: *Overview, index: usize) void {
        if (index >= o.tiles.items.len or index == o.selected) return;
        o.selected = index;
        // The ring is only seen at the grid, where the zoom comes from the tab it is on.
        if (!o.animating) o.focus = index;
        // It slides to the tab from where it is, starting this frame, and the tab's name
        // lights up.
        const home = o.ringHome();
        o.ring_off = .{ o.ring_at[0] - home[0], o.ring_at[1] - home[1] };
        o.markChosen();
        o.startTick();
        o.widget().queueAllocate();
    }

    /// Where the ring belongs: around the panes of the tab it is on, a little off them, not
    /// around the tab's whole place, which is larger by the margins the panes keep.
    fn ringHome(o: *Overview) [2]f64 {
        if (o.selected >= o.tiles.items.len) return .{ 0, 0 };
        const sel = o.contentRect(o.tiles.items[o.selected].cur);
        return .{ @round(sel[0]) - ring_gap, @round(sel[1]) - ring_gap };
    }

    /// Lights the name of the tab the ring is on; the other names are dimmed.
    fn markChosen(o: *Overview) void {
        for (o.tiles.items, 0..) |t, i| {
            const name = t.label.as(gtk.Widget);
            if (i == o.selected) name.addCssClass("chosen") else name.removeCssClass("chosen");
        }
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
        inline for (.{ &o.tiles, &o.dead, &o.leaving }) |list| {
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
        o.markChosen();
        if (!o.open) return;
        if (o.tiles.items.len == 0) o.hideNow() else o.widget().queueAllocate();
    }

    /// Pane title rows were switched on or off.
    pub fn headersChanged(o: *Overview) void {
        for (o.tiles.items) |t| if (t.ws) |ws| ws.headersChanged();
    }

    /// The window's background went or came back.
    pub fn bareChanged(o: *Overview) void {
        // The panes' margins change with it, and the ring and cards follow them.
        if (o.open) o.widget().queueAllocate();
    }

    /// Makes the grid hold exactly the tabs the servers have now, in the sidebar's order, and
    /// each preview there is show its tab as it is now. Tabs that are still there are kept.
    fn sync(o: *Overview) void {
        const a = o.app;
        const was_selected = o.selected;
        const had_selected = if (o.selected < o.tiles.items.len) o.tiles.items[o.selected].label else null;
        const had_focus = if (o.focus < o.tiles.items.len) o.tiles.items[o.focus].label else null;
        var next: std.ArrayList(Tile) = .empty;
        var differs = false;
        const grouped = settings.current.overview_by_session;
        for (a.hosts.items) |h| for (h.server.sessions.items) |*session| {
            const v = h.server.sessionView(session.id) orelse continue;
            for (v.windows) |*w| {
                var tile = o.take(h, session.id, w.id) orelse made: {
                    differs = true;
                    break :made o.make(h, session.id, w.id);
                };
                if (tile.ws) |ws| ws.show(session.id, w);
                var key_buf: [320]u8 = undefined;
                if (tile.picture == null) if (o.thumbs.get(thumbKey(&key_buf, h, session.id, w.id))) |kept| {
                    kept.ref();
                    tile.picture = kept;
                };
                var name: [300]u8 = undefined;
                var tab: [256]u8 = undefined;
                const tab_name = app_mod.windowLabel(h, &tab, w, v);
                // Grouped, a tab is under its session's name already and says only its own.
                const text = if (grouped)
                    std.fmt.bufPrintSentinel(&name, "{s}", .{tab_name}, 0) catch "Tab"
                else
                    std.fmt.bufPrintSentinel(&name, "{s} · {s}", .{ session.label, tab_name }, 0) catch "Tab";
                tile.label.setText(text.ptr);
                o.markAgents(&tile, w);
                next.append(gpa, tile) catch o.free(&tile);
            }
        };
        // What is left belongs to tabs that are gone. With the grid on screen they fade out of
        // it, as pictures: their previews have nothing left to show.
        for (o.tiles.items) |*t| {
            differs = true;
            if (!o.settled) {
                o.free(t);
                continue;
            }
            freePreview(t);
            inline for (.{ t.label.as(gtk.Widget), t.badges.as(gtk.Widget), t.host_chip.as(gtk.Widget) }) |mark| mark.setVisible(0);
            o.leaving.append(gpa, t.*) catch o.free(t);
        }
        o.tiles.deinit(gpa);
        o.tiles = next;
        // The ring stays on its tab, or where that tab was if it is gone.
        o.selected = @min(was_selected, o.tiles.items.len -| 1);
        o.focus = o.selected;
        var kept = false;
        for (o.tiles.items, 0..) |t, i| {
            if (t.label == had_selected) {
                o.selected = i;
                kept = true;
            }
            if (t.label == had_focus) o.focus = i;
        }
        // On another tab now, the ring slides there from where it was.
        if (!kept and o.settled) o.ring_moved = true;
        o.markChosen();
        o.regroup();
        o.widget().queueAllocate();
        if (differs and o.settled) o.startGlide();
        o.followNew();
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
        t.shot = gtk.WidgetPaintable.new(ws.root);
        t.placed = false;
        t.live = 0;
        if (t.host.server.sessionView(t.session_id)) |v| if (v.window(t.window_id)) |w| ws.show(t.session_id, w);
        o.widget().queueAllocate();
    }

    /// Lets a tab's preview go, keeping the rest of the tab.
    fn freePreview(t: *Tile) void {
        if (t.shot) |shot| shot.unref();
        t.shot = null;
        if (t.ws) |ws| {
            // The workspace goes while its widget is still in place; see `Workspace.destroy`.
            ws.destroy();
            if (t.root) |root| root.unparent();
        }
        t.ws = null;
        t.root = null;
        t.placed = false;
        t.live = 0;
    }

    fn free(_: *Overview, t: *Tile) void {
        freePreview(t);
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

    /// Whether the grid is near enough its place to be pointed at. The zoom's last settling is
    /// too small to wait out before a click counts.
    fn atGrid(o: *Overview) bool {
        return !o.animating or (o.to == 1 and @abs(o.zoom - 1) < 0.03);
    }

    /// The tab at a point of the window, which is a point of the grid as the view shows it now.
    fn tileAt(o: *Overview, at_x: f64, at_y: f64) ?usize {
        const v = o.viewRect();
        const x = v[0] + at_x * v[2] / @max(1, o.size[0]);
        const y = v[1] + at_y * v[3] / @max(1, o.size[1]);
        for (o.tiles.items, 0..) |t, i| {
            const r = t.rect;
            // A tab's name under it counts as the tab.
            const below: f64 = if (o.groups.items.len > 0) group_name_room else name_room;
            if (x >= r[0] and x < r[0] + r[2] and y >= r[1] and y < r[1] + r[3] + below) return i;
        }
        return null;
    }

    fn clicked(_: *gtk.GestureClick, _: c_int, x: f64, y: f64, o: *Overview) callconv(.c) void {
        // A click lands on the grid only once the grid is what is shown.
        if (!o.atGrid()) return;
        if (o.tileAt(x, y)) |i| o.pick(i) else o.close();
    }

    fn moved(_: *gtk.EventControllerMotion, x: f64, y: f64, o: *Overview) callconv(.c) void {
        const still = @abs(x - o.pointer[0]) < 1 and @abs(y - o.pointer[1]) < 1;
        const first = o.pointer[0] < 0;
        o.pointer = .{ x, y };
        // The pointer happening to be over a tab as the grid appears picks nothing.
        if (still or first or !o.atGrid()) return;
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
        const area = [4]f64{ pad, pad, full_w - 2 * pad, full_h - pad - bottom_room };
        if (o.groups.items.len == 0) {
            const grid = Grid.fit(n, area, o.size, gap, name_room);
            for (o.tiles.items, 0..) |*t, i| t.rect = grid.cell(i);
            return;
        }
        // Grouped: each session has a cell of the grid, and its tabs a smaller grid inside it.
        const outer = Grid.fit(o.groups.items.len, area, o.size, gap, name_room);
        for (o.groups.items, 0..) |*g, k| {
            g.rect = outer.cell(k);
            const inner = Grid.fit(g.count, .{ g.rect[0] + 12, g.rect[1] + 12, g.rect[2] - 24, g.rect[3] - 24 }, o.size, 10, group_name_room);
            for (o.tiles.items[g.first .. g.first + g.count], 0..) |*t, i| t.rect = inner.cell(i);
        }
    }

    /// The part of a tab's place that its panes cover.
    fn contentRect(o: *Overview, r: [4]f64) [4]f64 {
        return .{ r[0] + o.content[0] * r[2], r[1] + o.content[1] * r[3], o.content[2] * r[2], o.content[3] * r[3] };
    }

    /// Gives every child its place: the previews, the plain cards, names and dots, the
    /// sessions' cards, the ring, and the buttons and keys at the foot.
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
            if (!t.seen) {
                // A tab that joins a grid already on screen grows into its place.
                t.seen = true;
                t.cur = if (o.settled) shrunk(t.rect, 0.86) else t.rect;
                t.alpha = if (o.settled) 0 else 1;
            } else if (!o.gliding) t.cur = t.rect;
            const c = o.contentRect(t.cur);
            if (t.root) |root| {
                // The preview has the window's full size, so its panes are laid out exactly as
                // in the window, and is drawn small.
                place(root, full_w, full_h, t.cur[0], t.cur[1], t.cur[2] / full_w);
                t.placed = true;
            }
            place(t.blank, c[2], c[3], c[0], c[1], 1);
            placeUnder(t.label.as(gtk.Widget), c);
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
        for (o.leaving.items) |t| {
            const c = o.contentRect(t.cur);
            place(t.blank, c[2], c[3], c[0], c[1], 1);
        }
        for (o.groups.items) |g| {
            place(g.card, g.rect[2], g.rect[3], g.rect[0], g.rect[1], 1);
            placeUnder(g.label.as(gtk.Widget), g.rect);
        }
        // The ring goes around the panes themselves, a little off them, not around the tab's
        // whole place, which is larger by the margins the panes keep in the window.
        const sel = if (o.selected < n) o.contentRect(o.tiles.items[o.selected].cur) else [4]f64{ 0, 0, 1, 1 };
        const home = o.ringHome();
        // On a tab that had no place until now, it starts from where it was last drawn.
        if (o.ring_moved) {
            o.ring_moved = false;
            o.ring_off = .{ o.ring_at[0] - home[0], o.ring_at[1] - home[1] };
        }
        o.ring_at = .{ home[0] + o.ring_off[0], home[1] + o.ring_off[1] };
        place(o.ring, @round(sel[2]) + 2 * ring_gap, @round(sel[3]) + 2 * ring_gap, o.ring_at[0], o.ring_at[1], 1);
        // The button in the middle of the foot, the keys at its right end.
        const buttons = [_]*gtk.Widget{o.group_button.as(gtk.Widget)};
        var sizes: [1][2]f64 = undefined;
        var row_w: f64 = 0;
        for (buttons, 0..) |b, i| {
            sizes[i] = natural(b);
            row_w += sizes[i][0];
        }
        var x = @round((full_w - row_w) / 2);
        for (buttons, 0..) |b, i| {
            place(b, sizes[i][0], sizes[i][1], x, @round(full_h - sizes[i][1] - 16), 1);
            x += sizes[i][0] + 8;
        }
        const hint = natural(o.hint.as(gtk.Widget));
        place(o.hint.as(gtk.Widget), hint[0], hint[1], @round(full_w - hint[0] - 22), @round(full_h - hint[1] - 22), 1);
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
        if (o.tick != 0 or o.held) return;
        o.last_frame = 0;
        o.tick = o.widget().addTickCallback(&onTick, o, null);
    }

    fn onTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const o: *Overview = @ptrCast(@alignCast(data.?));
        const now = clock.getFrameTime();
        const dt = if (o.last_frame == 0) 1.0 / 60.0 else std.math.clamp(@as(f64, @floatFromInt(now - o.last_frame)) / 1_000_000, 0.001, 0.05);
        o.last_frame = now;
        if (!o.held and o.advance(dt)) return 1;
        o.tick = 0;
        return 0;
    }

    /// Moves everything that is moving on by `dt` seconds: the ring, the previews fading in,
    /// the tabs gliding, the zoom, and after it the making of the previews. False once there
    /// is nothing left to do.
    fn advance(o: *Overview, dt: f64) bool {
        var busy = o.moveRing(dt);
        // A preview that has its place fades in over what stood for it.
        if (!o.animating and !o.gliding) for (o.tiles.items) |*t| {
            if (!t.placed or t.live >= 1) continue;
            // Over a picture of itself a preview has nothing to fade in from, and takes over
            // at once; drawing both for a fifth of a second would be work nobody sees.
            t.live = if (t.picture != null or t.sharp != null) 1 else @min(1, t.live + dt * 1000 / fade_ms);
            busy = true;
            o.widget().queueDraw();
        };
        if (o.gliding and !o.animating) {
            o.widget().queueAllocate();
            if (o.glide(dt)) return true;
            o.gliding = false;
            // A tab made with the overview open is gone to now that it is in its place.
            if (o.go_after) |label| {
                o.go_after = null;
                for (o.tiles.items, 0..) |t, i| if (t.label == label) {
                    o.pick(i);
                    return true;
                };
            }
            return true;
        }
        if (o.animating) {
            // A spring pulls the zoom to where it is going, in steps short enough to stay true
            // through a slow frame.
            const drag = 2 * @sqrt(zoom_stiffness) * zoom_damping;
            var left = dt;
            while (left > 0) : (left -= 0.004) {
                const h = @min(left, 0.004);
                o.vel += (-zoom_stiffness * (o.zoom - o.to) - drag * o.vel) * h;
                o.zoom += o.vel * h;
            }
            o.widget().queueDraw();
            // Into a tab it stops as it arrives; out at the grid it stops once it has settled.
            const there = if (o.to == 0) o.zoom <= 0 else @abs(o.zoom - o.to) < 0.0015 and @abs(o.vel) < 0.02;
            if (!there) return true;
            o.zoom = o.to;
            o.vel = 0;
            o.animating = false;
            if (o.to == 0) {
                // Zoomed all the way in, the tab itself takes over from its copy.
                o.tick = 0;
                o.hideNow();
                return false;
            }
            return true;
        }
        // The grid is still: the previews are made, one a frame, the focus tab's first.
        const order = [_]?usize{ if (o.focus < o.tiles.items.len) o.focus else null, null };
        for (order) |first| {
            if (first) |i| {
                if (o.tiles.items[i].ws == null) {
                    o.makePreview(&o.tiles.items[i]);
                    return true;
                }
            } else for (o.tiles.items) |*t| if (t.ws == null) {
                o.makePreview(t);
                return true;
            };
        }
        // A preview that has faded in is what is drawn from then on; the sharp picture the
        // zoom out left in its place has done its work.
        var waiting = false;
        for (o.tiles.items) |*t| {
            if (!t.placed or t.live < 1) waiting = true else if (t.sharp) |p| {
                p.unref();
                t.sharp = null;
            }
        }
        return waiting or busy;
    }

    /// Moves the ring a step toward the tab it is on. False once it is there and still.
    fn moveRing(o: *Overview, dt: f64) bool {
        const still = o.ring_off[0] == 0 and o.ring_off[1] == 0 and o.ring_vel[0] == 0 and o.ring_vel[1] == 0;
        // Told to start from where it was drawn, it does so at the next layout.
        if (still) return o.ring_moved;
        const drag = 2 * @sqrt(ring_stiffness) * ring_damping;
        var left = dt;
        while (left > 0) : (left -= 0.004) {
            const h = @min(left, 0.004);
            for (0..2) |i| {
                o.ring_vel[i] += (-ring_stiffness * o.ring_off[i] - drag * o.ring_vel[i]) * h;
                o.ring_off[i] += o.ring_vel[i] * h;
            }
        }
        if (@abs(o.ring_off[0]) < 0.3 and @abs(o.ring_off[1]) < 0.3 and @abs(o.ring_vel[0]) < 5 and @abs(o.ring_vel[1]) < 5) {
            o.ring_off = .{ 0, 0 };
            o.ring_vel = .{ 0, 0 };
        }
        o.widget().queueAllocate();
        return true;
    }

    /// Development: stops the overview's clock and moves it on by hand, `ms` at a time, so a
    /// picture can be taken part-way through a zoom or a slide. Null lets it run again.
    pub fn hold(o: *Overview, ms: ?f64) void {
        const by = ms orelse {
            o.held = false;
            if (o.open) o.startTick();
            return;
        };
        o.held = true;
        var left = by / 1000;
        while (left > 0 and o.open) : (left -= 1.0 / 240.0) _ = o.advance(1.0 / 240.0);
        if (!o.open) return;
        o.widget().queueAllocate();
        o.widget().queueDraw();
    }

    fn screenScale(o: *Overview) f64 {
        if (@import("../terminal/termview.zig").shotScale()) |scale| return scale;
        const native = o.widget().getNative() orelse return 1;
        return if (native.getSurface()) |s| s.getScale() else 1;
    }

    /// A picture of a widget as it was last drawn, `q` pixels to each of its own, from the
    /// paintable that has followed it. Null for a widget that hasn't been drawn yet. The
    /// paintable has to be one kept since before that drawing: GTK forgets a widget's last
    /// frame as soon as anything in it asks to be drawn again, as a blinking cursor does, and
    /// a paintable made now would have nothing to show.
    fn shoot(o: *Overview, paintable: *gtk.WidgetPaintable, source: *gtk.Widget, q: f64) ?*gdk.Texture {
        const native = o.app.window.as(gtk.Native);
        const renderer = native.getRenderer() orelse return null;
        var own: graphene.Rect = undefined;
        if (source.computeBounds(source, &own) == 0) return null;
        if (own.f_size.f_width < 1 or own.f_size.f_height < 1) return null;
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
    fn takePictures(o: *Overview, sharp_too: bool) void {
        const screen = o.screenScale();
        for (o.tiles.items, 0..) |*t, i| {
            const root = t.root orelse continue;
            const shot = t.shot orelse continue;
            if (!t.placed) continue;
            const small = t.rect[2] / @max(1, o.size[0]);
            // Larger than the tab is in the grid, so it stays readable as the zoom enlarges it.
            if (o.shoot(shot, root, @min(screen, @max(0.2, small * screen * picture_detail)))) |picture| {
                if (t.picture) |old| old.unref();
                t.picture = picture;
                o.keep(t, picture);
            }
            if (sharp_too and i == o.focus) if (o.shoot(shot, root, screen)) |sharp| {
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

    /// How much of its size a tab other than the one zoomed out of is drawn at: it lands in
    /// the grid, growing the last of the way, as the zoom reaches it, the farthest tab last.
    /// `far` is how far the farthest is.
    fn landing(o: *Overview, index: usize, far: f64) f64 {
        if (index == o.focus or o.zoom >= 1 or o.focus >= o.tiles.items.len) return 1;
        const from = center(o.tiles.items[o.focus].rect);
        const at = center(o.tiles.items[index].rect);
        const wait = land_wait * std.math.hypot(at[0] - from[0], at[1] - from[1]) / far;
        const q = std.math.clamp((o.zoom - wait) / (1 - wait), 0, 1);
        return land_from + (1 - land_from) * q;
    }

    /// A tab as a still: its sharp picture, its picture at the grid's size, or a plain card.
    fn drawStill(o: *Overview, sn: *gtk.Snapshot, t: *const Tile) void {
        const c = o.contentRect(t.cur);
        const bounds: graphene.Rect = .{ .f_origin = .{ .f_x = @floatCast(c[0]), .f_y = @floatCast(c[1]) }, .f_size = .{ .f_width = @floatCast(c[2]), .f_height = @floatCast(c[3]) } };
        // Pictures are drawn as plain textures. A texture node that names a way of scaling
        // is first made into a picture the size of its bounds, in the grid's own units,
        // and that picture is then enlarged by the zoom and by the screen's scale, which
        // blurs it badly. A plain one is drawn straight from its own pixels.
        if (t.sharp) |sharp| {
            // The sharp picture all the way, giving way to the grid's own only as the tab
            // settles into the grid, so neither end of the zoom shows a change of picture
            // and the text stays crisp in between.
            const near_grid = std.math.clamp((o.zoom - 0.8) / 0.2, 0, 1);
            if (t.picture != null and near_grid > 0) {
                sn.pushCrossFade(near_grid * near_grid);
                sn.appendTexture(sharp, &bounds);
                sn.pop();
                sn.appendTexture(t.picture.?, &bounds);
                sn.pop();
            } else sn.appendTexture(sharp, &bounds);
        } else if (t.picture) |picture| {
            sn.appendTexture(picture, &bounds);
        } else o.widget().snapshotChild(t.blank, sn);
    }

    /// Which point of a mark's top edge is held at the place it is drawn.
    const Hold = enum { left, middle, right };

    /// Draws a name, a tab's dots or its host at a place in the window, at its own size,
    /// wherever the layout put it.
    fn drawAt(o: *Overview, sn: *gtk.Snapshot, mark: *gtk.Widget, by: Hold, x: f64, y: f64) void {
        var b: graphene.Rect = undefined;
        if (mark.getVisible() == 0 or mark.computeBounds(o.widget(), &b) == 0) return;
        const wide: f64 = b.f_size.f_width;
        const left = switch (by) {
            .left => x,
            .middle => x - wide / 2,
            .right => x - wide,
        };
        sn.save();
        sn.translate(&.{ .f_x = @floatCast(left - b.f_origin.f_x), .f_y = @floatCast(y - b.f_origin.f_y) });
        o.widget().snapshotChild(mark, sn);
        sn.restore();
    }

    /// While the window has no background and the gaps are to be sharp, has the desktop blur
    /// only what is behind the tabs, where they are drawn in this frame. A desktop that blurs
    /// all of a see-through window would otherwise blur the room between the tabs too, which
    /// then looks like a window lying behind them.
    fn frost(o: *Overview, v: [4]f64, k: f64, far: f64) void {
        if (builtin.os.tag != .linux) return;
        if (!o.app.bare or !settings.current.sharp_gaps) return o.frostAsUsual();
        const window = o.app.window;
        const surface = window.as(gtk.Native).getSurface() orelse return;
        var at: graphene.Rect = undefined;
        if (o.widget().computeBounds(window.as(gtk.Widget), &at) == 0) return;
        var off_x: f64 = 0;
        var off_y: f64 = 0;
        window.as(gtk.Native).getSurfaceTransform(&off_x, &off_y);
        const left = off_x + at.f_origin.f_x;
        const top = off_y + at.f_origin.f_y;
        const right: f64 = @floatFromInt(surface.getWidth());
        const bottom: f64 = @floatFromInt(surface.getHeight());
        var now: std.ArrayList(wayland.Part) = .empty;
        defer now.deinit(gpa);
        // The sidebar's card stays beside the grid, frosted as it was.
        if (o.app.sidebarFrost()) |part| now.append(gpa, part) catch return;
        for (o.tiles.items, 0..) |t, i| {
            if (t.alpha <= 0) continue;
            // A tab still landing in the grid is drawn small about its middle.
            const land = o.landing(i, far);
            const mid = center(t.cur);
            const whole = o.contentRect(t.cur);
            const c = [4]f64{ mid[0] + (whole[0] - mid[0]) * land, mid[1] + (whole[1] - mid[1]) * land, whole[2] * land, whole[3] * land };
            // Only the part inside the window is named: while the zoom is close to one tab the
            // others lie outside it, and Hyprland blurs nothing at all when any part named does.
            const x0 = std.math.clamp(@round(left + (c[0] - v[0]) * k), 0, right);
            const y0 = std.math.clamp(@round(top + (c[1] - v[1]) * k), 0, bottom);
            const x1 = std.math.clamp(@round(left + (c[0] + c[2] - v[0]) * k), 0, right);
            const y1 = std.math.clamp(@round(top + (c[1] + c[3] - v[1]) * k), 0, bottom);
            if (x1 <= x0 or y1 <= y0) continue;
            now.append(gpa, .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 }) catch return;
        }
        if (o.frosting and std.mem.eql(u8, std.mem.sliceAsBytes(now.items), std.mem.sliceAsBytes(o.frosted.items))) return;
        std.mem.swap(std.ArrayList(wayland.Part), &now, &o.frosted);
        o.frosting = true;
        wayland.blurParts(surface, o.frosted.items);
    }

    /// Leaves the blur behind the window to the desktop again.
    fn frostAsUsual(o: *Overview) void {
        if (builtin.os.tag != .linux or !o.frosting) return;
        o.frosting = false;
        if (o.app.window.as(gtk.Native).getSurface()) |surface| wayland.blurAsUsual(surface);
    }

    fn draw(o: *Overview, sn: *gtk.Snapshot) void {
        const w = o.widget();
        if (o.size[0] < 1 or o.tiles.items.len == 0) return;
        // The zoom passes the grid a little as it settles; nothing is more than fully there.
        const out = std.math.clamp(o.zoom, 0, 1);
        // Without its background the window draws nothing behind the panes, and nothing is drawn
        // behind the grid either: each tab lies straight on the desktop, like a window of its own.
        // What belongs to the grid, its names, dots, ring and foot, comes in over the second
        // half of the zoom.
        const chrome = smooth((out - 0.5) / 0.5);
        var far: f64 = 1;
        if (o.focus < o.tiles.items.len) {
            const from = center(o.tiles.items[o.focus].rect);
            for (o.tiles.items) |t| {
                const at = center(t.rect);
                far = @max(far, std.math.hypot(at[0] - from[0], at[1] - from[1]));
            }
        }
        const v = o.viewRect();
        const k = o.size[0] / @max(1, v[2]);
        o.frost(v, k, far);
        sn.save();
        sn.scale(@floatCast(k), @floatCast(k));
        sn.translate(&.{ .f_x = @floatCast(-v[0]), .f_y = @floatCast(-v[1]) });
        // Each session's card lies under its tabs, and fades with the names.
        if (o.groups.items.len > 0 and chrome > 0.01) {
            sn.pushOpacity(chrome);
            for (o.groups.items) |g| w.snapshotChild(g.card, sn);
            sn.pop();
        }
        for (o.tiles.items, 0..) |*t, i| {
            const land = o.landing(i, far);
            if (land < 1) {
                sn.save();
                scaleAbout(sn, center(t.cur), land);
            }
            defer if (land < 1) sn.restore();
            if (t.alpha < 1) sn.pushOpacity(t.alpha);
            defer if (t.alpha < 1) sn.pop();
            // At rest a tab is its live preview, once there is one, faded in over the plain
            // card that stood for it. While the zoom runs, and until then, it is a picture,
            // or failing that the card.
            const root = if (!o.animating and !o.gliding and t.placed) t.root else null;
            if (root) |live| {
                if (t.live >= 1) {
                    w.snapshotChild(live, sn);
                    continue;
                }
                sn.pushCrossFade(t.live);
                o.drawStill(sn, t);
                sn.pop();
                w.snapshotChild(live, sn);
                sn.pop();
                continue;
            }
            o.drawStill(sn, t);
        }
        if (chrome > 0.01) {
            sn.pushOpacity(chrome);
            // A closed tab fades out where it was, as its last picture or a plain card.
            for (o.leaving.items) |t| {
                sn.pushOpacity(t.alpha);
                if (t.picture) |picture| {
                    const c = o.contentRect(t.cur);
                    sn.appendTexture(picture, &.{ .f_origin = .{ .f_x = @floatCast(c[0]), .f_y = @floatCast(c[1]) }, .f_size = .{ .f_width = @floatCast(c[2]), .f_height = @floatCast(c[3]) } });
                } else w.snapshotChild(t.blank, sn);
                sn.pop();
            }
            w.snapshotChild(o.ring, sn);
            sn.pop();
        }
        sn.restore();
        if (chrome <= 0.01) return;
        // The names, dots and hosts, and the foot. They are drawn at their own size: text
        // drawn at a new size every frame has every glyph made again each time, which is
        // slow. At the grid they are where the layout put them; while the zoom runs each
        // follows its tab, and the names rise the last of their way into place.
        sn.pushOpacity(chrome);
        const rise = name_rise * (1 - chrome);
        for (o.tiles.items, 0..) |t, i| {
            if (t.alpha < 1) sn.pushOpacity(t.alpha);
            defer if (t.alpha < 1) sn.pop();
            const name = t.label.as(gtk.Widget);
            const dots = t.badges.as(gtk.Widget);
            const host = t.host_chip.as(gtk.Widget);
            if (!o.animating) {
                inline for (.{ name, dots, host }) |mark| {
                    if (mark.getVisible() != 0) w.snapshotChild(mark, sn);
                }
                continue;
            }
            // Where the tab's panes are in the window now.
            const c = o.contentRect(shrunk(t.cur, o.landing(i, far)));
            const left = (c[0] - v[0]) * k;
            const right = (c[0] + c[2] - v[0]) * k;
            const top = (c[1] - v[1]) * k;
            const bottom = (c[1] + c[3] - v[1]) * k;
            o.drawAt(sn, name, .middle, (left + right) / 2, bottom + 10 + rise);
            o.drawAt(sn, dots, .right, right - 8, top + 8);
            o.drawAt(sn, host, .left, left + 8, top + 8);
        }
        for (o.groups.items) |g| {
            const name = g.label.as(gtk.Widget);
            if (!o.animating) {
                w.snapshotChild(name, sn);
                continue;
            }
            o.drawAt(sn, name, .middle, (g.rect[0] + g.rect[2] / 2 - v[0]) * k, (g.rect[1] + g.rect[3] - v[1]) * k + 10 + rise);
        }
        // The foot comes up from below as it appears.
        sn.save();
        sn.translate(&.{ .f_x = 0, .f_y = @floatCast(foot_rise * (1 - smooth(out))) });
        inline for (.{ o.group_button.as(gtk.Widget), o.hint.as(gtk.Widget) }) |foot| w.snapshotChild(foot, sn);
        sn.restore();
        sn.pop();
    }
};

/// A grid of same-sized cells, each the window's own shape, centered in an area.
const Grid = struct {
    n: usize,
    cols: usize,
    cell_w: f64,
    cell_h: f64,
    area: [4]f64,
    top: f64,
    between: f64,
    under: f64,

    /// As many columns as make the cells largest. `between` is the room between cells and
    /// `under` the room kept below each, for a name.
    fn fit(n: usize, area: [4]f64, shape: [2]f64, between: f64, under: f64) Grid {
        const count: f64 = @floatFromInt(@max(1, n));
        var cols: usize = 1;
        var scale: f64 = 0;
        for (1..@max(1, n) + 1) |c| {
            const cf: f64 = @floatFromInt(c);
            const rows = @ceil(count / cf);
            const w = (area[2] - (cf - 1) * between) / cf;
            const h = (area[3] - (rows - 1) * between) / rows - under;
            const s = @min(w / shape[0], h / shape[1]);
            if (s > scale) {
                scale = s;
                cols = c;
            }
        }
        scale = std.math.clamp(scale, 0.02, 0.86);
        const rows: f64 = @ceil(count / @as(f64, @floatFromInt(cols)));
        const cell_h = shape[1] * scale;
        const grid_h = rows * (cell_h + under) + (rows - 1) * between;
        return .{ .n = @max(1, n), .cols = cols, .cell_w = shape[0] * scale, .cell_h = cell_h, .area = area, .top = area[1] + @max(0, (area[3] - grid_h) / 2), .between = between, .under = under };
    }

    /// The place of cell `i`; the last row is centered when it is short.
    fn cell(g: Grid, i: usize) [4]f64 {
        const row = i / g.cols;
        const col = i % g.cols;
        const in_row: f64 = @floatFromInt(@min(g.cols, g.n - row * g.cols));
        const row_w = in_row * g.cell_w + (in_row - 1) * g.between;
        const left = g.area[0] + (g.area[2] - row_w) / 2;
        return .{
            @round(left + @as(f64, @floatFromInt(col)) * (g.cell_w + g.between)),
            @round(g.top + @as(f64, @floatFromInt(row)) * (g.cell_h + g.under + g.between)),
            g.cell_w,
            g.cell_h,
        };
    }
};

test "a grid's cells have the window's shape and stay inside the area" {
    const grid = Grid.fit(5, .{ 36, 36, 1368, 800 }, .{ 1440, 900 }, 28, 30);
    try std.testing.expect(grid.cols >= 2);
    for (0..5) |i| {
        const c = grid.cell(i);
        try std.testing.expectApproxEqAbs(@as(f64, 1.6), c[2] / c[3], 0.001);
        try std.testing.expect(c[0] >= 35 and c[0] + c[2] <= 36 + 1368 + 1);
        try std.testing.expect(c[1] >= 35 and c[1] + c[3] + 30 <= 36 + 800 + 1);
    }
}

/// A share of the way, 0 to 1, eased at both ends.
fn smooth(t: f64) f64 {
    const x = std.math.clamp(t, 0, 1);
    return x * x * (3 - 2 * x);
}

/// Scales what is drawn next about a point.
fn scaleAbout(sn: *gtk.Snapshot, about: [2]f64, by: f64) void {
    sn.translate(&.{ .f_x = @floatCast(about[0]), .f_y = @floatCast(about[1]) });
    sn.scale(@floatCast(by), @floatCast(by));
    sn.translate(&.{ .f_x = @floatCast(-about[0]), .f_y = @floatCast(-about[1]) });
}

/// What a tab's kept picture is filed under. Window IDs are only one server's own, so the
/// host and session are part of it.
fn thumbKey(buf: []u8, h: *app_mod.Host, session_id: []const u8, window_id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x}/{s}/{s}", .{ @intFromPtr(h), session_id, window_id }) catch window_id;
}

/// A widget's own size.
fn natural(w: *gtk.Widget) [2]f64 {
    var min: c_int = 0;
    var nat_w: c_int = 0;
    var nat_h: c_int = 0;
    w.measure(.horizontal, -1, &min, &nat_w, null, null);
    w.measure(.vertical, -1, &min, &nat_h, null, null);
    return .{ @floatFromInt(nat_w), @floatFromInt(nat_h) };
}

/// Places a name under a rectangle, centered, no wider than it.
fn placeUnder(label: *gtk.Widget, r: [4]f64) void {
    const size = natural(label);
    const w = @min(size[0], r[2]);
    place(label, w, size[1], @round(r[0] + (r[2] - w) / 2), @round(r[1] + r[3] + 10), 1);
}

/// A rectangle scaled about its middle.
fn shrunk(r: [4]f64, by: f64) [4]f64 {
    const w = r[2] * by;
    const h = r[3] * by;
    return .{ r[0] + (r[2] - w) / 2, r[1] + (r[3] - h) / 2, w, h };
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
