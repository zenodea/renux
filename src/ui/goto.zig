//! Go to Anything, like Rex's: one search over every session, tab, pane and recent folder on
//! every host. Also the folder browser behind Go to Directory and Insert Path.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const gobject = @import("gobject");
const glib = @import("glib");
const app_mod = @import("../app/app.zig");
const settings = @import("../settings/settings.zig");
const programs = @import("../icons/programs.zig");
const Server = @import("../rex/server.zig").Server;
const filterdialog = @import("filterdialog.zig");

const gpa = std.heap.c_allocator;
const App = app_mod.App;
const Host = app_mod.Host;

const Kind = enum { session, tab, pane, folder, detached };

const Item = struct {
    kind: Kind,
    /// The host it is on; a recent folder belongs to none.
    host: ?*Host,
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
/// Counts the dialogs opened, so a late answer finds the one that asked and no other.
var opened: usize = 0;

/// The folder browsers that are open, so one whose server goes away can close.
var browsers: std.ArrayList(*Browser) = .empty;

/// A host is about to be removed: nothing open here may reach for it or its server again.
pub fn hostRemoved(server: *Server) void {
    if (current) |g| _ = g.dialog.close();
    for (browsers.items) |b| if (b.server == server) {
        b.gone = true;
        _ = b.dialog.close();
    };
}

const Anything = struct {
    app: *App,
    dialog: *adw.Dialog,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    serial: usize,
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

    fn add(g: *Anything, kind: Kind, h: ?*Host, sid: []const u8, wid: []const u8, bid: []const u8, title: []const u8, detail: []const u8) void {
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

    fn refilter(g: *Anything) void {
        const query = filterdialog.query(g.entry);
        var first: ?*gtk.ListBoxRow = null;
        for (g.items.items) |*it| {
            const show = filterdialog.matchesWords(it.haystack, query);
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
        if (it.kind == .folder) {
            a.changeDirectory(it.path);
        } else if (it.host) |h| {
            // The host may have been removed since the list was made.
            if (std.mem.indexOfScalar(*Host, a.hosts.items, h) != null) switch (it.kind) {
                .session => a.openSession(h, it.session_id),
                .tab => a.openWindow(h, it.session_id, it.window_id),
                .pane => a.jumpTo(h, it.session_id, it.window_id, it.block_id),
                .detached => a.placeDetached(h, it.session_id, it.block_id),
                .folder => {},
            };
        }
        _ = g.dialog.close();
    }
};

/// Opens Go to Anything over every host's sessions, tabs and panes, and recent folders.
pub fn openAnything(a: *App) void {
    if (current) |g| _ = g.dialog.close();
    const g = gpa.create(Anything) catch return;
    const parts = filterdialog.build("Go to Anything", "Sessions, tabs, panes and folders", 560, 460, "goto");
    const dialog = parts.dialog;
    const entry = parts.entry;
    const list = parts.list;
    opened += 1;
    g.* = .{ .app = a, .dialog = dialog, .entry = entry, .list = list, .serial = opened };
    current = g;

    var tbuf: [256]u8 = undefined;
    var wbuf: [256]u8 = undefined;
    var dbuf: [256]u8 = undefined;
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
                    // The app that reported, such as claude, says more than the shell it runs in.
                    const prog = if (info) |i| ((if (i.has_status) i.status_app else null) orelse i.program) else null;
                    const title = programs.displayTitle(&tbuf, prog, if (info) |i| i.folder else null);
                    const detail = std.fmt.bufPrint(&dbuf, "{s} · {s}", .{ label, wt }) catch label;
                    g.add(.pane, h, session.id, w.id, b.id, title, detail);
                };
            }
        }
    }
    // Panes running outside any window arrive from each session a moment later.
    for (a.hosts.items) |h| for (h.server.sessions.items) |session| {
        h.server.listDetached(session.id, @ptrFromInt(g.serial), gotDetached);
    };
    if (settings.current.recent_paths_shown) for (settings.current.recent_paths.items) |p| {
        g.add(.folder, null, "", "", "", p, "Change to this folder in the focused pane");
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
    };
    filterdialog.onQuery(entry, *Anything, &Handlers.changed, g);
    _ = gtk.SearchEntry.signals.activate.connect(entry, *Anything, &Handlers.activate, g, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *Anything, &Handlers.rowActivated, g, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Anything, &Handlers.closed, g, .{});
    g.refilter();
    dialog.present(a.window.as(gtk.Widget));
    _ = entry.as(gtk.Widget).grabFocus();
}

