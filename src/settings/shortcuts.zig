//! Settings > Shortcuts: every action with its keys, a way to record new ones, and the
//! recorded ones as Lua for the Rex config. Recorded keys are Renux's own, over the config's.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");
const gobject = @import("gobject");
const app_mod = @import("../app/app.zig");
const settings = @import("settings.zig");
const keys = @import("../terminal/keys.zig");
const Server = @import("../rex/server.zig").Server;

const gpa = std.heap.c_allocator;
const App = app_mod.App;

/// One action and its arguments, as a row on the page.
const Entry = struct {
    app: *App,
    action: [:0]u8,
    args: [:0]u8,
    row: *adw.ActionRow,
    keys_label: *gtk.Label,
    restore: *gtk.Button,
    title_lower: []u8,
};

/// The rows of one Shortcuts page. The Settings window owns it and the memory its rows are in,
/// and frees both when the window itself is freed, so a row's buttons never outlive their data.
pub const Page = struct {
    al: std.mem.Allocator,
    entries: std.ArrayList(*Entry) = .empty,
};

/// The page on screen, whose rows show new keys as they're recorded.
var live: ?*Page = null;

/// The Settings window closed: its page's rows are no longer refreshed.
pub fn closed(page: *Page) void {
    if (live == page) live = null;
}

fn overridden(action: []const u8, args: []const u8) ?settings.Shortcut {
    for (settings.current.shortcuts.items) |sc| if (std.mem.eql(u8, sc.action, action) and std.mem.eql(u8, sc.args, args)) return sc;
    return null;
}

/// The keys an action has now, such as "⌃A -", joined when it has several.
fn keysText(s: *Server, buf: []u8, action: []const u8, args: []const u8) [:0]const u8 {
    var n: usize = 0;
    for (s.bindings) |b| {
        if (!std.mem.eql(u8, b.action, action) or !std.mem.eql(u8, b.args orelse "", args)) continue;
        if (n > 0 and n + 2 < buf.len) {
            @memcpy(buf[n .. n + 2], ", ");
            n += 2;
        }
        for (b.keys, 0..) |k, i| {
            var kb: [48]u8 = undefined;
            const p = app_mod.prettyKey(&kb, k);
            if (i > 0 and n + 1 < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
            if (n + p.len >= buf.len) break;
            @memcpy(buf[n .. n + p.len], p);
            n += p.len;
        }
    }
    if (n == 0) return std.fmt.bufPrintSentinel(buf, "None", .{}, 0) catch "";
    buf[n] = 0;
    return buf[0..n :0];
}

fn refresh(e: *Entry) void {
    const s = e.app.server orelse return;
    var buf: [256]u8 = undefined;
    e.keys_label.setText(keysText(s, &buf, e.action, e.args).ptr);
    e.restore.as(gtk.Widget).setVisible(@intFromBool(overridden(e.action, e.args) != null));
}

/// Adds the shortcut groups to the Shortcuts page. `page` and its allocator outlive the rows.
pub fn build(a: *App, p: *adw.PreferencesPage, page: *Page) void {
    page.entries = .empty;
    live = page;
    const s = a.server orelse return;
    const head = adw.PreferencesGroup.new();
    head.setTitle("Key Bindings");
    head.setDescription("From your Rex config. A shortcut recorded here is Renux's own and takes the place of the config's keys for that action; Copy as Lua puts them in your config for good.");
    const copy = gtk.Button.newWithLabel("Copy Shortcuts as Lua");
    copy.as(gtk.Widget).addCssClass("flat");
    copy.as(gtk.Widget).setValign(.center);
    head.setHeaderSuffix(copy.as(gtk.Widget));
    _ = gtk.Button.signals.clicked.connect(copy, *App, &copyLua, a, .{});
    const filter = gtk.SearchEntry.new();
    filter.setPlaceholderText("Filter shortcuts");
    head.add(filter.as(gtk.Widget));
    p.add(head);

    const list = adw.PreferencesGroup.new();
    p.add(list);
    // Every action once with each set of arguments it's bound with, then unbound actions.
    var seen: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen.items) |k| gpa.free(k);
        seen.deinit(gpa);
    }
    const Add = struct {
        fn one(app: *App, pg: *Page, group: *adw.PreferencesGroup, seen_list: *std.ArrayList([]const u8), action: []const u8, args: []const u8) void {
            const key = std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ action, args }) catch return;
            for (seen_list.items) |k| if (std.mem.eql(u8, k, key)) {
                gpa.free(key);
                return;
            };
            seen_list.append(gpa, key) catch return gpa.free(key);
            addRow(app, pg, group, action, args);
        }
    };
    for (s.config_bindings) |b| Add.one(a, page, list, &seen, b.action, b.args orelse "");
    for (settings.current.shortcuts.items) |sc| Add.one(a, page, list, &seen, sc.action, sc.args);
    for (s.actions) |act| if (!act.needs_args) Add.one(a, page, list, &seen, act.name, "");
    _ = gtk.SearchEntry.signals.search_changed.connect(filter, *Page, &filterChanged, page, .{});
}

