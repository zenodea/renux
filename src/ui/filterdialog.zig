//! What the command palette, Go to Anything and the folder browser share: a dialog with a search
//! field over a list, where typing filters, the arrows move through what's shown and Enter takes
//! the selected row.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");
const gobject = @import("gobject");

pub const Parts = struct {
    dialog: *adw.Dialog,
    /// Holds the search field and the list; callers add their own widgets around them.
    box: *gtk.Box,
    entry: *gtk.SearchEntry,
    list: *gtk.ListBox,
};

pub fn build(title: [:0]const u8, placeholder: [:0]const u8, width: c_int, height: c_int, css_class: [:0]const u8) Parts {
    const dialog = adw.Dialog.new();
    dialog.setTitle(title.ptr);
    dialog.setContentWidth(width);
    dialog.setContentHeight(height);
    const box = gtk.Box.new(.vertical, 8);
    box.as(gtk.Widget).addCssClass(css_class.ptr);
    const entry = gtk.SearchEntry.new();
    entry.setPlaceholderText(placeholder.ptr);
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

    // Up and down move through the rows shown while typing goes on in the search field.
    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *gtk.ListBox, &arrowKey, list, .{});
    entry.as(gtk.Widget).addController(keys.as(gtk.EventController));
    return .{ .dialog = dialog, .box = box, .entry = entry, .list = list };
}

/// Calls `callback` at once on every change to what's typed. The search field's own
/// `search-changed` waits 150 ms, long enough for Enter to act on the rows of the text before.
pub fn onQuery(entry: *gtk.SearchEntry, comptime T: type, callback: *const fn (*gtk.SearchEntry, T) callconv(.c) void, data: T) void {
    _ = gtk.Editable.signals.changed.connect(entry, T, callback, data, .{});
}

/// What's typed in the search field.
pub fn query(entry: *gtk.SearchEntry) []const u8 {
    return std.mem.span(entry.as(gtk.Editable).getText());
}

/// Whether a lower-case `haystack` holds every word of `text`, whatever their case and order.
pub fn matchesWords(haystack: []const u8, text: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |w| if (!containsIgnoreCase(haystack, w)) return false;
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, haystack[i..][0..needle.len]) |n, h| {
            if (std.ascii.toLower(n) != h) break;
        } else return true;
    }
    return false;
}

/// The row to select after an arrow key, among `count` rows shown with the one at `at` selected.
pub fn step(at: ?usize, count: usize, down: bool) ?usize {
    if (count == 0) return null;
    const p = at orelse return 0;
    if (down) return @min(p + 1, count - 1);
    return p -| 1;
}

fn arrowKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, list: *gtk.ListBox) callconv(.c) c_int {
    const down = keyval == gdk.KEY_Down or keyval == gdk.KEY_KP_Down;
    const up = keyval == gdk.KEY_Up or keyval == gdk.KEY_KP_Up;
    if (!down and !up) return 0;
    const selected = list.getSelectedRow();
    var at: ?usize = null;
    var count: usize = 0;
    var i: c_int = 0;
    while (list.getRowAtIndex(i)) |row| : (i += 1) {
        if (!usable(row)) continue;
        if (row == selected) at = count;
        count += 1;
    }
    const want = step(at, count, down) orelse return 1;
    var n: usize = 0;
    i = 0;
    while (list.getRowAtIndex(i)) |row| : (i += 1) {
        if (!usable(row)) continue;
        if (n == want) {
            list.selectRow(row);
            reveal(list, row);
            break;
        }
        n += 1;
    }
    return 1;
}

fn usable(row: *gtk.ListBoxRow) bool {
    return row.as(gtk.Widget).getVisible() != 0 and row.getSelectable() != 0;
}

/// Scrolls the list so a row shows, leaving the keyboard in the search field: giving the row
/// the focus and taking it back would select everything typed, and the next key would replace it.
fn reveal(list: *gtk.ListBox, row: *gtk.ListBoxRow) void {
    const ancestor = list.as(gtk.Widget).getAncestor(gtk.ScrolledWindow.getGObjectType()) orelse return;
    const scroller: *gtk.ScrolledWindow = @ptrCast(@alignCast(ancestor));
    const adj = scroller.getVadjustment();
    var x: f64 = 0;
    var y: f64 = 0;
    if (row.as(gtk.Widget).translateCoordinates(list.as(gtk.Widget), 0, 0, &x, &y) == 0) return;
    const h: f64 = @floatFromInt(row.as(gtk.Widget).getHeight());
    const top = adj.getValue();
    const page = adj.getPageSize();
    if (y < top) adj.setValue(y) else if (y + h > top + page) adj.setValue(y + h - page);
}

test "every word typed must be found" {
    try std.testing.expect(matchesWords("pane close app.close-pane kill", "clo"));
    try std.testing.expect(matchesWords("pane close app.close-pane kill", "KILL pane"));
    try std.testing.expect(matchesWords("anything", ""));
    try std.testing.expect(matchesWords("anything", "   "));
    try std.testing.expect(!matchesWords("pane close", "close tab"));
    try std.testing.expect(!matchesWords("ab", "abc"));
    // Words of any length are matched whole, not cut short.
    const long: [200]u8 = @splat('x');
    try std.testing.expect(matchesWords(&long, &long));
    try std.testing.expect(!matchesWords(long[0..199], &long));
}

test "arrows stop at the ends of the list" {
    try std.testing.expectEqual(@as(?usize, null), step(null, 0, true));
    try std.testing.expectEqual(@as(?usize, 0), step(null, 3, true));
    try std.testing.expectEqual(@as(?usize, 1), step(0, 3, true));
    try std.testing.expectEqual(@as(?usize, 2), step(2, 3, true));
    try std.testing.expectEqual(@as(?usize, 0), step(0, 3, false));
    try std.testing.expectEqual(@as(?usize, 1), step(2, 3, false));
}
