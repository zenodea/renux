//! Go to Anything, like Rex's: one search over every session, tab, pane and recent folder on
//! every host. Also the folder browser behind Go to Directory and Insert Path.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gobject = @import("gobject");
const glib = @import("glib");
const app_mod = @import("app.zig");
const settings = @import("settings.zig");
const programs = @import("programs.zig");
const Server = @import("server.zig").Server;

const gpa = std.heap.c_allocator;
const App = app_mod.App;
const Host = app_mod.Host;

const Kind = enum { session, tab, pane, folder, detached };

const Item = struct {
    kind: Kind,
    host: *Host,
    session_id: []u8,
    window_id: []u8,
    block_id: []u8,
    /// What the search matches against, in lower case.
    haystack: []u8,
    /// A recent folder's path, as typed into the shell.
    path: []u8,
    row: *gtk.ListBoxRow = undefined,
};

/// The open Go to Anything dialog; there is only ever one.
var current: ?*Anything = null;

const Anything = struct {
    app: *App,
    dialog: *adw.Dialog,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    items: std.ArrayList(Item) = .empty,

    fn deinit(g: *Anything) void {
        for (g.items.items) |it| {
            gpa.free(it.session_id);
            gpa.free(it.window_id);
            gpa.free(it.block_id);
            gpa.free(it.haystack);
            gpa.free(it.path);
        }
        g.items.deinit(gpa);
        gpa.destroy(g);
    }

    fn add(g: *Anything, kind: Kind, h: *Host, sid: []const u8, wid: []const u8, bid: []const u8, title: []const u8, detail: []const u8) void {
        const hay = std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ @tagName(kind), title, detail }) catch return;
        for (hay) |*c| c.* = std.ascii.toLower(c.*);
        const line = gtk.Box.new(.horizontal, 10);
        const text = gtk.Box.new(.vertical, 1);
        text.as(gtk.Widget).setHexpand(1);
        const tz = gpa.dupeSentinel(u8, title, 0) catch return;
        defer gpa.free(tz);
        const t = gtk.Label.new(tz.ptr);
        t.setXalign(0);
        t.setEllipsize(.end);
        text.append(t.as(gtk.Widget));
        if (detail.len > 0) {
            const dz = gpa.dupeSentinel(u8, detail, 0) catch return;
            defer gpa.free(dz);
            const d = gtk.Label.new(dz.ptr);
            d.setXalign(0);
            d.setEllipsize(.end);
            d.as(gtk.Widget).addCssClass("goto-detail");
            text.append(d.as(gtk.Widget));
        }
        line.append(text.as(gtk.Widget));
        const chip = gtk.Label.new(switch (kind) {
            .session => "Session",
            .tab => "Tab",
            .pane => "Pane",
            .folder => "Folder",
            .detached => "Detached",
        });
        chip.as(gtk.Widget).addCssClass("goto-kind");
        chip.as(gtk.Widget).setValign(.center);
        line.append(chip.as(gtk.Widget));
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("goto-row");
        row.setChild(line.as(gtk.Widget));
        g.list.append(row.as(gtk.Widget));
        g.items.append(gpa, .{
            .kind = kind,
            .host = h,
            .session_id = gpa.dupe(u8, sid) catch return,
            .window_id = gpa.dupe(u8, wid) catch return,
            .block_id = gpa.dupe(u8, bid) catch return,
            .haystack = hay,
            .path = gpa.dupe(u8, if (kind == .folder) title else "") catch return,
            .row = row,
        }) catch return;
    }

    fn matches(g: *Anything, it: *const Item) bool {
        const q = std.mem.span(g.entry.as(gtk.Editable).getText());
        var words = std.mem.tokenizeScalar(u8, q, ' ');
        var buf: [128]u8 = undefined;
        while (words.next()) |w| {
            const n = @min(w.len, buf.len);
            for (w[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
            if (std.mem.indexOf(u8, it.haystack, buf[0..n]) == null) return false;
        }
        return true;
    }

    fn refilter(g: *Anything) void {
        var first: ?*gtk.ListBoxRow = null;
        for (g.items.items) |*it| {
            const show = g.matches(it);
            it.row.as(gtk.Widget).setVisible(@intFromBool(show));
            if (show and first == null) first = it.row;
        }
        if (first) |r| g.list.selectRow(r) else g.list.unselectAll();
    }

    fn pick(g: *Anything, row: *gtk.ListBoxRow) void {
        const it = for (g.items.items) |*i| {
            if (i.row == row) break i;
        } else return;
        const a = g.app;
        switch (it.kind) {
            .session => a.openSession(it.host, it.session_id),
            .tab => a.openWindow(it.host, it.session_id, it.window_id),
            .pane => a.jumpTo(it.host, it.session_id, it.window_id, it.block_id),
            .folder => a.changeDirectory(it.path),
            .detached => a.placeDetached(it.host, it.session_id, it.block_id),
        }
        _ = g.dialog.close();
    }
};

/// Opens Go to Anything over every host's sessions, tabs and panes, and recent folders.
pub fn openAnything(a: *App) void {
    if (current) |g| _ = g.dialog.close();
    const g = gpa.create(Anything) catch return;
    const dialog = adw.Dialog.new();
    dialog.setTitle("Go to Anything");
    dialog.setContentWidth(560);
    dialog.setContentHeight(460);
    const box = gtk.Box.new(.vertical, 8);
    box.as(gtk.Widget).addCssClass("goto");
    const entry = gtk.SearchEntry.new();
    entry.setPlaceholderText("Sessions, tabs, panes and folders");
    box.append(entry.as(gtk.Widget));
    const list = gtk.ListBox.new();
    list.as(gtk.Widget).addCssClass("navigation-sidebar");
    list.setActivateOnSingleClick(1);
    const scroller = gtk.ScrolledWindow.new();
    scroller.setPolicy(.never, .automatic);
    scroller.as(gtk.Widget).setVexpand(1);
    scroller.setChild(list.as(gtk.Widget));
    box.append(scroller.as(gtk.Widget));
    dialog.setChild(box.as(gtk.Widget));
    g.* = .{ .app = a, .dialog = dialog, .entry = entry, .list = list };
    current = g;

    var tbuf: [256]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var dbuf: [256]u8 = undefined;
    var fbuf: [256]u8 = undefined;
    for (a.hosts.items) |h| {
        const s = h.server;
        for (s.sessions.items) |session| {
            const label = if (session.label.len > 0) session.label else session.id;
            g.add(.session, h, session.id, "", "", label, h.label);
            const v = s.sessionView(session.id) orelse continue;
            for (v.windows) |*w| {
                const wt = app_mod.windowLabel(h, &wbuf, w, v);
                g.add(.tab, h, session.id, w.id, "", wt, label);
                for (w.layers) |l| for (l.blocks) |b| {
                    const info = s.blockInfo(b.id);
                    const prog = if (info) |i| ((if (i.has_status) i.status_app else null) orelse i.program orelse "shell") else "shell";
                    const name = std.mem.trimStart(u8, prog[0 .. std.mem.indexOfScalar(u8, prog, '/') orelse prog.len], "-");
                    const title = if (info) |i| (if (i.folder) |f| std.fmt.bufPrint(&tbuf, "{s} {s}", .{ name, programs.shortFolder(&fbuf, f) }) catch name else name) else name;
                    const detail = std.fmt.bufPrint(&dbuf, "{s} · {s}", .{ label, wt }) catch label;
                    g.add(.pane, h, session.id, w.id, b.id, title, detail);
                };
            }
        }
    }
    // Panes running outside any window arrive from each session a moment later.
    for (a.hosts.items) |h| for (h.server.sessions.items) |session| {
        h.server.listDetached(session.id, g, gotDetached);
    };
    if (settings.current.recent_paths_shown) for (settings.current.recent_paths.items) |p| {
        g.add(.folder, a.hosts.items[0], "", "", "", p, "Change to this folder in the focused pane");
    };
    const Handlers = struct {
        fn changed(_: *gtk.SearchEntry, gg: *Anything) callconv(.c) void {
            gg.refilter();
        }
        fn activate(_: *gtk.SearchEntry, gg: *Anything) callconv(.c) void {
            if (gg.list.getSelectedRow()) |r| gg.pick(r);
        }
        fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, gg: *Anything) callconv(.c) void {
            gg.pick(row);
        }
        fn closed(_: *adw.Dialog, gg: *Anything) callconv(.c) void {
            if (current == gg) current = null;
            gg.deinit();
        }
        fn key(ctl: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk_mod.ModifierType, gg: *Anything) callconv(.c) c_int {
            _ = ctl;
            // Up and down move through what's shown while typing goes on in the search.
            const down = keyval == 0xff54;
            const up = keyval == 0xff52;
            if (!down and !up) return 0;
            const sel = gg.list.getSelectedRow();
            var i: usize = 0;
            var at: ?usize = null;
            var shown: [512]*gtk.ListBoxRow = undefined;
            var n: usize = 0;
            for (gg.items.items) |*it| if (it.row.as(gtk.Widget).getVisible() != 0 and n < shown.len) {
                if (sel == it.row) at = n;
                shown[n] = it.row;
                n += 1;
            };
            if (n == 0) return 1;
            i = if (at) |p| (if (down) @min(p + 1, n - 1) else if (p > 0) p - 1 else 0) else 0;
            gg.list.selectRow(shown[i]);
            _ = shown[i].as(gtk.Widget).grabFocus();
            _ = gg.entry.as(gtk.Widget).grabFocus();
            return 1;
        }
    };
    _ = gtk.SearchEntry.signals.search_changed.connect(entry, *Anything, &Handlers.changed, g, .{});
    _ = gtk.SearchEntry.signals.activate.connect(entry, *Anything, &Handlers.activate, g, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *Anything, &Handlers.rowActivated, g, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Anything, &Handlers.closed, g, .{});
    const keys_ctl = gtk.EventControllerKey.new();
    keys_ctl.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys_ctl, *Anything, &Handlers.key, g, .{});
    entry.as(gtk.Widget).addController(keys_ctl.as(gtk.EventController));
    g.refilter();
    dialog.present(a.window.as(gtk.Widget));
    _ = entry.as(gtk.Widget).grabFocus();
}