fn addRow(a: *App, page: *Page, group: *adw.PreferencesGroup, action: []const u8, args: []const u8) void {
    var dbuf: [128]u8 = undefined;
    const title = app_mod.describeAction(a, &dbuf, action, if (args.len > 0) args else null, false);
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    const sub = gpa.dupeSentinel(u8, action, 0) catch return;
    defer gpa.free(sub);
    row.setSubtitle(sub.ptr);
    const label = gtk.Label.new("");
    label.as(gtk.Widget).addCssClass("palette-keys");
    label.as(gtk.Widget).setValign(.center);
    row.addSuffix(label.as(gtk.Widget));
    const restore = gtk.Button.newFromIconName("edit-undo-symbolic");
    restore.as(gtk.Widget).setTooltipText("Restore the config's keys");
    restore.as(gtk.Widget).addCssClass("flat");
    restore.as(gtk.Widget).setValign(.center);
    row.addSuffix(restore.as(gtk.Widget));
    const record = gtk.Button.newWithLabel("Record");
    record.as(gtk.Widget).addCssClass("flat");
    record.as(gtk.Widget).setValign(.center);
    row.addSuffix(record.as(gtk.Widget));
    group.add(row.as(gtk.Widget));
    const e = page.al.create(Entry) catch return;
    const lower = page.al.dupe(u8, title) catch return;
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    e.* = .{
        .app = a,
        .action = page.al.dupeSentinel(u8, action, 0) catch return,
        .args = page.al.dupeSentinel(u8, args, 0) catch return,
        .row = row,
        .keys_label = label,
        .restore = restore,
        .title_lower = lower,
    };
    page.entries.append(page.al, e) catch return;
    _ = gtk.Button.signals.clicked.connect(record, *Entry, &startRecord, e, .{});
    _ = gtk.Button.signals.clicked.connect(restore, *Entry, &restoreKeys, e, .{});
    refresh(e);
}

