//! Custom themes: made and edited in Renux, saved as Ghostty theme files in
//! ~/.config/renux/themes, and picked like any other theme.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const themes = @import("../theme/themes.zig");
const stream = @import("../rex/stream.zig");
const Rgb = @import("../theme/theme.zig").Rgb;

const gpa = std.heap.c_allocator;

/// The folder custom themes live in, created when needed.
pub fn dir() ?[:0]u8 {
    const d = std.fmt.allocPrintSentinel(gpa, "{s}/renux/themes", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return null;
    _ = glib.mkdirWithParents(d.ptr, 0o700);
    return d;
}

/// The custom theme files, by full path, in name order.
pub fn list(out: *std.ArrayList([:0]u8)) void {
    const d = dir() orelse return;
    defer gpa.free(d);
    const gd = glib.Dir.open(d.ptr, 0, null) orelse return;
    defer gd.close();
    while (true) {
        // The binding says it never returns null, but the end of the folder does.
        const name = gd.readName();
        if (@intFromPtr(name) == 0) break;
        const n = std.mem.span(name);
        if (n.len == 0 or n[0] == '.') continue;
        out.append(gpa, std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ d, n }, 0) catch continue) catch {};
    }
    std.mem.sort([:0]u8, out.items, {}, struct {
        fn less(_: void, a: [:0]u8, b: [:0]u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.less);
}

/// Writes a theme as a Ghostty theme file.
pub fn save(path: []const u8, bg: u32, fg: u32, cursor: u32, palette: [16]u32) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.print(gpa, "background = #{x:0>6}\nforeground = #{x:0>6}\ncursor-color = #{x:0>6}\n", .{ bg & 0xffffff, fg & 0xffffff, cursor & 0xffffff }) catch return false;
    for (palette, 0..) |c, i| out.print(gpa, "palette = {d}=#{x:0>6}\n", .{ i, c & 0xffffff }) catch return false;
    const z = gpa.dupeSentinel(u8, path, 0) catch return false;
    defer gpa.free(z);
    return glib.fileSetContents(z.ptr, @ptrCast(out.items.ptr), @intCast(out.items.len), null) != 0;
}

/// Sixteen colors that suit a background: the usual hues, lighter on dark backgrounds.
pub fn regenerate(bg: u32, fg: u32) [16]u32 {
    const dark = luma(bg) < 0.5;
    const hues = [_]f64{ 0, 120, 50, 215, 300, 180 }; // red, green, yellow, blue, magenta, cyan
    var p: [16]u32 = undefined;
    p[0] = mix(bg, fg, if (dark) 0.15 else 0.85);
    p[7] = mix(bg, fg, if (dark) 0.75 else 0.35);
    p[8] = mix(bg, fg, if (dark) 0.4 else 0.6);
    p[15] = fg;
    for (hues, 0..) |h, i| {
        p[1 + i] = hsl(h, 0.6, if (dark) 0.62 else 0.42);
        p[9 + i] = hsl(h, 0.7, if (dark) 0.72 else 0.5);
    }
    return p;
}

fn luma(c: u32) f64 {
    return Rgb.of(c).luma();
}

fn mix(a: u32, b: u32, t: f64) u32 {
    return Rgb.of(a).mix(Rgb.of(b), t).pack();
}

fn hsl(h: f64, s: f64, l: f64) u32 {
    const c = (1 - @abs(2 * l - 1)) * s;
    const hp = h / 60;
    const x = c * (1 - @abs(@mod(hp, 2) - 1));
    const rgb: [3]f64 = if (hp < 1) .{ c, x, 0 } else if (hp < 2) .{ x, c, 0 } else if (hp < 3) .{ 0, c, x } else if (hp < 4) .{ 0, x, c } else if (hp < 5) .{ x, 0, c } else .{ c, 0, x };
    const m = l - c / 2;
    return (Rgb{ .r = rgb[0] + m, .g = rgb[1] + m, .b = rgb[2] + m }).pack();
}

pub const NameError = error{ Empty, Hidden, TooLong };