fn gotDetached(ctx: *anyopaque, session_id: []const u8, ids: []const []const u8, labels: []const []const u8) void {
    // The dialog may have closed, or another opened, while the answer was on its way.
    const g = current orelse return;
    if (g.serial != @intFromPtr(ctx)) return;
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
    /// The server went away; the dialog is closing and must not use it again.
    gone: bool = false,
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
        if (b.gone) return;
        b.waiting += 1;
        b.server.listDir(b.session_id, b.block_id, path, b.mode == .insert, .{ .ctx = b, .done = listed });
    }

    fn listed(ctx: *anyopaque, path: []const u8, names: []const []const u8, files: []const bool) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        b.waiting -|= 1;
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
        if (!b.gone) b.app.usePath(b.server, b.session_id, b.block_id, path, b.mode == .insert);
        _ = b.dialog.close();
    }

    fn refilter(b: *Browser) void {
        const q = filterdialog.query(b.entry);
        var first: ?*gtk.ListBoxRow = null;
        for (b.rows.items, b.names.items) |r, n| {
            // Hidden folders stay out of the way until a filter starts with a dot.
            const hidden = n.len > 1 and n[0] == '.' and !std.mem.eql(u8, n, "..") and !std.mem.startsWith(u8, q, ".");
            const show = !hidden and (q.len == 0 or std.ascii.findIgnoreCase(n, q) != null);
            r.as(gtk.Widget).setVisible(@intFromBool(show));
            if (show and first == null and !std.mem.eql(u8, n, "..")) first = r;
        }
        // With nothing to match, nothing stays selected for Enter to take.
        if (first) |r| b.list.selectRow(r) else b.list.unselectAll();
    }
};

/// Browses folders from the focused pane's working directory, to change to one or insert a path.
pub fn openBrowser(a: *App, server: *Server, session_id: []const u8, block_id: []const u8, start: []const u8, mode: BrowseMode) void {
    const b = gpa.create(Browser) catch return;
    const owned_session = gpa.dupe(u8, session_id) catch return gpa.destroy(b);
    const owned_block = gpa.dupe(u8, block_id) catch {
        gpa.free(owned_session);
        return gpa.destroy(b);
    };
    const parts = filterdialog.build(if (mode == .cd) "Go to Directory" else "Insert Path", "Filter; Enter opens the first match, or this folder", 520, 480, "goto");
    const dialog = parts.dialog;
    const entry = parts.entry;
    const list = parts.list;
    const path_label = gtk.Label.new("");
    path_label.setXalign(0);
    path_label.setEllipsize(.start);
    path_label.as(gtk.Widget).addCssClass("goto-path");
    parts.box.prepend(path_label.as(gtk.Widget));
    const here = gtk.Button.newWithLabel(if (mode == .cd) "Open This Folder" else "Insert This Folder");
    here.as(gtk.Widget).addCssClass("suggested-action");
    here.as(gtk.Widget).addCssClass("pill");
    here.as(gtk.Widget).setHalign(.end);
    parts.box.append(here.as(gtk.Widget));
    b.* = .{
        .app = a,
        .mode = mode,
        .server = server,
        .session_id = owned_session,
        .block_id = owned_block,
        .dialog = dialog,
        .path_label = path_label,
        .entry = entry,
        .list = list,
    };
    browsers.append(gpa, b) catch {};
    const Handlers = struct {
        fn changed(_: *gtk.SearchEntry, bb: *Browser) callconv(.c) void {
            bb.refilter();
        }
        fn activate(_: *gtk.SearchEntry, bb: *Browser) callconv(.c) void {
            // With nothing typed, Enter takes the folder shown; otherwise the first match.
            if (filterdialog.query(bb.entry).len == 0) return bb.finish(bb.path.items);
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
            for (browsers.items, 0..) |x, i| if (x == bb) {
                _ = browsers.swapRemove(i);
                break;
            };
            if (bb.waiting == 0) bb.deinit();
        }
    };
    filterdialog.onQuery(entry, *Browser, &Handlers.changed, b);
    _ = gtk.SearchEntry.signals.activate.connect(entry, *Browser, &Handlers.activate, b, .{});
    _ = gtk.ListBox.signals.row_activated.connect(list, *Browser, &Handlers.rowActivated, b, .{});
    _ = gtk.Button.signals.clicked.connect(here, *Browser, &Handlers.useHere, b, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Browser, &Handlers.closed, b, .{});
    b.go(if (start.len > 0) start else "~");
    dialog.present(a.window.as(gtk.Widget));
    _ = entry.as(gtk.Widget).grabFocus();
}
