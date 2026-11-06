//! The command palette: the person's Rex actions, with the keys their config binds to them, and
//! Compy's own. Typing filters; Enter or a click runs the action on the focused pane.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const Server = @import("server.zig").Server;

const gpa = std.heap.c_allocator;

/// Compy's own actions, run through the app's action names.
const local = [_]struct { title: [:0]const u8, action: [:0]const u8, words: []const u8 }{
    .{ .title = "Split right", .action = "app.split-right", .words = "pane new horizontal" },
    .{ .title = "Split down", .action = "app.split-down", .words = "pane new vertical" },
    .{ .title = "Float or minimize pane", .action = "app.pane-float-focused", .words = "floating layer" },
    .{ .title = "Zoom pane", .action = "app.zoom-pane", .words = "maximize fullscreen" },
    .{ .title = "Close pane", .action = "app.close-pane", .words = "kill" },
    .{ .title = "Find in pane", .action = "app.find", .words = "search" },
    .{ .title = "New window", .action = "app.new-window", .words = "tab" },
    .{ .title = "New session", .action = "app.new-session", .words = "" },
    .{ .title = "Toggle sidebar", .action = "app.toggle-sidebar", .words = "hide show" },
    .{ .title = "Tight layout", .action = "app.tight", .words = "compact tmux relaxed" },
    .{ .title = "Settings", .action = "app.settings", .words = "preferences font" },
};

const Item = struct {
    row: *gtk.ListBoxRow,
    haystack: []u8,
    rex_index: ?usize,
    local_index: ?usize,
};

pub const Palette = struct {
    dialog: *adw.Dialog,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    items: std.ArrayList(Item) = .empty,
    server: *Server,
    app: *gtk.Application,
    session_id: []u8,
    block_id: ?[]u8,

    pub fn open(server: *Server, app: *gtk.Application, parent: *gtk.Widget, session_id: []const u8, block_id: ?[]const u8) void {
        const p = gpa.create(Palette) catch return;
        p.* = .{
            .dialog = adw.Dialog.new(),
            .entry = gtk.SearchEntry.new(),
            .list = gtk.ListBox.new(),
            .server = server,
            .app = app,
            .session_id = gpa.dupe(u8, session_id) catch return,
            .block_id = if (block_id) |b| gpa.dupe(u8, b) catch null else null,
        };
        p.dialog.setContentWidth(560);
        p.dialog.setContentHeight(480);
        p.dialog.setTitle("Commands");
        p.entry.setPlaceholderText("Run a command");
        p.list.as(gtk.Widget).addCssClass("navigation-sidebar");
        p.list.setActivateOnSingleClick(1);
        _ = gtk.ListBox.signals.row_activated.connect(p.list, *Palette, &activated, p, .{});
        _ = gtk.SearchEntry.signals.search_changed.connect(p.entry, *Palette, &changed, p, .{});
        _ = gtk.SearchEntry.signals.activate.connect(p.entry, *Palette, &enter, p, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(p.entry, *Palette, &stop, p, .{});
        _ = adw.Dialog.signals.closed.connect(p.dialog, *Palette, &closed, p, .{});

        for (server.actions, 0..) |a, i| p.add(a.title, a.category, a.keys, a.keywords, a.name, i, null);
        for (local, 0..) |l, i| p.add(l.title, "Compy", "", l.words, l.action, null, i);

        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(p.list.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        const box = gtk.Box.new(.vertical, 8);
        box.as(gtk.Widget).addCssClass("palette");
        box.append(p.entry.as(gtk.Widget));
        box.append(scroller.as(gtk.Widget));
        p.dialog.setChild(box.as(gtk.Widget));
        p.filter("");
        p.dialog.present(parent);
        _ = p.entry.as(gtk.Widget).grabFocus();
    }

    fn add(p: *Palette, title: []const u8, category: []const u8, keys: []const u8, words: []const u8, name: []const u8, rex: ?usize, loc: ?usize) void {
        const line = gtk.Box.new(.horizontal, 10);
        const z = gpa.dupeSentinel(u8, title, 0) catch return;
        defer gpa.free(z);
        const label = gtk.Label.new(z.ptr);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        line.append(label.as(gtk.Widget));
        if (category.len > 0) {
            const c = gpa.dupeSentinel(u8, category, 0) catch return;
            defer gpa.free(c);
            const cl = gtk.Label.new(c.ptr);
            cl.as(gtk.Widget).addCssClass("palette-category");
            line.append(cl.as(gtk.Widget));
        }
        if (keys.len > 0) {
            const k = gpa.dupeSentinel(u8, keys, 0) catch return;
            defer gpa.free(k);
            const kl = gtk.Label.new(k.ptr);
            kl.as(gtk.Widget).addCssClass("palette-keys");
            line.append(kl.as(gtk.Widget));
        }
        const row = gtk.ListBoxRow.new();
        row.setChild(line.as(gtk.Widget));
        p.list.append(row.as(gtk.Widget));
        const hay = std.fmt.allocPrint(gpa, "{s} {s} {s} {s}", .{ title, name, category, words }) catch return;
        for (hay) |*ch| ch.* = std.ascii.toLower(ch.*);
        p.items.append(gpa, .{ .row = row, .haystack = hay, .rex_index = rex, .local_index = loc }) catch {};
    }

    /// Shows the items holding every word typed, in order of the list.
    fn filter(p: *Palette, query: []const u8) void {
        var first: ?*gtk.ListBoxRow = null;
        for (p.items.items) |it| {
            var words = std.mem.tokenizeScalar(u8, query, ' ');
            var match = true;
            while (words.next()) |w| {
                var buf: [64]u8 = undefined;
                const n = @min(w.len, buf.len);
                for (w[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
                if (std.mem.indexOf(u8, it.haystack, buf[0..n]) == null) match = false;
            }
            it.row.as(gtk.Widget).setVisible(@intFromBool(match));
            if (match and first == null) first = it.row;
        }
        p.list.selectRow(first);
    }

    fn changed(entry: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
        p.filter(std.mem.span(entry.as(gtk.Editable).getText()));
    }

    fn enter(_: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
        if (p.list.getSelectedRow()) |row| p.run(row);
    }

    fn stop(_: *gtk.SearchEntry, p: *Palette) callconv(.c) void {
        _ = p.dialog.close();
    }

    fn activated(_: *gtk.ListBox, row: *gtk.ListBoxRow, p: *Palette) callconv(.c) void {
        p.run(row);
    }

    fn run(p: *Palette, row: *gtk.ListBoxRow) void {
        for (p.items.items) |it| if (it.row == row) {
            if (it.rex_index) |i| {
                const a = p.server.actions[i];
                if (a.needs_args and a.args == null) {
                    p.server.notifyMessage("That command needs arguments; bind it to a key in your Rex config");
                } else {
                    p.server.runAction(p.session_id, p.block_id, a.name, a.args);
                }
            } else if (it.local_index) |i| {
                const name = local[i].action["app.".len..];
                p.app.as(gio.ActionGroup).activateAction(name.ptr, null);
            }
            _ = p.dialog.close();
            return;
        };
    }

    fn closed(_: *adw.Dialog, p: *Palette) callconv(.c) void {
        for (p.items.items) |it| gpa.free(it.haystack);
        p.items.deinit(gpa);
        gpa.free(p.session_id);
        if (p.block_id) |b| gpa.free(b);
        gpa.destroy(p);
    }
};
