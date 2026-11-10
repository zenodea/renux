//! Custom themes: made and edited in Compy, saved as Ghostty theme files in
//! ~/.config/compy/themes, and picked like any other theme.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const themes = @import("themes.zig");
const stream = @import("stream.zig");

const gpa = std.heap.c_allocator;

/// The folder custom themes live in, created when needed.
pub fn dir() ?[:0]u8 {
    const d = std.fmt.allocPrintSentinel(gpa, "{s}/compy/themes", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return null;
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
    return (0.2126 * @as(f64, @floatFromInt((c >> 16) & 0xff)) + 0.7152 * @as(f64, @floatFromInt((c >> 8) & 0xff)) + 0.0722 * @as(f64, @floatFromInt(c & 0xff))) / 255;
}

fn mix(a: u32, b: u32, t: f64) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const x: f64 = @floatFromInt((a >> sh) & 0xff);
        const y: f64 = @floatFromInt((b >> sh) & 0xff);
        out |= @as(u32, @intFromFloat(@round(x + (y - x) * t))) << sh;
    }
    return out;
}

fn hsl(h: f64, s: f64, l: f64) u32 {
    const c = (1 - @abs(2 * l - 1)) * s;
    const hp = h / 60;
    const x = c * (1 - @abs(@mod(hp, 2) - 1));
    const rgb: [3]f64 = if (hp < 1) .{ c, x, 0 } else if (hp < 2) .{ x, c, 0 } else if (hp < 3) .{ 0, c, x } else if (hp < 4) .{ 0, x, c } else if (hp < 5) .{ x, 0, c } else .{ c, 0, x };
    const m = l - c / 2;
    var out: u32 = 0;
    for (rgb, 0..) |v, i| out |= @as(u32, @intFromFloat(@round(std.math.clamp(v + m, 0, 1) * 255))) << @intCast(16 - 8 * i);
    return out;
}

// The editor.

const Editor = struct {
    dialog: *adw.Dialog,
    name: *adw.EntryRow,
    path: ?[:0]u8,
    buttons: [19]*gtk.ColorDialogButton,
    done: *const fn (ctx: *anyopaque, path: []const u8) void,
    ctx: *anyopaque,

    fn get(e: *Editor, i: usize) u32 {
        const v = e.buttons[i].getRgba();
        const byte = struct {
            fn f(x: f32) u32 {
                return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
            }
        }.f;
        return (byte(v.f_red) << 16) | (byte(v.f_green) << 8) | byte(v.f_blue);
    }

    fn set(e: *Editor, i: usize, c: u32) void {
        const rgba: gdk.RGBA = .{ .f_red = @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255, .f_green = @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255, .f_blue = @as(f32, @floatFromInt(c & 0xff)) / 255, .f_alpha = 1 };
        e.buttons[i].setRgba(&rgba);
    }
};

const labels = [_][:0]const u8{ "Background", "Foreground", "Cursor", "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White", "Bright black", "Bright red", "Bright green", "Bright yellow", "Bright blue", "Bright magenta", "Bright cyan", "Bright white" };

/// Opens the editor on a theme file, or on a new theme starting from `start`'s colors.
pub fn open(parent: *gtk.Widget, path: ?[]const u8, start: stream.Colors, ctx: *anyopaque, done: *const fn (ctx: *anyopaque, path: []const u8) void) void {
    const e = gpa.create(Editor) catch return;
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
    if (path) |p| {
        const base = std.fs.path.basename(p);
        const z = gpa.dupeSentinel(u8, base, 0) catch return;
        defer gpa.free(z);
        name.as(gtk.Editable).setText(z.ptr);
    }
    g.add(name.as(gtk.Widget));
    page.add(g);
    e.* = .{ .dialog = dialog, .name = name, .path = if (path) |p| gpa.dupeSentinel(u8, p, 0) catch null else null, .buttons = undefined, .done = done, .ctx = ctx };
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
            const raw = std.mem.trim(u8, std.mem.span(ed.name.as(gtk.Editable).getText()), " ");
            if (raw.len == 0) return;
            // A name stays a plain file name.
            var clean: [96]u8 = undefined;
            var n: usize = 0;
            for (raw) |c| if (n < clean.len) {
                clean[n] = if (c == '/' or c == '\\') '-' else c;
                n += 1;
            };
            const d = dir() orelse return;
            defer gpa.free(d);
            const target = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ d, clean[0..n] }, 0) catch return;
            defer gpa.free(target);
            var palette: [16]u32 = undefined;
            for (0..16) |i| palette[i] = ed.get(3 + i);
            if (!save(target, ed.get(0), ed.get(1), ed.get(2), palette)) return;
            // A renamed theme leaves its old file behind no more.
            if (ed.path) |old| if (!std.mem.eql(u8, old, target)) {
                _ = glib.unlink(old.ptr);
            };
            ed.done(ed.ctx, target);
            _ = ed.dialog.close();
        }
        fn regenerated(_: *gtk.Button, ed: *Editor) callconv(.c) void {
            const p = regenerate(ed.get(0), ed.get(1));
            for (0..16) |i| ed.set(3 + i, p[i]);
        }
        fn closed(_: *adw.Dialog, ed: *Editor) callconv(.c) void {
            if (ed.path) |p| gpa.free(p);
            gpa.destroy(ed);
        }
    };
    _ = gtk.Button.signals.clicked.connect(save_button, *Editor, &H.saved, e, .{});
    _ = gtk.Button.signals.clicked.connect(regen, *Editor, &H.regenerated, e, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Editor, &H.closed, e, .{});
    dialog.present(parent);
}
