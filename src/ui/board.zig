//! The agent board: every pane on every host as a card in one of four columns, by what the
//! program in it reports: Idle, Running, Attention (it needs you, or it failed) and Done (it
//! finished and its pane hasn't been looked at since; after that it is Idle).
//! Cards move between columns as programs change state, and a click on one goes to its pane.
const std = @import("std");
const gtk = @import("gtk");
const gobject = @import("gobject");
const glib = @import("glib");
const app_mod = @import("../app/app.zig");
const settings = @import("../settings/settings.zig");
const blockicon = @import("../icons/blockicon.zig");
const icons = @import("../icons/icons.zig");
const programs = @import("../icons/programs.zig");
const art = @import("../settings/settings_art.zig");
const TermView = @import("../terminal/termview.zig").TermView;

const gpa = std.heap.c_allocator;

const Column = enum(usize) { idle, running, attention, done };
const column_names = [_][:0]const u8{ "Idle", "Running", "Attention", "Done" };
const column_empty = [_][:0]const u8{ "No idle agents", "Nothing is running", "Nothing needs you", "Nothing has finished" };

const Card = struct {
    board: *Board,
    host: *app_mod.Host,
    session_id: [:0]u8,
    window_id: [:0]u8,
    block_id: [:0]u8,
    button: *gtk.Button,
    icon_slot: *gtk.Box,
    title: *gtk.Label,
    chip: *gtk.Label,
    message: *gtk.Label,
    where: *gtk.Label,
    since: *gtk.Label,
    progress: *gtk.ProgressBar,
    column: ?Column = null,
    /// Set when the card changed column in the last pass, for it to arrive with a small move.
    moved: bool = false,
    /// When its status last changed, to put the latest first.
    since_us: i64 = 0,
    /// Where its session comes in the sidebar's order, and the session's name.
    session_rank: usize = 0,
    session_label: [96]u8 = undefined,
    session_label_len: usize = 0,
    /// What the icon was drawn for, so it is only made again when that changes.
    icon_key: u64 = 0,
    seen: bool = true,

    fn free(c: *Card) void {
        c.button.as(gobject.Object).unref();
        gpa.free(c.session_id);
        gpa.free(c.window_id);
        gpa.free(c.block_id);
        gpa.destroy(c);
    }
};