/// A theme's name as the name of its file: slashes and control characters become dashes. A
/// name that starts with a dot is refused, since the list of themes leaves hidden files out
/// and `.` and `..` aren't files at all.
pub fn fileName(buf: []u8, raw: []const u8) NameError![]const u8 {
    const name = std.mem.trim(u8, raw, " \t");
    if (name.len == 0) return error.Empty;
    if (name[0] == '.') return error.Hidden;
    if (name.len > buf.len) return error.TooLong;
    for (name, 0..) |c, i| buf[i] = if (c == '/' or c == '\\' or c < 0x20 or c == 0x7f) '-' else c;
    return buf[0..name.len];
}

// The editor.

const Editor = struct {
    dialog: *adw.Dialog,
    name: *adw.EntryRow,
    /// The group the name is in, whose description says why a name was refused.
    name_group: *adw.PreferencesGroup,
    path: ?[:0]u8,
    buttons: [19]*gtk.ColorDialogButton,
    done: Done,
    ctx: *anyopaque,

    fn get(e: *Editor, i: usize) u32 {
        return Rgb.fromRgba(e.buttons[i].getRgba()).pack();
    }

    fn set(e: *Editor, i: usize, c: u32) void {
        e.buttons[i].setRgba(&Rgb.of(c).rgba());
    }

    /// Says why the theme wasn't saved, by the name.
    fn refuse(e: *Editor, why: [:0]const u8) void {
        e.name.as(gtk.Widget).addCssClass("error");
        e.name_group.setDescription(why.ptr);
    }
};

/// Called with the file a theme was saved to, and the file it was in before when it was an
/// existing theme (the same one unless it was renamed).
pub const Done = *const fn (ctx: *anyopaque, old: ?[]const u8, path: []const u8) void;

const labels = [_][:0]const u8{ "Background", "Foreground", "Cursor", "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White", "Bright black", "Bright red", "Bright green", "Bright yellow", "Bright blue", "Bright magenta", "Bright cyan", "Bright white" };