const gdk_mod = @import("gdk");

fn gotDetached(ctx: *anyopaque, session_id: []const u8, ids: []const []const u8, labels: []const []const u8) void {
    const g: *Anything = @ptrCast(@alignCast(ctx));
    // The dialog may have closed, or another opened, while the answer was on its way.
    if (current != g) return;
    var found: ?*Host = null;
    for (g.app.hosts.items) |x| for (x.server.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id)) {
        found = x;
    };
    const h = found orelse return;
    var label: []const u8 = session_id;
    for (h.server.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id) and session.label.len > 0) {
        label = session.label;
    };
    for (ids, labels) |id, l| g.add(.detached, h, session_id, "", id, l, label);
    g.refilter();
}

// The folder browser.

pub const BrowseMode = enum { cd, insert };

const Browser = struct {
    app: *App,
    mode: BrowseMode,
    server: *Server,
    session_id: []u8,
    block_id: []u8,
    dialog: *adw.Dialog,
    path_label: *gtk.Label,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    path: std.ArrayList(u8) = .empty,
    names: std.ArrayList([]u8) = .empty,
    files: std.ArrayList(bool) = .empty,
    rows: std.ArrayList(*gtk.ListBoxRow) = .empty,
    closed: bool = false,
    /// Listings still on their way; the browser is freed once it's closed and none are left.
    waiting: u32 = 0,

    fn clearNames(b: *Browser) void {
        for (b.names.items) |n| gpa.free(n);
        b.names.clearRetainingCapacity();
        b.files.clearRetainingCapacity();
        b.rows.clearRetainingCapacity();
        const w = b.list.as(gtk.Widget);
        while (w.getFirstChild()) |c| b.list.remove(c);
    }

    fn deinit(b: *Browser) void {
        for (b.names.items) |n| gpa.free(n);
        b.names.deinit(gpa);
        b.files.deinit(gpa);
        b.rows.deinit(gpa);
        b.path.deinit(gpa);
        gpa.free(b.session_id);
        gpa.free(b.block_id);
        gpa.destroy(b);
    }

    fn go(b: *Browser, path: []const u8) void {
        b.waiting += 1;
        b.server.listDir(b.session_id, b.block_id, path, b.mode == .insert, .{ .ctx = b, .done = listed });
    }

    fn listed(ctx: *anyopaque, path: []const u8, names: []const []const u8, files: []const bool) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        b.waiting -= 1;
        if (b.closed) {
            if (b.waiting == 0) b.deinit();
            return;
        }
        if (path.len == 0) return;
        b.path.clearRetainingCapacity();
        b.path.appendSlice(gpa, path) catch return;
        const pz = gpa.dupeSentinel(u8, path, 0) catch return;
        defer gpa.free(pz);
        b.path_label.setText(pz.ptr);
        b.clearNames();
        b.entry.as(gtk.Editable).setText("");
        // Folders first, then files, each in name order; ".." goes up a level.
        const Pair = struct { name: []const u8, file: bool };
        var pairs: std.ArrayList(Pair) = .empty;
        defer pairs.deinit(gpa);
        for (names, files) |n, f| pairs.append(gpa, .{ .name = n, .file = f }) catch break;
        std.mem.sort(Pair, pairs.items, {}, struct {
            fn less(_: void, x: Pair, y: Pair) bool {
                if (x.file != y.file) return !x.file;
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.less);
        if (!std.mem.eql(u8, path, "/")) b.addRow("..", false);
        for (pairs.items) |p| b.addRow(p.name, p.file);
        b.refilter();
    }

    fn addRow(b: *Browser, name: []const u8, file: bool) void {
        const z = std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ name, if (file) "" else "/" }, 0) catch return;
        defer gpa.free(z);
        const label = gtk.Label.new(z.ptr);
        label.setXalign(0);
        label.setEllipsize(.middle);
        if (file) label.as(gtk.Widget).addCssClass("goto-detail");
        const row = gtk.ListBoxRow.new();
        row.setChild(label.as(gtk.Widget));
        b.list.append(row.as(gtk.Widget));
        b.names.append(gpa, gpa.dupe(u8, name) catch return) catch return;
        b.files.append(gpa, file) catch return;
        b.rows.append(gpa, row) catch return;
    }

    fn child(b: *Browser, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, name, "..")) {
            const cut = std.mem.lastIndexOfScalar(u8, b.path.items, '/') orelse 0;
            return gpa.dupe(u8, if (cut == 0) "/" else b.path.items[0..cut]);
        }
        const sep: []const u8 = if (std.mem.endsWith(u8, b.path.items, "/")) "" else "/";
        return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ b.path.items, sep, name });
    }

    fn rowPicked(b: *Browser, row: *gtk.ListBoxRow) void {
        const i = for (b.rows.items, 0..) |r, k| {
            if (r == row) break k;
        } else return;
        const target = b.child(b.names.items[i]) catch return;
        defer gpa.free(target);
        if (b.files.items[i]) return b.finish(target);
        b.go(target);
    }

    /// Changes to the folder, or types the path, then closes.
    fn finish(b: *Browser, path: []const u8) void {
        b.app.usePath(b.server, b.session_id, b.block_id, path, b.mode == .insert);
        _ = b.dialog.close();
    }

    fn refilter(b: *Browser) void {
        const q = std.mem.span(b.entry.as(gtk.Editable).getText());
        var first: ?*gtk.ListBoxRow = null;
        for (b.rows.items, b.names.items) |r, n| {
            // Hidden folders stay out of the way until a filter starts with a dot.
            const hidden = n.len > 1 and n[0] == '.' and !std.mem.eql(u8, n, "..") and !std.mem.startsWith(u8, q, ".");
            const show = !hidden and (q.len == 0 or std.ascii.findIgnoreCase(n, q) != null);
            r.as(gtk.Widget).setVisible(@intFromBool(show));
            if (show and first == null and !std.mem.eql(u8, n, "..")) first = r;
        }
        if (first) |r| b.list.selectRow(r);
    }
};