fn filterChanged(entry: *gtk.SearchEntry, page: *Page) callconv(.c) void {
    const q = std.mem.span(entry.as(gtk.Editable).getText());
    var buf: [128]u8 = undefined;
    const n = @min(q.len, buf.len);
    for (q[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    for (page.entries.items) |e| {
        const show = n == 0 or std.mem.indexOf(u8, e.title_lower, buf[0..n]) != null or std.mem.indexOf(u8, e.action, buf[0..n]) != null;
        e.row.as(gtk.Widget).setVisible(@intFromBool(show));
    }
}

fn applied(a: *App) void {
    for (a.hosts.items) |h| h.server.applyShortcuts();
    if (live) |page| for (page.entries.items) |e| refresh(e);
}

fn restoreKeys(_: *gtk.Button, e: *Entry) callconv(.c) void {
    settings.setShortcut(e.action, e.args, null);
    applied(e.app);
}

// Recording.

/// The keys recorded so far, such as "⌃A  X", or a prompt before the first. What doesn't fit
/// in `buf` is left out.
fn sequenceText(buf: []u8, seq: []const []const u8) [:0]const u8 {
    if (seq.len == 0) return std.fmt.bufPrintSentinel(buf, "Press the keys…", .{}, 0) catch "";
    var n: usize = 0;
    for (seq, 0..) |k, i| {
        var kb: [48]u8 = undefined;
        const p = app_mod.prettyKey(&kb, k);
        // Two spaces between keys, and room kept for the key and the end of the text.
        const gap: usize = if (i > 0) 2 else 0;
        if (n + gap + p.len >= buf.len) break;
        @memcpy(buf[n..][0..gap], "  "[0..gap]);
        n += gap;
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

const Recording = struct {
    /// Its own copies: the row it was started from can go while this is open.
    app: *App,
    action: []u8,
    args: []u8,
    dialog: *adw.Dialog,
    shown: *gtk.Label,
    seq: std.ArrayList([]u8) = .empty,

    fn update(r: *Recording) void {
        var buf: [256]u8 = undefined;
        r.shown.setText(sequenceText(&buf, r.seq.items).ptr);
    }

    fn clear(r: *Recording) void {
        for (r.seq.items) |k| gpa.free(k);
        r.seq.clearRetainingCapacity();
    }

    fn save(r: *Recording, unbind: bool) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        if (!unbind) for (r.seq.items, 0..) |k, i| {
            if (i > 0) out.append(gpa, ' ') catch return;
            out.appendSlice(gpa, k) catch return;
        };
        if (!unbind and out.items.len == 0) return;
        settings.setShortcut(r.action, r.args, out.items);
        applied(r.app);
        _ = r.dialog.close();
    }
};

fn startRecord(_: *gtk.Button, e: *Entry) callconv(.c) void {
    const r = gpa.create(Recording) catch return;
    const action = gpa.dupe(u8, e.action) catch return gpa.destroy(r);
    const args = gpa.dupe(u8, e.args) catch {
        gpa.free(action);
        return gpa.destroy(r);
    };
    const dialog = adw.Dialog.new();
    dialog.setTitle("Record Shortcut");
    dialog.setContentWidth(420);
    const box = gtk.Box.new(.vertical, 14);
    box.as(gtk.Widget).addCssClass("record-box");
    var dbuf: [128]u8 = undefined;
    const what = gtk.Label.new(app_mod.describeAction(e.app, &dbuf, e.action, if (e.args.len > 0) e.args else null, false).ptr);
    what.as(gtk.Widget).addCssClass("dim-label");
    box.append(what.as(gtk.Widget));
    const shown = gtk.Label.new("");
    shown.as(gtk.Widget).addCssClass("record-keys");
    box.append(shown.as(gtk.Widget));
    const note = gtk.Label.new("Keys one after another make a sequence, like ctrl+a then x. Backspace starts over, and Escape cancels before the first key.");
    note.setWrap(1);
    note.setJustify(.center);
    note.as(gtk.Widget).addCssClass("dim-label");
    box.append(note.as(gtk.Widget));
    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.center);
    const cancel = gtk.Button.newWithLabel("Cancel");
    const unbind = gtk.Button.newWithLabel("No Keys");
    unbind.as(gtk.Widget).setTooltipText("Leave this action without a shortcut");
    const save = gtk.Button.newWithLabel("Save");
    save.as(gtk.Widget).addCssClass("suggested-action");
    buttons.append(cancel.as(gtk.Widget));
    buttons.append(unbind.as(gtk.Widget));
    buttons.append(save.as(gtk.Widget));
    box.append(buttons.as(gtk.Widget));
    dialog.setChild(box.as(gtk.Widget));
    r.* = .{ .app = e.app, .action = action, .args = args, .dialog = dialog, .shown = shown };
    r.update();

    const H = struct {
        fn key(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, rr: *Recording) callconv(.c) c_int {
            if (keys.isModifier(keyval)) return 1;
            const mods = keys.modsFromGdk(@bitCast(state));
            if (keyval == 0xff08 and mods == 0) { // Backspace starts over
                rr.clear();
                rr.update();
                return 1;
            }
            // Escape alone, before anything is recorded, is a way out; later it's a key like any.
            if (keyval == 0xff1b and mods == 0 and rr.seq.items.len == 0) {
                _ = rr.dialog.close();
                return 1;
            }
            if (rr.seq.items.len >= 4) return 1;
            var buf: [48]u8 = undefined;
            // Caps Lock makes a capital without Shift; a shortcut records the key, not the lock.
            const plain = keys.uncapsed(keyval, mods);
            const name = keys.rexName(&buf, plain, gdk.keyvalToUnicode(plain), mods) orelse return 1;
            const copy = gpa.dupe(u8, name) catch return 1;
            rr.seq.append(gpa, copy) catch {
                gpa.free(copy);
                return 1;
            };
            rr.update();
            return 1;
        }
        fn saved(_: *gtk.Button, rr: *Recording) callconv(.c) void {
            rr.save(false);
        }
        fn unbound(_: *gtk.Button, rr: *Recording) callconv(.c) void {
            rr.save(true);
        }
        fn cancelled(_: *gtk.Button, rr: *Recording) callconv(.c) void {
            _ = rr.dialog.close();
        }
        // Runs when the dialog itself is freed, after every button that points here is gone.
        fn freed(data: ?*anyopaque) callconv(.c) void {
            const rr: *Recording = @ptrCast(@alignCast(data.?));
            rr.clear();
            rr.seq.deinit(gpa);
            gpa.free(rr.action);
            gpa.free(rr.args);
            gpa.destroy(rr);
        }
    };
    const ctl = gtk.EventControllerKey.new();
    ctl.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(ctl, *Recording, &H.key, r, .{});
    dialog.as(gtk.Widget).addController(ctl.as(gtk.EventController));
    _ = gtk.Button.signals.clicked.connect(save, *Recording, &H.saved, r, .{});
    _ = gtk.Button.signals.clicked.connect(unbind, *Recording, &H.unbound, r, .{});
    _ = gtk.Button.signals.clicked.connect(cancel, *Recording, &H.cancelled, r, .{});
    dialog.as(gobject.Object).setDataFull("renux-recording", r, &H.freed);
    // Buttons can't take the keyboard, so every key goes to the recording.
    save.as(gtk.Widget).setFocusable(0);
    unbind.as(gtk.Widget).setFocusable(0);
    cancel.as(gtk.Widget).setFocusable(0);
    dialog.present(e.row.as(gtk.Widget));
}

// Copy as Lua.

fn luaValue(out: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .string => |t| {
            try out.append(gpa, '"');
            for (t) |c| switch (c) {
                '"', '\\' => {
                    try out.append(gpa, '\\');
                    try out.append(gpa, c);
                },
                '\n' => try out.appendSlice(gpa, "\\n"),
                else => try out.append(gpa, c),
            };
            try out.append(gpa, '"');
        },
        .integer => |i| try out.print(gpa, "{d}", .{i}),
        .float => |f| try out.print(gpa, "{d}", .{f}),
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .array => |arr| {
            try out.appendSlice(gpa, "{ ");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(gpa, ", ");
                try luaValue(out, item);
            }
            try out.appendSlice(gpa, " }");
        },
        .object => |obj| {
            try out.appendSlice(gpa, "{ ");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try out.appendSlice(gpa, ", ");
                first = false;
                try out.print(gpa, "{s} = ", .{kv.key_ptr.*});
                try luaValue(out, kv.value_ptr.*);
            }
            try out.appendSlice(gpa, " }");
        },
        else => try out.appendSlice(gpa, "nil"),
    }
}

