//! Native text and choice prompts, using the command palette's filtering and navigation.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");
const filterdialog = @import("filterdialog.zig");
const keys = @import("../terminal/keys.zig");

pub const Item = struct {
    id: []const u8,
    title: []const u8,
    subtitle: []const u8 = "",
    detail: []const u8 = "",
    icon: ?[]const u8 = null,
    selected: bool = false,
};

pub const Mode = enum { input, single, other, multiple };

pub const Spec = struct {
    title: []const u8,
    placeholder: []const u8 = "",
    value: []const u8 = "",
    confirm: ?[]const u8 = null,
    mode: Mode = .single,
    items: []const Item = &.{},
};

pub const Result = union(enum) {
    cancelled,
    text: []const u8,
    ids: []const []const u8,
};

pub const Picker = struct {
    const Row = struct {
        widget: *gtk.ListBoxRow,
        id: []const u8,
        haystack: []const u8,
        check: ?*gtk.CheckButton = null,
    };

    const Action = union(enum) {
        none,
        text: struct { row: *gtk.ListBoxRow, preview: ?*gtk.Label },
        multiple: struct { count: *gtk.Label, selected: usize = 0 },
    };

    arena: std.heap.ArenaAllocator,
    dialog: *adw.Dialog,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
    rows: []Row,
    action: Action = .none,
    single_id: [1][]const u8 = undefined,
    ctx: *anyopaque,
    done: *const fn (*anyopaque, Result) void,
    phase: union(enum) {
        open,
        closing: Result,
        finished,
    } = .open,

    /// Call on the GTK thread. `spec` is needed only during this call; `value` seeds the query.
    /// The picker handle expires on dismissal or completion. Result slices are valid through `done`.
    pub fn open(parent: *gtk.Widget, spec: Spec, ctx: *anyopaque, done: *const fn (*anyopaque, Result) void) !*Picker {
        const gpa = std.heap.c_allocator;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const p = try alloc.create(Picker);
        const items: []const Item = if (spec.mode == .input) &.{} else spec.items;
        const rows = try alloc.alloc(Row, items.len);

        // Allocate before creating GTK objects. GTK copies its strings, so they share one scratch buffer.
        const confirm_len = if (spec.confirm) |confirm| confirm.len else 0;
        var text_len = @max(spec.title.len, spec.placeholder.len, spec.value.len, confirm_len);
        for (items, rows) |item, *row| {
            text_len = @max(text_len, item.title.len, item.subtitle.len, item.detail.len);
            row.* = .{
                .widget = undefined,
                .id = try alloc.dupe(u8, item.id),
                .haystack = try searchText(alloc, item),
            };
        }
        const text = try gpa.alloc(u8, text_len + 1);
        defer gpa.free(text);

        // The title and placeholder must both survive the call to build(). Stage the title in GTK
        // immediately afterward, using the same text for the visible heading.
        const parts = filterdialog.build("", z(text, spec.placeholder), 560, if (spec.mode == .input) 240 else 480, "palette");
        p.* = .{
            .arena = arena,
            .dialog = parts.dialog,
            .entry = parts.entry,
            .list = parts.list,
            .rows = rows,
            .ctx = ctx,
            .done = done,
        };
        const title = z(text, spec.title);
        p.dialog.setTitle(title.ptr);
        const heading = label(title);
        heading.as(gtk.Widget).addCssClass("title-3");
        parts.box.prepend(heading.as(gtk.Widget));
        p.list.setSelectionMode(.single);
        switch (spec.mode) {
            .input, .other => {
                const submit = label(if (spec.confirm) |confirm| z(text, confirm) else "Use text");
                const line = gtk.Box.new(.horizontal, 10);
                submit.as(gtk.Widget).setHexpand(1);
                line.append(submit.as(gtk.Widget));
                line.append(keycap("Enter"));
                const row = gtk.ListBoxRow.new();
                row.setChild(line.as(gtk.Widget));
                p.action = .{ .text = .{ .row = row, .preview = if (spec.confirm == null) submit else null } };
            },
            .single, .multiple => {
                const empty = gtk.Label.new(if (rows.len == 0) "No choices available" else "No matching choices");
                empty.as(gtk.Widget).addCssClass("dim-label");
                empty.as(gtk.Widget).setMarginTop(16);
                p.list.setPlaceholder(empty.as(gtk.Widget));
                if (spec.mode == .multiple) p.addMultipleConfirm(parts.box, if (spec.confirm) |confirm| z(text, confirm) else "Confirm");
            },
        }
        for (items, rows) |item, *row| {
            if (p.action == .multiple) {
                const check = gtk.CheckButton.new();
                // The whole row activates; the check button exposes the checked state.
                check.as(gtk.Widget).setCanTarget(0);
                check.as(gtk.Widget).setFocusable(0);
                check.as(gtk.Widget).setValign(.center);
                check.setActive(@intFromBool(item.selected));
                p.action.multiple.selected += @intFromBool(item.selected);
                _ = gtk.CheckButton.signals.toggled.connect(check, *Picker, &toggled, p, .{});
                row.check = check;
            }
            row.widget = makeRow(text, item, row.check);
            p.list.append(row.widget.as(gtk.Widget));
        }
        if (p.action == .text) p.list.append(p.action.text.row.as(gtk.Widget));
        if (p.action == .multiple) p.updateCount();
        p.entry.as(gtk.Editable).setText(z(text, spec.value).ptr);
        p.filter(filterdialog.query(p.entry));

        p.dialog.as(gobject.Object).setDataFull("renux-picker", p, &freed);
        _ = adw.Dialog.signals.closed.connect(p.dialog, *Picker, &closed, p, .{});
        _ = gtk.ListBox.signals.row_activated.connect(p.list, *Picker, &activated, p, .{});
        _ = gtk.SearchEntry.signals.activate.connect(parts.entry, *Picker, &enter, p, .{});
        filterdialog.onQuery(parts.entry, *Picker, &changed, p);

        // Capture Escape before GtkSearchEntry can consume it to clear or stop the search.
        const controller = gtk.EventControllerKey.new();
        controller.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Picker, &keyPressed, p, .{});
        p.dialog.as(gtk.Widget).addController(controller.as(gtk.EventController));

        p.dialog.present(parent);
        _ = parts.entry.as(gtk.Widget).grabFocus();
        return p;
    }

    /// Close a live picker without notifying its caller, even if it is already closing.
    pub fn dismiss(p: *Picker) void {
        const needs_close = p.phase == .open;
        p.phase = .finished;
        if (needs_close) p.dialog.forceClose();
    }

    fn addMultipleConfirm(p: *Picker, box: *gtk.Box, confirm: [:0]const u8) void {
        const content = gtk.Box.new(.horizontal, 6);
        const count = gtk.Label.new("");
        content.append(label(confirm).as(gtk.Widget));
        content.append(count.as(gtk.Widget));
        const button = gtk.Button.new();
        button.setChild(content.as(gtk.Widget));
        button.as(gtk.Widget).addCssClass("suggested-action");
        button.as(gtk.Widget).addCssClass("pill");
        _ = gtk.Button.signals.clicked.connect(button, *Picker, &confirmClicked, p, .{});

        const footer = gtk.Box.new(.horizontal, 8);
        footer.as(gtk.Widget).setHalign(.end);
        footer.append(keycap(if (@import("builtin").os.tag == .macos) "⌘↵" else "Ctrl+Enter"));
        footer.append(button.as(gtk.Widget));
        box.append(footer.as(gtk.Widget));
        p.action = .{ .multiple = .{ .count = count } };
    }

    fn updateCount(p: *Picker) void {
        var buf: [32]u8 = undefined;
        const multi = p.action.multiple;
        const count = std.mem.printSentinel(&buf, "({d})", .{multi.selected}, 0) catch unreachable;
        multi.count.setText(count.ptr);
    }

    fn toggled(check: *gtk.CheckButton, p: *Picker) callconv(.c) void {
        if (p.phase != .open) return;
        if (check.getActive() != 0) p.action.multiple.selected += 1 else p.action.multiple.selected -= 1;
        p.updateCount();
    }

    fn confirmClicked(_: *gtk.Button, p: *Picker) callconv(.c) void {
        p.confirmMultiple();
    }

    fn confirmMultiple(p: *Picker) void {
        if (p.phase != .open) return;
        const ids = p.arena.allocator().alloc([]const u8, p.action.multiple.selected) catch return;
        var at: usize = 0;
        for (p.rows) |row| {
            if (row.check.?.getActive() == 0) continue;
            ids[at] = row.id;
            at += 1;
        }
        p.close(.{ .ids = ids });
    }

    fn filter(p: *Picker, query: []const u8) void {
        var first: ?*gtk.ListBoxRow = null;
        for (p.rows) |row| {
            const match = filterdialog.matchesWords(row.haystack, query);
            row.widget.as(gtk.Widget).setVisible(@intFromBool(match));
            if (match and first == null) first = row.widget;
        }
        if (p.action == .text) {
            const text = p.action.text;
            if (text.preview) |preview| {
                var buf: [256]u8 = undefined;
                if (std.mem.printSentinel(&buf, "Use \"{s}\"", .{query}, 0)) |title| {
                    preview.setText(title.ptr);
                } else |_| {
                    const alloc = std.heap.c_allocator;
                    if (std.fmt.allocPrintSentinel(alloc, "Use \"{s}\"", .{query}, 0)) |title| {
                        defer alloc.free(title);
                        preview.setText(title.ptr);
                    } else |_| preview.setText("Use text");
                }
            }
            if (first == null) first = text.row;
        }
        p.list.selectRow(first);
        if (p.list.getAdjustment()) |adj| adj.setValue(adj.getLower());
    }

    fn changed(entry: *gtk.SearchEntry, p: *Picker) callconv(.c) void {
        if (p.phase == .open) p.filter(filterdialog.query(entry));
    }

    fn enter(_: *gtk.SearchEntry, p: *Picker) callconv(.c) void {
        if (p.list.getSelectedRow()) |row| p.pick(row);
    }

    fn activated(_: *gtk.ListBox, row: *gtk.ListBoxRow, p: *Picker) callconv(.c) void {
        p.pick(row);
    }

    fn pick(p: *Picker, row: *gtk.ListBoxRow) void {
        if (p.phase != .open or row.as(gtk.Widget).getVisible() == 0) return;
        if (p.action == .text and p.action.text.row == row) {
            const text = p.arena.allocator().dupe(u8, filterdialog.query(p.entry)) catch return;
            p.close(.{ .text = text });
            return;
        }
        // No rows are inserted or removed after opening; the text action, if any, is last.
        const item = &p.rows[@intCast(row.getIndex())];
        if (item.check) |check| {
            check.setActive(@intFromBool(check.getActive() == 0));
        } else {
            p.single_id[0] = item.id;
            p.close(.{ .ids = &p.single_id });
        }
    }

    fn keyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, p: *Picker) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            p.close(.cancelled);
            return 1;
        }
        if (p.action == .multiple and (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter)) {
            const mods = keys.modsFromGdk(@bitCast(state));
            if (mods == keys.ctrl or mods == keys.super) {
                p.confirmMultiple();
                return 1;
            }
        }
        return 0;
    }

    fn close(p: *Picker, result: Result) void {
        if (p.phase != .open) return;
        p.phase = .{ .closing = result };
        _ = p.dialog.close();
    }

    fn complete(p: *Picker, result: Result) void {
        if (p.phase == .finished) return;
        p.phase = .finished;
        p.done(p.ctx, result);
    }

    fn closed(_: *adw.Dialog, p: *Picker) callconv(.c) void {
        p.complete(if (p.phase == .closing) p.phase.closing else .cancelled);
    }

    fn freed(data: ?*anyopaque) callconv(.c) void {
        const p: *Picker = @ptrCast(@alignCast(data.?));
        // Tearing down the dialog's host can destroy it without a closed signal.
        p.complete(.cancelled);
        var arena = p.arena;
        arena.deinit();
    }
};