pub const Board = struct {
    app: *app_mod.App,
    revealer: *gtk.Revealer,
    lists: [4]*gtk.Box = undefined,
    counts: [4]*gtk.Label = undefined,
    heading: *gtk.Widget = undefined,
    empties: [4]*gtk.Widget = undefined,
    /// What each column's list holds now, as a hash of its rows in order, so a list is only
    /// laid out again when its rows or their order change.
    laid_out: [4]u64 = .{ 0, 0, 0, 0 },
    cards: std.ArrayList(*Card) = .empty,
    refresh_source: c_uint = 0,
    clock: c_uint = 0,

    pub fn create(a: *app_mod.App) *Board {
        const b = gpa.create(Board) catch @panic("out of memory");
        b.* = .{ .app = a, .revealer = gtk.Revealer.new() };
        b.revealer.setTransitionType(.crossfade);
        b.revealer.setTransitionDuration(160);

        const page = gtk.Box.new(.vertical, 12);
        page.as(gtk.Widget).addCssClass("board");
        const head = gtk.Box.new(.horizontal, 8);
        const title = gtk.Label.new("Agents");
        title.as(gtk.Widget).addCssClass("board-title");
        title.setXalign(0);
        title.as(gtk.Widget).setHexpand(1);
        head.append(title.as(gtk.Widget));
        b.heading = title.as(gtk.Widget);
        // All cards in one run per column, or under the name of the session each is in.
        const by = gtk.Box.new(.horizontal, 0);
        by.as(gtk.Widget).addCssClass("linked");
        by.as(gtk.Widget).addCssClass("board-grouping");
        by.as(gtk.Widget).setValign(.center);
        const all = gtk.ToggleButton.newWithLabel("All");
        const by_session = gtk.ToggleButton.newWithLabel("By Session");
        by_session.setGroup(all);
        (if (settings.current.board_by_session) by_session else all).setActive(1);
        by.append(all.as(gtk.Widget));
        by.append(by_session.as(gtk.Widget));
        _ = gtk.ToggleButton.signals.toggled.connect(by_session, *Board, &groupingToggled, b, .{});
        head.append(by.as(gtk.Widget));
        const close = icons.button(.close, "Back to the panes", null);
        _ = gtk.Button.signals.clicked.connect(close, *Board, &closeClicked, b, .{});
        head.append(close.as(gtk.Widget));
        page.append(head.as(gtk.Widget));

        const columns = gtk.Box.new(.horizontal, 10);
        columns.setHomogeneous(1);
        columns.as(gtk.Widget).setVexpand(1);
        inline for (comptime std.enums.values(Column), 0..) |col, i| {
            const column = gtk.Box.new(.vertical, 8);
            column.as(gtk.Widget).addCssClass("board-column");
            const top = gtk.Box.new(.horizontal, 8);
            top.as(gtk.Widget).addCssClass("board-column-head");
            top.append(switch (col) {
                .idle => art.status(.idle),
                .running => art.status(.working),
                .attention => art.status(.blocked),
                .done => art.status(.done),
            });
            const name = gtk.Label.new(column_names[i].ptr);
            name.as(gtk.Widget).addCssClass("board-column-title");
            name.setXalign(0);
            name.as(gtk.Widget).setHexpand(1);
            top.append(name.as(gtk.Widget));
            b.counts[i] = gtk.Label.new("0");
            b.counts[i].as(gtk.Widget).addCssClass("board-count");
            top.append(b.counts[i].as(gtk.Widget));
            column.append(top.as(gtk.Widget));

            const empty = gtk.Label.new(column_empty[i].ptr);
            empty.as(gtk.Widget).addCssClass("board-empty");
            b.empties[i] = empty.as(gtk.Widget);
            b.lists[i] = gtk.Box.new(.vertical, 8);
            const inner = gtk.Box.new(.vertical, 0);
            inner.append(b.lists[i].as(gtk.Widget));
            inner.append(b.empties[i]);
            const scroller = gtk.ScrolledWindow.new();
            scroller.setPolicy(.never, .automatic);
            scroller.as(gtk.Widget).setVexpand(1);
            scroller.setChild(inner.as(gtk.Widget));
            column.append(scroller.as(gtk.Widget));
            columns.append(column.as(gtk.Widget));
        }
        page.append(columns.as(gtk.Widget));
        b.revealer.setChild(page.as(gtk.Widget));
        return b;
    }

    /// Moves the heading clear of the window's corner buttons, which lie over the board's
    /// top left while the sidebar is hidden or narrower than they are.
    pub fn setInset(b: *Board, px: c_int) void {
        // The board has its own padding, which already covers part of the way.
        const want = @max(0, px - 14);
        if (b.heading.getMarginStart() != want) b.heading.setMarginStart(want);
    }

    pub fn widget(b: *Board) *gtk.Widget {
        return b.revealer.as(gtk.Widget);
    }

    pub fn shown(b: *Board) bool {
        return b.revealer.getRevealChild() != 0;
    }

    pub fn toggle(b: *Board) void {
        b.show(!b.shown());
    }

    pub fn show(b: *Board, on: bool) void {
        if (on == b.shown()) return;
        if (on) {
            b.refresh();
            // "4 min" under each card is kept up to date while the board is open.
            b.clock = glib.timeoutAddSeconds(20, &ticked, b);
        } else if (b.clock != 0) {
            _ = glib.Source.remove(b.clock);
            b.clock = 0;
        }
        // Hidden, the board lets the pointer through to the panes under it.
        b.widget().setCanTarget(@intFromBool(on));
        b.revealer.setRevealChild(@intFromBool(on));
    }

    fn groupingToggled(button: *gtk.ToggleButton, b: *Board) callconv(.c) void {
        const on = button.getActive() != 0;
        if (on == settings.current.board_by_session) return;
        settings.current.board_by_session = on;
        settings.save();
        b.refresh();
    }

    fn closeClicked(_: *gtk.Button, b: *Board) callconv(.c) void {
        b.app.showBoard(false);
    }

    fn ticked(data: ?*anyopaque) callconv(.c) c_int {
        const b: *Board = @ptrCast(@alignCast(data.?));
        b.refresh();
        return 1;
    }

    /// Something a program reports changed; the board catches up on the next idle moment.
    pub fn changed(b: *Board) void {
        if (!b.shown() or b.refresh_source != 0) return;
        b.refresh_source = glib.idleAdd(&refreshLater, b);
    }

    fn refreshLater(data: ?*anyopaque) callconv(.c) c_int {
        const b: *Board = @ptrCast(@alignCast(data.?));
        b.refresh_source = 0;
        b.refresh();
        return 0;
    }

    /// A host is gone: its cards go at once, since each holds a pointer to it.
    pub fn hostRemoved(b: *Board) void {
        b.refresh();
    }

    /// Brings the cards in line with what every pane reports now: new panes get a card, a
    /// pane that closed loses its card, and a card whose program changed state moves column.
    pub fn refresh(b: *Board) void {
        for (b.cards.items) |c| c.seen = false;
        var rank: usize = 0;
        for (b.app.hosts.items) |h| {
            const s = h.server;
            for (s.sessions.items) |session| {
                rank += 1;
                const v = s.sessionView(session.id) orelse continue;
                for (v.windows) |w| for (w.layers) |l| for (l.blocks) |blk| {
                    if (!blk.isTerminal()) continue;
                    // Only agents are on the board: a pane that reports a status, or runs a
                    // program known to be one. Plain shells and editors stay off it.
                    const info = s.blockInfo(blk.id) orelse continue;
                    if (!info.has_status and !programs.isAgent(info.program)) continue;
                    const c = b.cardFor(h, session.id, w.id, blk.id) orelse continue;
                    c.seen = true;
                    c.session_rank = rank;
                    b.fill(c, if (session.label.len > 0) session.label else "session");
                };
            }
        }
        var i: usize = 0;
        while (i < b.cards.items.len) {
            const c = b.cards.items[i];
            if (c.seen) {
                i += 1;
                continue;
            }
            if (c.button.as(gtk.Widget).getParent()) |parent| @as(*gtk.Box, @ptrCast(parent)).remove(c.button.as(gtk.Widget));
            _ = b.cards.swapRemove(i);
            c.free();
        }
        b.layout();
        var totals = [_]usize{ 0, 0, 0, 0 };
        for (b.cards.items) |c| if (c.column) |col| {
            totals[@intFromEnum(col)] += 1;
        };
        for (totals, 0..) |n, k| {
            var buf: [16]u8 = undefined;
            const text: [:0]const u8 = std.fmt.bufPrintSentinel(&buf, "{d}", .{n}, 0) catch "";
            b.counts[k].setText(text.ptr);
            b.empties[k].setVisible(@intFromBool(n == 0));
        }
    }

    fn cardFor(b: *Board, h: *app_mod.Host, session_id: []const u8, window_id: []const u8, block_id: []const u8) ?*Card {
        for (b.cards.items) |c| if (c.host == h and std.mem.eql(u8, c.block_id, block_id)) {
            // A pane can move to another window or session and keep its card.
            if (!std.mem.eql(u8, c.window_id, window_id)) replace(&c.window_id, window_id);
            if (!std.mem.eql(u8, c.session_id, session_id)) replace(&c.session_id, session_id);
            return c;
        };
        const c = gpa.create(Card) catch return null;
        const button = gtk.Button.new();
        // The card keeps its button while it moves from one column's list to another's.
        _ = button.as(gobject.Object).refSink();
        button.as(gtk.Widget).addCssClass("board-card");
        button.as(gtk.Widget).addCssClass("flat");
        const body = gtk.Box.new(.vertical, 4);
        const top = gtk.Box.new(.horizontal, 8);
        const icon_slot = gtk.Box.new(.horizontal, 0);
        icon_slot.as(gtk.Widget).setValign(.center);
        top.append(icon_slot.as(gtk.Widget));
        const title = gtk.Label.new("");
        title.setXalign(0);
        title.setEllipsize(.end);
        title.as(gtk.Widget).setHexpand(1);
        title.as(gtk.Widget).addCssClass("board-card-title");
        top.append(title.as(gtk.Widget));
        const chip = gtk.Label.new("");
        chip.as(gtk.Widget).addCssClass("hover-chip");
        chip.as(gtk.Widget).addCssClass("failed");
        chip.as(gtk.Widget).setValign(.center);
        top.append(chip.as(gtk.Widget));
        body.append(top.as(gtk.Widget));
        const message = gtk.Label.new("");
        message.setXalign(0);
        message.setWrap(1);
        message.setWrapMode(.word_char);
        message.setLines(2);
        message.setEllipsize(.end);
        message.as(gtk.Widget).addCssClass("board-card-message");
        body.append(message.as(gtk.Widget));
        const progress = gtk.ProgressBar.new();
        progress.as(gtk.Widget).addCssClass("board-card-progress");
        body.append(progress.as(gtk.Widget));
        const foot = gtk.Box.new(.horizontal, 8);
        const where = gtk.Label.new("");
        where.setXalign(0);
        where.setEllipsize(.middle);
        where.as(gtk.Widget).setHexpand(1);
        where.as(gtk.Widget).addCssClass("board-card-meta");
        foot.append(where.as(gtk.Widget));
        const since = gtk.Label.new("");
        since.as(gtk.Widget).addCssClass("board-card-meta");
        foot.append(since.as(gtk.Widget));
        body.append(foot.as(gtk.Widget));
        button.setChild(body.as(gtk.Widget));
        c.* = .{
            .board = b,
            .host = h,
            .session_id = gpa.dupeSentinel(u8, session_id, 0) catch return null,
            .window_id = gpa.dupeSentinel(u8, window_id, 0) catch return null,
            .block_id = gpa.dupeSentinel(u8, block_id, 0) catch return null,
            .button = button,
            .icon_slot = icon_slot,
            .title = title,
            .chip = chip,
            .message = message,
            .where = where,
            .since = since,
            .progress = progress,
        };
        _ = gtk.Button.signals.clicked.connect(button, *Card, &cardClicked, c, .{});
        b.cards.append(gpa, c) catch return null;
        return c;
    }

    fn replace(slot: *[:0]u8, value: []const u8) void {
        const copy = gpa.dupeSentinel(u8, value, 0) catch return;
        gpa.free(slot.*);
        slot.* = copy;
    }

    /// Writes a card's text from what its pane reports, and puts it in the column for it.
    fn fill(_: *Board, c: *Card, session_label: []const u8) void {
        const s = c.host.server;
        const info = s.blockInfo(c.block_id);
        var buf: [320]u8 = undefined;
        var zbuf: [321]u8 = undefined;

        const prog: ?[]const u8 = if (info) |i| ((if (i.has_status) i.status_app else null) orelse i.program) else null;
        // A shell's own title is only its prompt's idea of one, so a shell goes by its name.
        const is_shell = if (prog) |p| TermView.isShell(programs.programName(p)) else true;
        const own_title: ?[]const u8 = if (is_shell) null else if (info) |i| (if (i.title) |t| (if (t.len > 0) t else null) else null) else null;
        // An agent's name for its task says most; then its own title; then what runs there.
        const task: ?[]const u8 = if (info) |i| (if (i.has_status) (if (i.task) |t| (if (t.len > 0) t else null) else null) else null) else null;
        setLabel(c.title, zt(&zbuf, task orelse own_title orelse programs.displayTitle(&buf, prog, null)));

        const status = if (info) |i| (if (i.has_status) i.status else .other) else .other;
        const unread = if (info) |i| i.attention else false;
        const col: Column = switch (status) {
            .working => .running,
            .blocked, .failed => .attention,
            // Finished, it waits in Done until its pane has been shown and focused, as the
            // sidebar's dot does; then it's simply idle.
            .done => if (unread) .done else .idle,
            .other => .idle,
        };
        c.chip.as(gtk.Widget).setVisible(@intFromBool(status == .failed));
        if (status == .failed) setLabel(c.chip, "Failed");

        // What it says about itself, or failing that what kind of thing it waits on.
        const said: ?[]const u8 = if (info) |i| (if (i.message) |m| (if (m.len > 0) m else null) else null) else null;
        const kind: ?[]const u8 = if (info) |i| (if (!i.has_status) null else if (i.status_kind) |k| (if (std.mem.eql(u8, k, "permission")) "permission prompt" else if (k.len > 0) k else null) else null) else null;
        const line = said orelse kind;
        c.message.as(gtk.Widget).setVisible(@intFromBool(line != null));
        if (line) |text| setLabel(c.message, zt(&zbuf, text));

        const shows_progress = status == .working and if (info) |i| (i.progress != null and i.progress.? >= 0) else false;
        c.progress.as(gtk.Widget).setVisible(@intFromBool(shows_progress));
        if (shows_progress) c.progress.setFraction(@as(f64, @floatFromInt(info.?.progress.?)) / 100.0);

        const folder: ?[]const u8 = if (info) |i| (if (i.folder) |f| programs.shortFolder(&buf, f) else null) else null;
        // Under its session's name a card only says where in it; otherwise the session too.
        const where = if (settings.current.board_by_session)
            zt(&zbuf, folder orelse "")
        else if (folder) |f|
            std.fmt.bufPrintSentinel(&zbuf, "{s} · {s}", .{ session_label, f }, 0) catch ""
        else
            zt(&zbuf, session_label);
        setLabel(c.where, where);
        c.session_label_len = @min(session_label.len, c.session_label.len);
        @memcpy(c.session_label[0..c.session_label_len], session_label[0..c.session_label_len]);

        const since_us: i64 = if (info) |i| i.since else 0;
        c.since_us = since_us;
        setLabel(c.since, if (col == .idle) "" else ago(&zbuf, since_us));

        // The icon carries the program and its status dot; it is made again when either changes.
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(prog orelse "");
        hasher.update(std.mem.asBytes(&status));
        const key = hasher.final() | 1;
        if (key != c.icon_key) {
            c.icon_key = key;
            while (c.icon_slot.as(gtk.Widget).getFirstChild()) |old| c.icon_slot.remove(old);
            c.icon_slot.append(blockicon.create(s, c.block_id, 20));
        }

        if (c.column != col) {
            // Arriving in a new column, the card comes in with a small move; the cards a
            // freshly opened board starts with just appear.
            c.moved = c.column != null;
            c.column = col;
            const w = c.button.as(gtk.Widget);
            inline for (.{ "idle", "running", "attention", "done" }, 0..) |name, k| {
                if (k == @intFromEnum(col)) w.addCssClass(name) else w.removeCssClass(name);
            }
        }
    }

    /// Puts each column's cards in order: the latest change first, and with grouping on,
    /// under the name of the session each is in, sessions in the sidebar's order. A column
    /// whose rows are already right is left alone, so nothing under the pointer flickers.
    fn layout(b: *Board) void {
        const grouped = settings.current.board_by_session;
        const Order = struct {
            fn before(by_session: bool, x: *Card, y: *Card) bool {
                if (by_session and x.session_rank != y.session_rank) return x.session_rank < y.session_rank;
                if (x.since_us != y.since_us) return x.since_us > y.since_us;
                return @intFromPtr(x) < @intFromPtr(y);
            }
        };
        var sorted: std.ArrayList(*Card) = .empty;
        defer sorted.deinit(gpa);
        for (0..4) |k| {
            sorted.clearRetainingCapacity();
            for (b.cards.items) |c| if (c.column) |col| {
                if (@intFromEnum(col) == k) sorted.append(gpa, c) catch {};
            };
            std.mem.sort(*Card, sorted.items, grouped, Order.before);
            var hasher = std.hash.Wyhash.init(@intFromBool(grouped));
            for (sorted.items) |c| {
                hasher.update(std.mem.asBytes(&c));
                if (grouped) hasher.update(c.session_label[0..c.session_label_len]);
            }
            const sig = hasher.final() | 1;
            const list = b.lists[k];
            if (sig != b.laid_out[k]) {
                b.laid_out[k] = sig;
                while (list.as(gtk.Widget).getFirstChild()) |child| list.remove(child);
                var last_rank: usize = 0;
                for (sorted.items) |c| {
                    if (grouped and c.session_rank != last_rank) {
                        last_rank = c.session_rank;
                        var zbuf: [97]u8 = undefined;
                        const name = gtk.Label.new(zt(&zbuf, c.session_label[0..c.session_label_len]).ptr);
                        name.setXalign(0);
                        name.setEllipsize(.end);
                        name.as(gtk.Widget).addCssClass("board-session");
                        list.append(name.as(gtk.Widget));
                    }
                    // A card moving left, as from Done to Idle, is still in the list of the column
                    // it left, which is laid out after this one; GTK won't add it here until it
                    // leaves there, and it would end up in neither.
                    const w = c.button.as(gtk.Widget);
                    if (w.getParent()) |parent| @as(*gtk.Box, @ptrCast(parent)).remove(w);
                    list.append(w);
                }
            }
            for (sorted.items) |c| {
                const w = c.button.as(gtk.Widget);
                if (c.moved) {
                    w.removeCssClass("arrived");
                    w.addCssClass("arrived");
                    c.moved = false;
                }
            }
        }
    }

    fn setLabel(label: *gtk.Label, text: [:0]const u8) void {
        if (!std.mem.eql(u8, std.mem.span(label.getText()), text)) label.setText(text.ptr);
    }

    fn cardClicked(_: *gtk.Button, c: *Card) callconv(.c) void {
        const b = c.board;
        // Only a host that is still here; a card can outlive its host by a moment.
        if (std.mem.indexOfScalar(*app_mod.Host, b.app.hosts.items, c.host) == null) return;
        b.app.showBoard(false);
        b.app.jumpTo(c.host, c.session_id, c.window_id, c.block_id);
    }
};

/// How long ago a moment on the monotonic clock was, in a word: "now", "4 min", "2 h", "3 d".
/// Empty for a moment that was never set.
pub fn ago(buf: []u8, since_us: i64) [:0]const u8 {
    if (since_us == 0) return "";
    const mins = @divTrunc(glib.getMonotonicTime() - since_us, 60 * std.time.us_per_s);
    if (mins < 1) return "now";
    if (mins < 60) return std.fmt.bufPrintSentinel(buf, "{d} min", .{mins}, 0) catch "";
    if (mins < 24 * 60) return std.fmt.bufPrintSentinel(buf, "{d} h", .{@divTrunc(mins, 60)}, 0) catch "";
    return std.fmt.bufPrintSentinel(buf, "{d} d", .{@divTrunc(mins, 24 * 60)}, 0) catch "";
}

/// `text` with the zero at its end that GTK reads to, cut short if it's longer than `buf`.
fn zt(buf: []u8, text: []const u8) [:0]const u8 {
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}