/// The shortcuts recorded in Renux, as rex.bind lines for init.lua, onto the clipboard.
fn copyLua(_: *gtk.Button, a: *App) callconv(.c) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "-- Shortcuts recorded in Renux\n") catch return;
    for (settings.current.shortcuts.items) |sc| {
        if (sc.keys.len == 0) {
            out.print(gpa, "-- {s} has no keys in Renux\n", .{sc.action}) catch return;
            continue;
        }
        out.appendSlice(gpa, "rex.bind(\"") catch return;
        var it = std.mem.tokenizeScalar(u8, sc.keys, ' ');
        var first = true;
        while (it.next()) |k| {
            if (!first) out.append(gpa, '>') catch return;
            first = false;
            out.appendSlice(gpa, k) catch return;
        }
        out.print(gpa, "\", \"{s}\"", .{sc.action}) catch return;
        if (sc.args.len > 0) {
            if (std.json.parseFromSlice(std.json.Value, gpa, sc.args, .{})) |parsed| {
                defer parsed.deinit();
                out.appendSlice(gpa, ", ") catch return;
                luaValue(&out, parsed.value) catch return;
            } else |_| {}
        }
        out.appendSlice(gpa, ")\n") catch return;
    }
    out.append(gpa, 0) catch return;
    a.window.as(gtk.Widget).getClipboard().setText(@ptrCast(out.items.ptr));
    a.toastText("Shortcuts copied as Lua");
}

test "the recorded keys fit their buffer, two spaces apart" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Press the keys…", sequenceText(&buf, &.{}));
    try std.testing.expectEqualStrings("⌃A", sequenceText(&buf, &.{"ctrl+a"}));
    try std.testing.expectEqualStrings("⌃A  x  ⌃⇧N", sequenceText(&buf, &.{ "ctrl+a", "x", "ctrl+shift+n" }));
    // A buffer too small for every key holds the ones that fit and still ends properly.
    for (0..16) |len| {
        var small: [16]u8 = undefined;
        const text = sequenceText(small[0 .. len + 1], &.{ "ctrl+a", "x", "ctrl+shift+n", "f" });
        try std.testing.expect(text.len <= len);
        try std.testing.expect(std.mem.startsWith(u8, "⌃A  x  ⌃⇧N  f", text));
    }
}
