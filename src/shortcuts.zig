//! Settings > Shortcuts: every action with its keys, a way to record new ones, and the
//! recorded ones as Lua for the Rex config. Recorded keys are Compy's own, over the config's.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");
const gobject = @import("gobject");
const app_mod = @import("app.zig");
const settings = @import("settings.zig");
const keys = @import("keys.zig");
const Server = @import("server.zig").Server;

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

var entries: std.ArrayList(*Entry) = .empty;

fn freeEntries() void {
    for (entries.items) |e| {
        gpa.free(e.action);
        gpa.free(e.args);
        gpa.free(e.title_lower);
        gpa.destroy(e);
    }
    entries.clearRetainingCapacity();
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

/// Adds the shortcut groups to the Shortcuts page.
pub fn build(a: *App, p: *adw.PreferencesPage) void {
    freeEntries();
    const s = a.server orelse return;
    const head = adw.PreferencesGroup.new();
    head.setTitle("Key Bindings");
    head.setDescription("From your Rex config. A shortcut recorded here is Compy's own and takes the place of the config's keys for that action; Copy as Lua puts them in your config for good.");
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
        fn one(app: *App, group: *adw.PreferencesGroup, seen_list: *std.ArrayList([]const u8), action: []const u8, args: []const u8) void {
            const key = std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ action, args }) catch return;
            for (seen_list.items) |k| if (std.mem.eql(u8, k, key)) {
                gpa.free(key);
                return;
            };
            seen_list.append(gpa, key) catch return;
            addRow(app, group, action, args);
        }
    };
    for (s.config_bindings) |b| Add.one(a, list, &seen, b.action, b.args orelse "");
    for (settings.current.shortcuts.items) |sc| Add.one(a, list, &seen, sc.action, sc.args);
    for (s.actions) |act| if (!act.needs_args) Add.one(a, list, &seen, act.name, "");
    _ = gtk.SearchEntry.signals.search_changed.connect(filter, ?*anyopaque, &filterChanged, null, .{});
}

fn addRow(a: *App, group: *adw.PreferencesGroup, action: []const u8, args: []const u8) void {
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
    const e = gpa.create(Entry) catch return;
    const lower = gpa.dupe(u8, title) catch return;
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    e.* = .{
        .app = a,
        .action = gpa.dupeSentinel(u8, action, 0) catch return,
        .args = gpa.dupeSentinel(u8, args, 0) catch return,
        .row = row,
        .keys_label = label,
        .restore = restore,
        .title_lower = lower,
    };
    entries.append(gpa, e) catch return;
    _ = gtk.Button.signals.clicked.connect(record, *Entry, &startRecord, e, .{});
    _ = gtk.Button.signals.clicked.connect(restore, *Entry, &restoreKeys, e, .{});
    refresh(e);
}

fn filterChanged(entry: *gtk.SearchEntry, _: ?*anyopaque) callconv(.c) void {
    const q = std.mem.span(entry.as(gtk.Editable).getText());
    var buf: [128]u8 = undefined;
    const n = @min(q.len, buf.len);
    for (q[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    for (entries.items) |e| {
        const show = n == 0 or std.mem.indexOf(u8, e.title_lower, buf[0..n]) != null or std.mem.indexOf(u8, e.action, buf[0..n]) != null;
        e.row.as(gtk.Widget).setVisible(@intFromBool(show));
    }
}

fn applied(a: *App) void {
    for (a.hosts.items) |h| h.server.applyShortcuts();
    for (entries.items) |e| refresh(e);
}

fn restoreKeys(_: *gtk.Button, e: *Entry) callconv(.c) void {
    settings.setShortcut(e.action, e.args, null);
    applied(e.app);
}

// Recording.

const Recording = struct {
    entry: *Entry,
    dialog: *adw.Dialog,
    shown: *gtk.Label,
    seq: std.ArrayList([]u8) = .empty,

    fn text(r: *Recording, buf: []u8) [:0]const u8 {
        if (r.seq.items.len == 0) return std.fmt.bufPrintSentinel(buf, "Press the keys…", .{}, 0) catch "";
        var n: usize = 0;
        for (r.seq.items, 0..) |k, i| {
            var kb: [48]u8 = undefined;
            const p = app_mod.prettyKey(&kb, k);
            if (i > 0 and n + 3 < buf.len) {
                @memcpy(buf[n .. n + 3], "  ");
                n += 2;
            }
            if (n + p.len >= buf.len) break;
            @memcpy(buf[n .. n + p.len], p);
            n += p.len;
        }
        buf[n] = 0;
        return buf[0..n :0];
    }

    fn update(r: *Recording) void {
        var buf: [256]u8 = undefined;
        r.shown.setText(r.text(&buf).ptr);
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
        settings.setShortcut(r.entry.action, r.entry.args, out.items);
        applied(r.entry.app);
        _ = r.dialog.close();
    }
};

fn startRecord(_: *gtk.Button, e: *Entry) callconv(.c) void {
    const r = gpa.create(Recording) catch return;
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
    const note = gtk.Label.new("Keys one after another make a sequence, like ctrl+a then x. Backspace starts over.");
    note.setWrap(1);
    note.setJustify(.center);
    note.as(gtk.Widget).addCssClass("dim-label");
    box.append(note.as(gtk.Widget));
    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.center);
    const unbind = gtk.Button.newWithLabel("No Keys");
    const save = gtk.Button.newWithLabel("Save");
    save.as(gtk.Widget).addCssClass("suggested-action");
    buttons.append(unbind.as(gtk.Widget));
    buttons.append(save.as(gtk.Widget));
    box.append(buttons.as(gtk.Widget));
    dialog.setChild(box.as(gtk.Widget));
    r.* = .{ .entry = e, .dialog = dialog, .shown = shown };
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
            if (rr.seq.items.len >= 4) return 1;
            var buf: [48]u8 = undefined;
            const name = keys.rexName(&buf, keyval, gdk.keyvalToUnicode(keyval), mods) orelse return 1;
            rr.seq.append(gpa, gpa.dupe(u8, name) catch return 1) catch return 1;
            rr.update();
            return 1;
        }
        fn saved(_: *gtk.Button, rr: *Recording) callconv(.c) void {
            rr.save(false);
        }
        fn unbound(_: *gtk.Button, rr: *Recording) callconv(.c) void {
            rr.save(true);
        }
        fn closed(_: *adw.Dialog, rr: *Recording) callconv(.c) void {
            rr.clear();
            rr.seq.deinit(gpa);
            gpa.destroy(rr);
        }
    };
    const ctl = gtk.EventControllerKey.new();
    ctl.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(ctl, *Recording, &H.key, r, .{});
    dialog.as(gtk.Widget).addController(ctl.as(gtk.EventController));
    _ = gtk.Button.signals.clicked.connect(save, *Recording, &H.saved, r, .{});
    _ = gtk.Button.signals.clicked.connect(unbind, *Recording, &H.unbound, r, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Recording, &H.closed, r, .{});
    // Buttons can't take the keyboard, so every key goes to the recording.
    save.as(gtk.Widget).setFocusable(0);
    unbind.as(gtk.Widget).setFocusable(0);
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

/// The shortcuts recorded in Compy, as rex.bind lines for init.lua, onto the clipboard.
fn copyLua(_: *gtk.Button, a: *App) callconv(.c) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "-- Shortcuts recorded in Compy\n") catch return;
    for (settings.current.shortcuts.items) |sc| {
        if (sc.keys.len == 0) {
            out.print(gpa, "-- {s} has no keys in Compy\n", .{sc.action}) catch return;
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
