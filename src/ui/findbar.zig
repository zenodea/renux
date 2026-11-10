//! Find in one pane: a small bar floating at the top right of the pane's terminal, as in Rex.
//! Each pane has its own, so two panes can be searched side by side for different things.
const std = @import("std");
const gtk = @import("gtk");
const icons = @import("../icons/icons.zig");
const TermView = @import("../terminal/termview.zig").TermView;

const gpa = std.heap.c_allocator;

pub const FindBar = struct {
    view: *TermView,
    revealer: *gtk.Revealer,
    entry: *gtk.Entry,
    count: *gtk.Label,
    total: usize = 0,

    /// Builds the bar for `view`. It frees itself when its widget goes, with the pane.
    pub fn create(view: *TermView) ?*FindBar {
        const f = gpa.create(FindBar) catch return null;
        const row = gtk.Box.new(.horizontal, 2);
        row.as(gtk.Widget).addCssClass("find-bar");
        f.* = .{ .view = view, .revealer = gtk.Revealer.new(), .entry = gtk.Entry.new(), .count = gtk.Label.new("") };
        f.entry.as(gtk.Widget).setHexpand(1);
        f.entry.as(gtk.Editable).setWidthChars(12);
        f.entry.as(gtk.Editable).setMaxWidthChars(18);
        f.entry.setPlaceholderText("Find");
        // A plain field: nothing in it but the text, with no icon or clear button.
        f.entry.setHasFrame(0);
        _ = gtk.Editable.signals.changed.connect(f.entry, *FindBar, &changed, f, .{});
        _ = gtk.Entry.signals.activate.connect(f.entry, *FindBar, &nextSignal, f, .{});
        // Escape closes the bar, and Shift+Return goes back a match.
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *FindBar, &keyed, f, .{});
        f.entry.as(gtk.Widget).addController(keys.as(gtk.EventController));
        f.count.as(gtk.Widget).addCssClass("find-count");
        row.append(f.entry.as(gtk.Widget));
        row.append(f.count.as(gtk.Widget));
        inline for (.{ .{ icons.Kind.up, "Newer match", &prevClicked }, .{ icons.Kind.down, "Older match", &nextClicked }, .{ icons.Kind.close, "Close find", &closeClicked } }) |b| {
            const button = icons.button(b[0], b[1], null);
            _ = gtk.Button.signals.clicked.connect(button, *FindBar, b[2], f, .{});
            row.append(button.as(gtk.Widget));
        }
        f.revealer.setChild(row.as(gtk.Widget));
        f.revealer.setTransitionType(.crossfade);
        f.revealer.setTransitionDuration(120);
        f.revealer.as(gtk.Widget).setHalign(.end);
        f.revealer.as(gtk.Widget).setValign(.start);
        _ = gtk.Widget.signals.destroy.connect(f.revealer.as(gtk.Widget), *FindBar, &destroyed, f, .{});
        return f;
    }

    pub fn widget(f: *FindBar) *gtk.Widget {
        return f.revealer.as(gtk.Widget);
    }

    fn destroyed(_: *gtk.Widget, f: *FindBar) callconv(.c) void {
        gpa.destroy(f);
    }

    pub fn isOpen(f: *FindBar) bool {
        return f.revealer.getRevealChild() != 0;
    }

    /// Shows the bar and puts the keyboard in it, with what was searched last selected.
    pub fn open(f: *FindBar) void {
        f.revealer.setRevealChild(1);
        _ = f.entry.as(gtk.Widget).grabFocus();
        f.setText(std.mem.span(f.entry.as(gtk.Editable).getText()));
    }

    /// Hides the bar, clears the pane's matches and gives the pane the keyboard back.
    pub fn close(f: *FindBar) void {
        f.revealer.setRevealChild(0);
        if (f.view.term()) |t| t.endFind();
        f.count.setText("");
        f.view.widget().queueDraw();
        _ = f.view.widget().grabFocus();
    }

    /// Searches the pane for `text`, as typing it would.
    pub fn setText(f: *FindBar, text: []const u8) void {
        const t = f.view.term() orelse return;
        if (text.len == 0) {
            t.endFind();
            f.total = 0;
            f.count.setText("");
        } else {
            f.total = t.find(text);
            f.showCount(if (f.total > 0) t.findStep(true) else null);
        }
        f.view.widget().queueDraw();
    }

    /// Types `text` into the bar, for scripts.
    pub fn type_(f: *FindBar, text: [:0]const u8) void {
        f.entry.as(gtk.Editable).setText(text.ptr);
    }

    pub fn step(f: *FindBar, older: bool) void {
        const t = f.view.term() orelse return;
        if (!t.finding() or f.total == 0) return;
        f.showCount(t.findStep(older));
        f.view.widget().queueDraw();
    }

    fn showCount(f: *FindBar, index: ?usize) void {
        var buf: [32]u8 = undefined;
        const text = if (f.total == 0)
            std.fmt.bufPrintSentinel(&buf, "0/0", .{}, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "{d}/{d}", .{ (index orelse 0) + 1, f.total }, 0) catch "";
        f.count.setText(text.ptr);
    }

    fn changed(entry: *gtk.Entry, f: *FindBar) callconv(.c) void {
        if (f.isOpen()) f.setText(std.mem.span(entry.as(gtk.Editable).getText()));
    }
    fn nextSignal(_: *gtk.Entry, f: *FindBar) callconv(.c) void {
        f.step(true);
    }
    fn keyed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: @import("gdk").ModifierType, f: *FindBar) callconv(.c) c_int {
        if (keyval == 0xff1b) { // Escape
            f.close();
            return 1;
        }
        if ((keyval == 0xff0d or keyval == 0xff8d) and state.shift_mask) { // Shift+Return
            f.step(false);
            return 1;
        }
        return 0;
    }
    fn nextClicked(_: *gtk.Button, f: *FindBar) callconv(.c) void {
        f.step(true);
    }
    fn prevClicked(_: *gtk.Button, f: *FindBar) callconv(.c) void {
        f.step(false);
    }
    fn closeClicked(_: *gtk.Button, f: *FindBar) callconv(.c) void {
        f.close();
    }
};
