//! The activity panel, like Rex's: what every program on every host is doing, with the ones
//! that need you first. Programs report their state with OSC 7501; a click jumps to the pane.
const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
const glib = @import("glib");
const app_mod = @import("../app/app.zig");
const settings = @import("../settings/settings.zig");
const blockicon = @import("../icons/blockicon.zig");
const programs = @import("../icons/programs.zig");
const Server = @import("../rex/server.zig").Server;
const StatusKind = @import("../rex/server.zig").StatusKind;

const gpa = std.heap.c_allocator;

pub const Grouping = enum { priority, session };

const Item = struct {
    host: *app_mod.Host,
    session_id: []const u8,
    session_label: []const u8,
    window_id: []const u8,
    block_id: []const u8,
    rank: u8,
};

/// One row's target, kept on the row until it is clicked.
const Target = struct { host: *app_mod.Host, session_id: [:0]u8, window_id: [:0]u8, block_id: [:0]u8 };

pub const Activity = struct {
    app: *app_mod.App,
    revealer: *gtk.Revealer,
    list: *gtk.ListBox,
    grouping: Grouping = .priority,
    show_idle: bool = false,
    rebuild_source: c_uint = 0,
    targets: std.ArrayList(*Target) = .empty,

    pub fn create(a: *app_mod.App) *Activity {
        const act = gpa.create(Activity) catch @panic("out of memory");
        const revealer = gtk.Revealer.new();
        revealer.setTransitionType(.slide_left);
        revealer.setTransitionDuration(220);
        revealer.as(gtk.Widget).setHalign(.end);
        const panel = gtk.Box.new(.vertical, 0);
        panel.as(gtk.Widget).addCssClass("activity-panel");
        panel.as(gtk.Widget).setSizeRequest(300, -1);

        const head = gtk.Box.new(.horizontal, 6);
        head.as(gtk.Widget).addCssClass("activity-head");
        const title = gtk.Label.new("Activity");
        title.as(gtk.Widget).addCssClass("activity-title");
        title.setXalign(0);
        title.as(gtk.Widget).setHexpand(1);
        head.append(title.as(gtk.Widget));
        const by = gtk.Box.new(.horizontal, 0);
        by.as(gtk.Widget).addCssClass("linked");
        const by_priority = gtk.ToggleButton.newWithLabel("Priority");
        const by_session = gtk.ToggleButton.newWithLabel("Session");
        by_session.setGroup(by_priority);
        by_priority.setActive(1);
        by.append(by_priority.as(gtk.Widget));
        by.append(by_session.as(gtk.Widget));
        head.append(by.as(gtk.Widget));
        panel.append(head.as(gtk.Widget));

        const idle = gtk.CheckButton.newWithLabel("Show idle programs");
        idle.as(gtk.Widget).addCssClass("activity-idle");
        panel.append(idle.as(gtk.Widget));

        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("activity-list");
        list.setSelectionMode(.none);
        list.setActivateOnSingleClick(1);
        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .automatic);
        scroller.as(gtk.Widget).setVexpand(1);
        scroller.setChild(list.as(gtk.Widget));
        panel.append(scroller.as(gtk.Widget));
        revealer.setChild(panel.as(gtk.Widget));

        act.* = .{ .app = a, .revealer = revealer, .list = list };
        _ = gtk.ToggleButton.signals.toggled.connect(by_session, *Activity, &groupingToggled, act, .{});
        _ = gtk.CheckButton.signals.toggled.connect(idle, *Activity, &idleToggled, act, .{});
        _ = gtk.ListBox.signals.row_activated.connect(list, *Activity, &rowActivated, act, .{});
        return act;
    }

    pub fn widget(act: *Activity) *gtk.Widget {
        return act.revealer.as(gtk.Widget);
    }

    pub fn shown(act: *Activity) bool {
        return act.revealer.getRevealChild() != 0;
    }

    pub fn toggle(act: *Activity) void {
        const show = !act.shown();
        if (show) act.rebuild();
        act.revealer.setRevealChild(@intFromBool(show));
    }

    pub fn setGrouping(act: *Activity, g: Grouping) void {
        act.grouping = g;
        if (!act.shown()) act.toggle() else act.rebuild();
    }

    /// A host is gone: its rows go at once, since each holds a pointer to it.
    pub fn hostRemoved(act: *Activity) void {
        act.rebuild();
    }

    /// Something a program reports changed; the panel catches up on the next idle moment.
    pub fn changed(act: *Activity) void {
        if (!act.shown() or act.rebuild_source != 0) return;
        act.rebuild_source = glib.idleAdd(&rebuildLater, act);
    }

    fn rebuildLater(data: ?*anyopaque) callconv(.c) c_int {
        const act: *Activity = @ptrCast(@alignCast(data.?));
        act.rebuild_source = 0;
        act.rebuild();
        return 0;
    }

    fn groupingToggled(b: *gtk.ToggleButton, act: *Activity) callconv(.c) void {
        act.grouping = if (b.getActive() != 0) .session else .priority;
        act.rebuild();
    }

    fn idleToggled(b: *gtk.CheckButton, act: *Activity) callconv(.c) void {
        act.show_idle = b.getActive() != 0;
        act.rebuild();
    }

    /// Lower ranks need the person more: blocked, then failed, working, done, then idle.
    fn rankOf(info: anytype) u8 {
        if (!info.has_status) return 5;
        return switch (info.status) {
            .blocked => 0,
            .failed => 1,
            .working => 2,
            .done => 3,
            .other => 4,
        };
    }

    fn rebuild(act: *Activity) void {
        const list_w = act.list.as(gtk.Widget);
        while (list_w.getFirstChild()) |c| act.list.remove(c);
        for (act.targets.items) |t| freeTarget(t);
        act.targets.clearRetainingCapacity();

        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(gpa);
        for (act.app.hosts.items) |h| {
            const s = h.server;
            for (s.sessions.items) |session| {
                const v = s.sessionView(session.id) orelse continue;
                for (v.windows) |w| for (w.layers) |l| for (l.blocks) |b| {
                    const info = s.blockInfo(b.id) orelse continue;
                    const rank = rankOf(info);
                    if (rank >= 4 and !act.show_idle) continue;
                    items.append(gpa, .{ .host = h, .session_id = session.id, .session_label = if (session.label.len > 0) session.label else session.id, .window_id = w.id, .block_id = b.id, .rank = rank }) catch return;
                };
            }
        }
        const Sort = struct {
            fn byPriority(_: void, x: Item, y: Item) bool {
                if (x.rank != y.rank) return x.rank < y.rank;
                return std.mem.lessThan(u8, x.session_label, y.session_label);
            }
            fn bySession(_: void, x: Item, y: Item) bool {
                const o = std.mem.order(u8, x.session_label, y.session_label);
                if (o != .eq) return o == .lt;
                return x.rank < y.rank;
            }
        };
        if (act.grouping == .priority) std.mem.sort(Item, items.items, {}, Sort.byPriority) else std.mem.sort(Item, items.items, {}, Sort.bySession);

        if (items.items.len == 0) {
            const empty = gtk.Label.new(if (act.show_idle) "No programs are running" else "No programs are reporting activity");
            empty.as(gtk.Widget).addCssClass("dim-label");
            empty.as(gtk.Widget).setMarginTop(24);
            const row = gtk.ListBoxRow.new();
            row.setActivatable(0);
            row.setChild(empty.as(gtk.Widget));
            act.list.append(row.as(gtk.Widget));
            return;
        }
        var last_heading: []const u8 = "";
        for (items.items) |it| {
            const heading: []const u8 = if (act.grouping == .session) it.session_label else switch (it.rank) {
                0 => "Needs you",
                1 => "Failed",
                2 => "Working",
                3 => "Done",
                else => "Idle",
            };
            if (!std.mem.eql(u8, heading, last_heading)) {
                last_heading = heading;
                const z = gpa.dupeSentinel(u8, heading, 0) catch continue;
                defer gpa.free(z);
                const label = gtk.Label.new(z.ptr);
                label.as(gtk.Widget).addCssClass("activity-heading");
                label.setXalign(0);
                const row = gtk.ListBoxRow.new();
                row.setActivatable(0);
                row.setChild(label.as(gtk.Widget));
                act.list.append(row.as(gtk.Widget));
            }
            act.addRow(it);
        }
    }

    fn addRow(act: *Activity, it: Item) void {
        const s = it.host.server;
        const info = s.blockInfo(it.block_id) orelse return;
        const line = gtk.Box.new(.horizontal, 10);
        line.append(blockicon.create(s, it.block_id, 18));
        const text = gtk.Box.new(.vertical, 1);
        text.as(gtk.Widget).setHexpand(1);
        var tbuf: [256]u8 = undefined;
        var zbuf: [257]u8 = undefined;
        // The app that reported, such as claude, says more than the shell it runs in.
        const prog = (if (info.has_status) info.status_app else null) orelse info.program;
        const title = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{programs.displayTitle(&tbuf, prog, info.folder)}, 0) catch "program";
        const top = gtk.Label.new(title.ptr);
        top.setXalign(0);
        top.setEllipsize(.end);
        top.as(gtk.Widget).addCssClass("activity-name");
        text.append(top.as(gtk.Widget));
        var mbuf: [320]u8 = undefined;
        const state = switch (info.status) {
            .blocked => "Needs you",
            .failed => "Failed",
            .working => "Working",
            .done => "Done",
            .other => "Idle",
        };
        const where = if (act.grouping == .priority) it.session_label else "";
        const detail = if (info.message) |m|
            std.fmt.bufPrintSentinel(&mbuf, "{s}{s}{s}", .{ m, if (where.len > 0) " · " else "", where }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&mbuf, "{s}{s}{s}", .{ if (info.has_status) state else "Idle", if (where.len > 0) " · " else "", where }, 0) catch "";
        const bottom = gtk.Label.new(detail.ptr);
        bottom.setXalign(0);
        bottom.setEllipsize(.end);
        bottom.as(gtk.Widget).addCssClass("activity-detail");
        text.append(bottom.as(gtk.Widget));
        line.append(text.as(gtk.Widget));
        if (info.attention) {
            const dot = gtk.Box.new(.horizontal, 0);
            dot.as(gtk.Widget).addCssClass("activity-unread");
            dot.as(gtk.Widget).setValign(.center);
            line.append(dot.as(gtk.Widget));
        }
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("activity-row");
        row.as(gtk.Widget).addCssClass(switch (info.status) {
            .blocked => "blocked",
            .failed => "failed",
            .working => "working",
            .done => "done",
            .other => "idle",
        });
        row.setChild(line.as(gtk.Widget));
        const t = gpa.create(Target) catch return;
        t.* = .{
            .host = it.host,
            .session_id = gpa.dupeSentinel(u8, it.session_id, 0) catch return,
            .window_id = gpa.dupeSentinel(u8, it.window_id, 0) catch return,
            .block_id = gpa.dupeSentinel(u8, it.block_id, 0) catch return,
        };
        act.targets.append(gpa, t) catch return;
        gobject.Object.setData(row.as(gobject.Object), "target", t);
        act.list.append(row.as(gtk.Widget));
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, act: *Activity) callconv(.c) void {
        const data = gobject.Object.getData(row.as(gobject.Object), "target") orelse return;
        const t: *Target = @ptrCast(@alignCast(data));
        // Only a host that is still here; a row can outlive its host by a moment.
        if (std.mem.indexOfScalar(*app_mod.Host, act.app.hosts.items, t.host) == null) return;
        act.app.jumpTo(t.host, t.session_id, t.window_id, t.block_id);
    }

    fn freeTarget(t: *Target) void {
        gpa.free(t.session_id);
        gpa.free(t.window_id);
        gpa.free(t.block_id);
        gpa.destroy(t);
    }
};