/// Browses folders from the focused pane's working directory, to change to one or insert a path.
pub fn openBrowser(a: *App, server: *Server, session_id: []const u8, block_id: []const u8, start: []const u8, mode: BrowseMode) void {
    const b = gpa.create(Browser) catch return;
    const dialog = adw.Dialog.new();
    dialog.setTitle(if (mode == .cd) "Go to Directory" else "Insert Path");
    dialog.setContentWidth(520);
    dialog.setContentHeight(480);
    const box = gtk.Box.new(.vertical, 8);
    box.as(gtk.Widget).addCssClass("goto");
    const path_label = gtk.Label.new("");
    path_label.setXalign(0);
    path_label.setEllipsize(.start);
    path_label.as(gtk.Widget).addCssClass("goto-path");
    box.append(path_label.as(gtk.Widget));
    const entry = gtk.SearchEntry.new();
    entry.setPlaceholderText("Filter; Enter opens the first match, or this folder");
    box.append(entry.as(gtk.Widget));
    const list = gtk.ListBox.new();
    list.as(gtk.Widget).addCssClass("navigation-sidebar");
    list.setActivateOnSingleClick(1);
    const scroller = gtk.ScrolledWindow.new();
    scroller.setPolicy(.never, .automatic);
    scroller.as(gtk.Widget).setVexpand(1);
    scroller.setChild(list.as(gtk.Widget));
    box.append(scroller.as(gtk.Widget));
    const here = gtk.Button.newWithLabel(if (mode == .cd) "Open This Folder" else "Insert This Folder");
    here.as(gtk.Widget).addCssClass("suggested-action");
    here.as(gtk.Widget).addCssClass("pill");
    here.as(gtk.Widget).setHalign(.end);
    box.append(here.as(gtk.Widget));
    dialog.setChild(box.as(gtk.Widget));
    b.* = .{
        .app = a,
        .mode = mode,
        .server = server,
        .session_id = gpa.dupe(u8, session_id) catch return,
        .block_id = gpa.dupe(u8, block_id) catch return,
        .dialog = dialog,
        .path_label = path_label,
        .entry = entry,
        .list = list,
    };
    const Handlers = struct {
        fn changed(_: *gtk.SearchEntry, bb: *Browser) callconv(.c) void {
            bb.refilter();
        }
        fn activate(_: *gtk.SearchEntry, bb: *Browser) callconv(.c) void {
            // With nothing typed, Enter takes the folder shown; otherwise the first match.
            if (std.mem.span(bb.entry.as(gtk.Editable).getText()).len == 0) return bb.finish(bb.path.items);
            if (bb.list.getSelectedRow()) |r| bb.rowPicked(r);
        }
        fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, bb: *Browser) callconv(.c) void {
            bb.rowPicked(row);
        }
        fn useHere(_: *gtk.Button, bb: *Browser) callconv(.c) void {
            bb.finish(bb.path.items);
        }
        fn closed(_: *adw.Dialog, bb: *Browser) callconv(.c) void {
            bb.closed = true;
            if (bb.waiting == 0) bb.deinit();
        }
    };
    _ = gtk.SearchEntry.signals.search_changed.connect(entry, *Browser, &Handlers.changed, b, .{});
    _ = gtk.SearchEntry.signals.activate.connect(entry, *Browser, &Handlers.activate, b, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *Browser, &Handlers.rowActivated, b, .{});
    _ = gtk.Button.signals.clicked.connect(here, *Browser, &Handlers.useHere, b, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Browser, &Handlers.closed, b, .{});
    b.go(if (start.len > 0) start else "~");
    dialog.present(a.window.as(gtk.Widget));
    _ = entry.as(gtk.Widget).grabFocus();
}