fn z(buf: []u8, text: []const u8) [:0]const u8 {
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return buf[0..text.len :0];
}

fn label(text: [:0]const u8) *gtk.Label {
    const l = gtk.Label.new(text.ptr);
    l.setXalign(0);
    l.setEllipsize(.end);
    return l;
}

fn keycap(text: [:0]const u8) *gtk.Widget {
    const widget = label(text).as(gtk.Widget);
    widget.addCssClass("palette-keys");
    widget.setValign(.center);
    return widget;
}

fn makeRow(text: []u8, item: Item, check: ?*gtk.CheckButton) *gtk.ListBoxRow {
    const line = gtk.Box.new(.horizontal, 10);
    if (check) |c| line.append(c.as(gtk.Widget));
    if (item.icon) |name| {
        if (icon_names.get(name)) |symbolic| {
            const image = gtk.Image.newFromIconName(symbolic.ptr);
            image.as(gtk.Widget).setValign(.center);
            line.append(image.as(gtk.Widget));
        }
    }
    const main = gtk.Box.new(.vertical, 2);
    main.as(gtk.Widget).setHexpand(1);
    main.append(label(z(text, item.title)).as(gtk.Widget));
    if (item.subtitle.len != 0) {
        const subtitle = label(z(text, item.subtitle)).as(gtk.Widget);
        subtitle.addCssClass("palette-category");
        main.append(subtitle);
    }
    line.append(main.as(gtk.Widget));
    if (item.detail.len != 0) {
        const detail = label(z(text, item.detail));
        detail.setMaxWidthChars(24);
        detail.as(gtk.Widget).setValign(.center);
        detail.as(gtk.Widget).addCssClass("palette-keys");
        line.append(detail.as(gtk.Widget));
    }
    const row = gtk.ListBoxRow.new();
    row.setChild(line.as(gtk.Widget));
    return row;
}