/// Opens the editor on a theme file, or on a new theme starting from `start`'s colors.
pub fn open(parent: *gtk.Widget, path: ?[]const u8, start: stream.Colors, ctx: *anyopaque, done: Done) void {
    var colors = start;
    if (path) |p| if (themes.loadGhostty(p)) |c| {
        colors = c;
    };
    const dialog = adw.Dialog.new();
    dialog.setTitle(if (path == null) "New Theme" else "Edit Theme");
    dialog.setContentWidth(460);
    dialog.setContentHeight(640);
    const view = adw.ToolbarView.new();
    const header = adw.HeaderBar.new();
    const save_button = gtk.Button.newWithLabel("Save");
    save_button.as(gtk.Widget).addCssClass("suggested-action");
    header.packEnd(save_button.as(gtk.Widget));
    const regen = gtk.Button.newWithLabel("Regenerate Palette");
    regen.as(gtk.Widget).setTooltipText("Make the sixteen colors again from the background and foreground");
    header.packStart(regen.as(gtk.Widget));
    view.addTopBar(header.as(gtk.Widget));
    const page = adw.PreferencesPage.new();
    const g = adw.PreferencesGroup.new();
    const name = adw.EntryRow.new();
    name.as(adw.PreferencesRow).setTitle("Name");
    if (path) |p| if (gpa.dupeSentinel(u8, std.fs.path.basename(p), 0)) |z| {
        defer gpa.free(z);
        name.as(gtk.Editable).setText(z.ptr);
    } else |_| {};
    g.add(name.as(gtk.Widget));
    page.add(g);
    const e = gpa.create(Editor) catch return;
    e.* = .{ .dialog = dialog, .name = name, .name_group = g, .path = if (path) |p| gpa.dupeSentinel(u8, p, 0) catch null else null, .buttons = undefined, .done = done, .ctx = ctx };
    const groups = [_][:0]const u8{ "Colors", "Normal", "Bright" };
    var gi: usize = 0;
    var current_group: *adw.PreferencesGroup = undefined;
    for (labels, 0..) |label, i| {
        if (i == 0 or i == 3 or i == 11) {
            current_group = adw.PreferencesGroup.new();
            current_group.setTitle(groups[gi].ptr);
            gi += 1;
            page.add(current_group);
        }
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle(label.ptr);
        const b = gtk.ColorDialogButton.new(gtk.ColorDialog.new());
        b.as(gtk.Widget).setValign(.center);
        row.addSuffix(b.as(gtk.Widget));
        current_group.add(row.as(gtk.Widget));
        e.buttons[i] = b;
    }
    const pal = colors.palette orelse stream.builtin_palette;
    e.set(0, if (colors.bg != 0) colors.bg else 0x1e1e1e);
    e.set(1, if (colors.fg != 0) colors.fg else 0xd4d4d4);
    e.set(2, if (colors.cursor != 0) colors.cursor else colors.fg);
    for (0..16) |i| e.set(3 + i, pal[i]);
    view.setContent(page.as(gtk.Widget));
    dialog.setChild(view.as(gtk.Widget));

    const H = struct {
        fn saved(_: *gtk.Button, ed: *Editor) callconv(.c) void {
            var clean: [96]u8 = undefined;
            const name_text = fileName(&clean, std.mem.span(ed.name.as(gtk.Editable).getText())) catch |err| return ed.refuse(switch (err) {
                error.Empty => "Give the theme a name",
                error.Hidden => "A theme's name can't start with a dot",
                error.TooLong => "That name is too long",
            });
            const d = dir() orelse return ed.refuse("The themes folder couldn't be made");
            defer gpa.free(d);
            const target = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ d, name_text }, 0) catch return;
            defer gpa.free(target);
            // Saving under another theme's name would replace that theme.
            const same_file = if (ed.path) |old| std.mem.eql(u8, old, target) else false;
            if (!same_file and glib.fileTest(target.ptr, .{ .exists = true }) != 0) return ed.refuse("Another theme already has that name");
            var palette: [16]u32 = undefined;
            for (0..16) |i| palette[i] = ed.get(3 + i);
            if (!save(target, ed.get(0), ed.get(1), ed.get(2), palette)) return ed.refuse("The theme couldn't be saved");
            // A renamed theme leaves its old file behind no more.
            if (ed.path) |old| if (!same_file) {
                _ = glib.unlink(old.ptr);
            };
            ed.done(ed.ctx, ed.path, target);
            _ = ed.dialog.close();
        }
        fn regenerated(_: *gtk.Button, ed: *Editor) callconv(.c) void {
            const p = regenerate(ed.get(0), ed.get(1));
            for (0..16) |i| ed.set(3 + i, p[i]);
        }
        // Runs when the dialog itself is freed, after every button that points here is gone.
        fn freed(data: ?*anyopaque) callconv(.c) void {
            const ed: *Editor = @ptrCast(@alignCast(data.?));
            if (ed.path) |p| gpa.free(p);
            gpa.destroy(ed);
        }
    };
    _ = gtk.Button.signals.clicked.connect(save_button, *Editor, &H.saved, e, .{});
    _ = gtk.Button.signals.clicked.connect(regen, *Editor, &H.regenerated, e, .{});
    dialog.as(gobject.Object).setDataFull("renux-theme-editor", e, &H.freed);
    dialog.present(parent);
}

test "theme names become plain file names" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Night Owl", try fileName(&buf, "  Night Owl "));
    try std.testing.expectEqualStrings("a-b-c-d", try fileName(&buf, "a/b\\c\nd"));
    try std.testing.expectEqualStrings("café", try fileName(&buf, "café"));
    try std.testing.expectError(error.Empty, fileName(&buf, "   "));
    try std.testing.expectError(error.Hidden, fileName(&buf, ".."));
    try std.testing.expectError(error.Hidden, fileName(&buf, "."));
    try std.testing.expectError(error.Hidden, fileName(&buf, ".hidden"));
    // A name is never cut short, which could split a character in two.
    var long: [98]u8 = undefined;
    for (0..49) |i| @memcpy(long[i * 2 ..][0..2], "é");
    try std.testing.expectError(error.TooLong, fileName(&buf, &long));
    try std.testing.expectEqualStrings(long[0..96], try fileName(&buf, long[0..96]));
}

test "a regenerated palette keeps the background and foreground at its ends" {
    const p = regenerate(0x101010, 0xe0e0e0);
    try std.testing.expectEqual(@as(u32, 0xe0e0e0), p[15]);
    try std.testing.expectEqual(mix(0x101010, 0xe0e0e0, 0.15), p[0]);
    try std.testing.expectEqual(@as(u32, 0x2f2f2f), p[0]);
}