const icon_names = std.StaticStringMap([:0]const u8).initComptime(.{
    .{ "document", "text-x-generic-symbolic" },
    .{ "folder", "folder-symbolic" },
    .{ "branch", "go-jump-symbolic" },
    .{ "terminal", "utilities-terminal-symbolic" },
    .{ "code", "applications-engineering-symbolic" },
    .{ "server", "network-server-symbolic" },
    .{ "database", "drive-harddisk-symbolic" },
    .{ "package", "package-x-generic-symbolic" },
    .{ "globe", "web-browser-symbolic" },
    .{ "link", "insert-link-symbolic" },
    .{ "person", "avatar-default-symbolic" },
    .{ "tag", "bookmark-new-symbolic" },
    .{ "clock", "document-open-recent-symbolic" },
    .{ "star", "starred-symbolic" },
    .{ "gear", "emblem-system-symbolic" },
    .{ "plus", "list-add-symbolic" },
});

fn searchText(alloc: std.mem.Allocator, item: Item) ![]const u8 {
    const buf = try alloc.alloc(u8, item.title.len + item.subtitle.len + item.detail.len + 2);
    var at: usize = 0;
    for ([_][]const u8{ item.title, item.subtitle, item.detail }, 0..) |field, i| {
        if (i != 0) {
            buf[at] = ' ';
            at += 1;
        }
        _ = std.ascii.lowerString(buf[at..][0..field.len], field);
        at += field.len;
    }
    return buf;
}
