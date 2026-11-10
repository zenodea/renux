//! The settings window, laid out like Rex's: sections in a sidebar, their settings on the right.
//! Everything here changes only Renux; key bindings stay in the person's Rex config.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const theme_editor = @import("theme_editor.zig");
const cairo = @import("cairo");
const adw = @import("adw");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const settings = @import("settings.zig");
const themes = @import("../theme/themes.zig");
const Rgb = @import("../theme/theme.zig").Rgb;
const shortcuts = @import("shortcuts.zig");
const icons = @import("../icons/icons.zig");
const art = @import("settings_art.zig");
const App = @import("../app/app.zig").App;
const updates = @import("../rex/updates.zig");

const gpa = std.heap.c_allocator;

const Section = struct { title: [:0]const u8, icon: icons.Kind, build: *const fn (*Ctx) *gtk.Widget };

const sections = [_]Section{
    .{ .title = "Server", .icon = .server, .build = serverPage },
    .{ .title = "Interface", .icon = .interface, .build = interfacePage },
    .{ .title = "Themes", .icon = .palette, .build = themesPage },
    .{ .title = "Terminal", .icon = .terminal, .build = terminalPage },
    .{ .title = "Shortcuts", .icon = .keyboard, .build = shortcutsPage },
    .{ .title = "Notifications", .icon = .bell, .build = notificationsPage },
    .{ .title = "Remote Hosts", .icon = .add_host, .build = hostsPage },
};

/// One open Settings window. Everything its rows point at is in `arena` or in here, and both
/// are freed only when the dialog itself is (`freed`), after every row is gone: a row that
/// still answers while the window closes finds its data in place.
const Ctx = struct {
    app: *App,
    dialog: *adw.Dialog,
    stack: *gtk.Stack,
    list: *gtk.ListBox,
    arena: std.heap.ArenaAllocator,
    /// Pages are built when first shown, so opening Settings doesn't build all seven.
    built: [sections.len]bool = @splat(false),
    banner: *adw.Banner,
    tick: c_uint = 0,
    /// The Server page's status row, kept up to date while the window is open.
    status: ?*adw.ActionRow = null,
    status_retry: ?*gtk.Widget = null,
    /// The check marks of the theme rows.
    theme_checks: std.ArrayList(*ThemePick) = .empty,
    /// Theme values for the light and dark pickers: "" follows the host.
    theme_values: std.ArrayList([:0]u8) = .empty,
    font_family: ?*adw.ComboRow = null,
    font_size: ?*adw.SpinRow = null,
    font_names: std.ArrayList([:0]u8) = .empty,
    font_preview: ?*gtk.Label = null,
    /// The drawings that follow the settings: each is drawn again when a setting changes.
    drawings: std.ArrayList(*gtk.Widget) = .empty,
    shortcuts_page: shortcuts.Page,

    fn al(ctx: *Ctx) std.mem.Allocator {
        return ctx.arena.allocator();
    }

    /// A value a row's handlers point at, which lives as long as the window.
    fn keep(ctx: *Ctx, value: anytype) ?*@TypeOf(value) {
        const slot = ctx.al().create(@TypeOf(value)) catch return null;
        slot.* = value;
        return slot;
    }
};

/// The Settings window that is open, if one is. There is only ever one.
var open_ctx: ?*Ctx = null;

pub fn open(app: *App) void {
    // Asked for again while it's open: the one window takes the keyboard back.
    if (open_ctx) |shown| {
        _ = shown.dialog.as(gtk.Widget).grabFocus();
        return;
    }
    const ctx = gpa.create(Ctx) catch return;
    ctx.* = .{
        .app = app,
        .dialog = adw.Dialog.new(),
        .stack = gtk.Stack.new(),
        .list = gtk.ListBox.new(),
        .arena = .init(gpa),
        .banner = adw.Banner.new(""),
        .shortcuts_page = undefined,
    };
    ctx.shortcuts_page = .{ .al = ctx.al() };
    open_ctx = ctx;
    const d = ctx.dialog;
    d.setTitle("Settings");
    d.setContentWidth(900);
    d.setContentHeight(640);
    d.as(gobject.Object).setDataFull("renux-settings", ctx, &freed);
    _ = adw.Dialog.signals.closed.connect(d, *Ctx, &closed, ctx, .{});

    ctx.list.as(gtk.Widget).addCssClass("navigation-sidebar");
    _ = gtk.ListBox.signals.row_selected.connect(ctx.list, *Ctx, &picked, ctx, .{});
    for (sections) |sec| {
        const line = gtk.Box.new(.horizontal, 10);
        line.append(icons.image(sec.icon, 16));
        const label = gtk.Label.new(sec.title.ptr);
        label.setXalign(0);
        line.append(label.as(gtk.Widget));
        const row = gtk.ListBoxRow.new();
        row.setChild(line.as(gtk.Widget));
        ctx.list.append(row.as(gtk.Widget));
    }
    ctx.stack.setTransitionType(.crossfade);

    const side = adw.ToolbarView.new();
    const side_header = adw.HeaderBar.new();
    side_header.setShowEndTitleButtons(0);
    side.addTopBar(side_header.as(gtk.Widget));
    side.setContent(ctx.list.as(gtk.Widget));
    const content = adw.ToolbarView.new();
    content.addTopBar(adw.HeaderBar.new().as(gtk.Widget));
    content.addTopBar(ctx.banner.as(gtk.Widget));
    content.setContent(ctx.stack.as(gtk.Widget));
    const split = adw.NavigationSplitView.new();
    split.setSidebar(adw.NavigationPage.new(side.as(gtk.Widget), "Settings"));
    split.setContent(adw.NavigationPage.new(content.as(gtk.Widget), "Settings"));
    split.setMinSidebarWidth(200);
    d.setChild(split.as(gtk.Widget));
    // Development: RENUX_SETTINGS_PAGE opens on a page by its number.
    const first: c_int = if (!@import("build_options").dev) 0 else if (std.c.getenv("RENUX_SETTINGS_PAGE")) |n| std.fmt.parseInt(c_int, std.mem.span(n), 10) catch 0 else 0;
    ctx.list.selectRow(ctx.list.getRowAtIndex(first));
    refresh(ctx);
    ctx.tick = glib.timeoutAdd(500, &ticked, ctx);
    d.present(app.window.as(gtk.Widget));
}

/// The window closed. Its rows may still be on their way out, so nothing is freed yet.
fn closed(_: *adw.Dialog, ctx: *Ctx) callconv(.c) void {
    if (ctx.tick != 0) _ = glib.Source.remove(ctx.tick);
    ctx.tick = 0;
    shortcuts.closed(&ctx.shortcuts_page);
    if (open_ctx == ctx) open_ctx = null;
}

/// The dialog was freed, and its rows before it.
fn freed(data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (ctx.tick != 0) _ = glib.Source.remove(ctx.tick);
    shortcuts.closed(&ctx.shortcuts_page);
    if (open_ctx == ctx) open_ctx = null;
    ctx.arena.deinit();
    gpa.destroy(ctx);
}

fn ticked(data: ?*anyopaque) callconv(.c) c_int {
    refresh(@ptrCast(@alignCast(data.?)));
    return 1;
}

/// What can change while the window is open: the connection's state and whether settings.ini
/// can be saved.
fn refresh(ctx: *Ctx) void {
    if (settings.problem) |why| ctx.banner.setTitle(why.ptr);
    ctx.banner.setRevealed(@intFromBool(settings.problem != null));
    showStatus(ctx);
}

fn picked(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, ctx: *Ctx) callconv(.c) void {
    const r = row orelse return;
    const index = r.getIndex();
    if (index < 0 or index >= sections.len) return;
    const i: usize = @intCast(index);
    if (!ctx.built[i]) {
        ctx.built[i] = true;
        _ = ctx.stack.addNamed(sections[i].build(ctx), sections[i].title.ptr);
    }
    ctx.stack.setVisibleChildName(sections[i].title.ptr);
}

// Building blocks.

fn page() *adw.PreferencesPage {
    return adw.PreferencesPage.new();
}

fn group(p: *adw.PreferencesPage, title: [:0]const u8, description: ?[:0]const u8) *adw.PreferencesGroup {
    const g = adw.PreferencesGroup.new();
    g.setTitle(title.ptr);
    if (description) |d| g.setDescription(d.ptr);
    p.add(g);
    return g;
}

/// What a row's handlers need: the window, the setting the row is for, and what to do after
/// the setting changes.
fn Bound(comptime T: type) type {
    return struct {
        ctx: *Ctx,
        field: *T,
        after: ?*const fn (*App) void,

        fn changed(b: *@This()) void {
            settings.save();
            if (b.after) |f| f(b.ctx.app);
            redrawArt(b.ctx);
        }
    };
}

/// Development: the whole of the page showing, including what is scrolled out of sight, for
/// a screenshot.
pub fn wholePage() ?*gtk.Widget {
    const ctx = open_ctx orelse return null;
    var w = ctx.stack.getVisibleChild() orelse return null;
    // A preferences page keeps its rows in a scrolled window; what is inside that is the page.
    var depth: usize = 0;
    while (depth < 6) : (depth += 1) {
        if (w.getAncestor(gtk.Viewport.getGObjectType()) == w) return w.getFirstChild();
        w = w.getFirstChild() orelse return null;
    }
    return null;
}

/// Draws the window's pictures and samples again, after a setting they show changed.
fn redrawArt(ctx: *Ctx) void {
    for (ctx.drawings.items) |w| w.queueDraw();
}

fn keepDrawing(ctx: *Ctx, w: *gtk.Widget) *gtk.Widget {
    ctx.drawings.append(ctx.al(), w) catch {};
    return w;
}

/// A row that holds something of its own instead of a title: a strip of cards, a sample.
fn plainRow(g: *adw.PreferencesGroup, child: *gtk.Widget) void {
    const row = adw.PreferencesRow.new();
    row.as(gtk.ListBoxRow).setActivatable(0);
    row.as(gtk.Widget).setFocusable(0);
    row.as(gtk.Widget).addCssClass("settings-plain-row");
    row.as(gtk.ListBoxRow).setChild(child);
    g.add(row.as(gtk.Widget));
}

/// A strip of picture cards under a small heading, to start filling.
fn cardStrip(g: *adw.PreferencesGroup, title: [:0]const u8) *gtk.Box {
    const column = gtk.Box.new(.vertical, 8);
    column.as(gtk.Widget).addCssClass("settings-cards");
    const heading = gtk.Label.new(title.ptr);
    heading.setXalign(0);
    heading.as(gtk.Widget).addCssClass("settings-cards-title");
    column.append(heading.as(gtk.Widget));
    // The cards share the row's whole width evenly.
    const strip = gtk.Box.new(.horizontal, 10);
    strip.setHomogeneous(1);
    column.append(strip.as(gtk.Widget));
    plainRow(g, column.as(gtk.Widget));
    return strip;
}

/// One card: a drawing with its name under it, lit while it is the one picked.
fn pickCard(ctx: *Ctx, kind: art.Art, label: [:0]const u8) *gtk.ToggleButton {
    const b = gtk.ToggleButton.new();
    const column = gtk.Box.new(.vertical, 6);
    const picture = keepDrawing(ctx, art.card(kind, 104, 68));
    picture.setHexpand(1);
    column.append(picture);
    const name = gtk.Label.new(label.ptr);
    column.append(name.as(gtk.Widget));
    b.as(gtk.Button).setChild(column.as(gtk.Widget));
    b.as(gtk.Widget).addCssClass("pick-card");
    b.as(gtk.Widget).setHexpand(1);
    b.as(gtk.Widget).addCssClass("flat");
    return b;
}

/// A choice among a few named things, each shown as a picture card.
fn cards(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, comptime E: type, field: *E, labels: []const [:0]const u8, pictures: []const art.Art, after: *const fn (*App) void) void {
    const sc = ctx.keep(Bound(E){ .ctx = ctx, .field = field, .after = after }) orelse return;
    const strip = cardStrip(g, title);
    var first: ?*gtk.ToggleButton = null;
    inline for (comptime std.enums.values(E), 0..) |value, i| {
        const b = pickCard(ctx, pictures[i], labels[i]);
        if (first) |fb| b.setGroup(fb) else first = b;
        b.setActive(@intFromBool(field.* == value));
        const Pick = struct {
            fn changed(btn: *gtk.ToggleButton, bound: *Bound(E)) callconv(.c) void {
                if (btn.getActive() == 0 or bound.field.* == value) return;
                bound.field.* = value;
                bound.changed();
            }
        };
        _ = gtk.ToggleButton.signals.toggled.connect(b, *Bound(E), &Pick.changed, sc, .{});
        strip.append(b.as(gtk.Widget));
    }
}

/// Two picture cards for an on-or-off setting whose two states each have a name.
fn boolCards(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, field: *bool, off: [:0]const u8, off_art: art.Art, on: [:0]const u8, on_art: art.Art, after: *const fn (*App) void) void {
    const sc = ctx.keep(Bound(bool){ .ctx = ctx, .field = field, .after = after }) orelse return;
    const strip = cardStrip(g, title);
    const off_card = pickCard(ctx, off_art, off);
    const on_card = pickCard(ctx, on_art, on);
    on_card.setGroup(off_card);
    (if (field.*) on_card else off_card).setActive(1);
    strip.append(off_card.as(gtk.Widget));
    strip.append(on_card.as(gtk.Widget));
    const H = struct {
        fn changed(btn: *gtk.ToggleButton, bound: *Bound(bool)) callconv(.c) void {
            const v = btn.getActive() != 0;
            if (v == bound.field.*) return;
            bound.field.* = v;
            bound.changed();
        }
    };
    _ = gtk.ToggleButton.signals.toggled.connect(on_card, *Bound(bool), &H.changed, sc, .{});
}

/// A live sample of the terminal at the top of a group.
fn sampleRow(ctx: *Ctx, g: *adw.PreferencesGroup, kind: art.Sample) void {
    const box = gtk.Box.new(.vertical, 0);
    box.as(gtk.Widget).addCssClass("settings-sample-row");
    box.append(keepDrawing(ctx, art.sample(kind)));
    plainRow(g, box.as(gtk.Widget));
}

/// A switch with the colored mark of the status it is about.
fn statusSwitch(ctx: *Ctx, g: *adw.PreferencesGroup, kind: art.Status, title: [:0]const u8, subtitle: [:0]const u8, field: *bool) void {
    const row = adw.SwitchRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    row.as(adw.ActionRow).setSubtitle(subtitle.ptr);
    row.as(adw.ActionRow).addPrefix(art.status(kind));
    row.setActive(@intFromBool(field.*));
    g.add(row.as(gtk.Widget));
    const t = ctx.keep(Bound(bool){ .ctx = ctx, .field = field, .after = null }) orelse return;
    _ = gobject.Object.signals.notify.connect(row, *Bound(bool), &toggled, t, .{ .detail = "active" });
}

/// A button for the end of a row.
fn rowButton(label: [:0]const u8) *gtk.Button {
    const b = gtk.Button.newWithLabel(label.ptr);
    b.as(gtk.Widget).addCssClass("flat");
    b.as(gtk.Widget).setValign(.center);
    return b;
}

/// A switch bound to one of the settings, with an optional follow-up when it changes.
fn switchRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *bool, after: ?*const fn (*App) void) void {
    const row = adw.SwitchRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |s| row.as(adw.ActionRow).setSubtitle(s.ptr);
    row.setActive(@intFromBool(field.*));
    g.add(row.as(gtk.Widget));
    const t = ctx.keep(Bound(bool){ .ctx = ctx, .field = field, .after = after }) orelse return;
    _ = gobject.Object.signals.notify.connect(row, *Bound(bool), &toggled, t, .{ .detail = "active" });
}

fn toggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, t: *Bound(bool)) callconv(.c) void {
    const on = row.getActive() != 0;
    if (on == t.field.*) return;
    t.field.* = on;
    t.changed();
}

/// A number spinner bound to one of the settings, applied as it changes.
fn numberRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *f64, min: f64, max: f64, step: f64, digits: c_uint, after: *const fn (*App) void) void {
    const row = adw.SpinRow.newWithRange(min, max, step);
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |s| row.as(adw.ActionRow).setSubtitle(s.ptr);
    row.setDigits(digits);
    row.setValue(field.*);
    g.add(row.as(gtk.Widget));
    const n = ctx.keep(Bound(f64){ .ctx = ctx, .field = field, .after = after }) orelse return;
    _ = gobject.Object.signals.notify.connect(row, *Bound(f64), &numberChanged, n, .{ .detail = "value" });
}

fn numberChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, n: *Bound(f64)) callconv(.c) void {
    const v = row.getValue();
    if (v == n.field.*) return;
    n.field.* = v;
    n.changed();
}

/// A 20 to 100 percent spinner for an opacity, stored as 0.2 to 1.
fn percentRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: [:0]const u8, field: *f64) void {
    rangePercentRow(ctx, g, title, subtitle, field, 20, 100);
}

fn rangePercentRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *f64, min: f64, max: f64) void {
    const row = adw.SpinRow.newWithRange(min, max, 5);
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |sub| row.as(adw.ActionRow).setSubtitle(sub.ptr);
    row.setValue(@round(field.* * 100));
    g.add(row.as(gtk.Widget));
    const n = ctx.keep(Bound(f64){ .ctx = ctx, .field = field, .after = App.applyLook }) orelse return;
    _ = gobject.Object.signals.notify.connect(row, *Bound(f64), &percentChanged, n, .{ .detail = "value" });
}

fn percentChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, n: *Bound(f64)) callconv(.c) void {
    const v = row.getValue() / 100;
    if (v == n.field.*) return;
    n.field.* = v;
    n.changed();
}

/// A color setting: a picked color, or none (0) for the default that `reset` names.
fn colorPicker(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *u32, reset: [:0]const u8, after: *const fn (*App) void) void {
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |sub| row.setSubtitle(sub.ptr);
    const button = gtk.ColorDialogButton.new(gtk.ColorDialog.new());
    button.as(gtk.Widget).setValign(.center);
    if (field.* != 0) button.setRgba(&Rgb.of(field.*).rgba());
    const default = rowButton(reset);
    row.addSuffix(default.as(gtk.Widget));
    row.addSuffix(button.as(gtk.Widget));
    g.add(row.as(gtk.Widget));
    const cc = ctx.keep(Bound(u32){ .ctx = ctx, .field = field, .after = after }) orelse return;
    const H = struct {
        fn picked(b: *gtk.ColorDialogButton, _: *gobject.ParamSpec, x: *Bound(u32)) callconv(.c) void {
            // Pure black is kept as the next shade up, since 0 means the default.
            const c = @max(Rgb.fromRgba(b.getRgba()).pack(), 1);
            if (c == x.field.*) return;
            x.field.* = c;
            x.changed();
        }
        fn cleared(_: *gtk.Button, x: *Bound(u32)) callconv(.c) void {
            x.field.* = 0;
            x.changed();
        }
    };
    _ = gobject.Object.signals.notify.connect(button, *Bound(u32), &H.picked, cc, .{ .detail = "rgba" });
    _ = gtk.Button.signals.clicked.connect(default, *Bound(u32), &H.cleared, cc, .{});
}

/// Segmented buttons for an enum setting, like Rex's Comfortable / Compact.
fn segments(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, comptime E: type, field: *E, labels: []const [:0]const u8, after: *const fn (*App) void) void {
    const sc = ctx.keep(Bound(E){ .ctx = ctx, .field = field, .after = after }) orelse return;
    const box = segmentBox(g, title);
    var first: ?*gtk.ToggleButton = null;
    inline for (comptime std.enums.values(E), 0..) |value, i| {
        const b = gtk.ToggleButton.newWithLabel(labels[i].ptr);
        if (first) |fb| b.setGroup(fb) else first = b;
        b.setActive(@intFromBool(field.* == value));
        const Seg = struct {
            fn changed(btn: *gtk.ToggleButton, s: *Bound(E)) callconv(.c) void {
                if (btn.getActive() == 0 or s.field.* == value) return;
                s.field.* = value;
                s.changed();
            }
        };
        _ = gtk.ToggleButton.signals.toggled.connect(b, *Bound(E), &Seg.changed, sc, .{});
        box.append(b.as(gtk.Widget));
    }
}

/// Two segmented buttons for an on-or-off setting whose two states each have a name.
fn boolSegments(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, field: *bool, off: [:0]const u8, on: [:0]const u8, after: *const fn (*App) void) void {
    const sc = ctx.keep(Bound(bool){ .ctx = ctx, .field = field, .after = after }) orelse return;
    const box = segmentBox(g, title);
    const off_button = gtk.ToggleButton.newWithLabel(off.ptr);
    const on_button = gtk.ToggleButton.newWithLabel(on.ptr);
    on_button.setGroup(off_button);
    (if (field.*) on_button else off_button).setActive(1);
    box.append(off_button.as(gtk.Widget));
    box.append(on_button.as(gtk.Widget));
    const H = struct {
        // Only the second button is watched: it is on exactly when the setting is.
        fn changed(btn: *gtk.ToggleButton, s: *Bound(bool)) callconv(.c) void {
            const v = btn.getActive() != 0;
            if (v == s.field.*) return;
            s.field.* = v;
            s.changed();
        }
    };
    _ = gtk.ToggleButton.signals.toggled.connect(on_button, *Bound(bool), &H.changed, sc, .{});
}

fn segmentBox(g: *adw.PreferencesGroup, title: [:0]const u8) *gtk.Box {
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    const box = gtk.Box.new(.horizontal, 0);
    box.as(gtk.Widget).addCssClass("linked");
    box.as(gtk.Widget).setValign(.center);
    row.addSuffix(box.as(gtk.Widget));
    g.add(row.as(gtk.Widget));
    return box;
}

/// Sets a row's title or subtitle from text that isn't zero-terminated.
fn setRowText(row: *adw.ActionRow, title: ?[]const u8, subtitle: ?[]const u8) void {
    if (title) |t| if (gpa.dupeSentinel(u8, t, 0)) |z| {
        defer gpa.free(z);
        row.as(adw.PreferencesRow).setTitle(z.ptr);
    } else |_| {};
    if (subtitle) |t| if (gpa.dupeSentinel(u8, t, 0)) |z| {
        defer gpa.free(z);
        row.setSubtitle(z.ptr);
    } else |_| {};
}

// Server.

fn serverPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const a = ctx.app;
    const g = group(p, "Rex Server", "The server Renux is showing now. Add more under Remote Hosts.");
    const status = adw.ActionRow.new();
    const retry = gtk.Button.newWithLabel("Reconnect");
    retry.as(gtk.Widget).setValign(.center);
    retry.as(gtk.Actionable).setActionName("app.retry");
    status.addSuffix(retry.as(gtk.Widget));
    g.add(status.as(gtk.Widget));
    ctx.status = status;
    ctx.status_retry = retry.as(gtk.Widget);
    showStatus(ctx);
    if (a.server) |s| {
        const addr = adw.ActionRow.new();
        addr.as(adw.PreferencesRow).setTitle("Address");
        setRowText(addr, null, s.url);
        addr.setSubtitleSelectable(1);
        g.add(addr.as(gtk.Widget));
    }
    switchRow(ctx, g, "Look for Rex updates", "Reads Rex's public list of releases and says when a server could be updated. Updating is done on the server's computer.", &settings.current.rex_updates, &App.lookForUpdates);

    if (a.server != null) {
        const pair = group(p, "Pair a Phone", null);
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle("Pair device with QR code");
        row.setSubtitle("Compy on Android scans this server's address");
        const show = rowButton("Show Code");
        _ = gtk.Button.signals.clicked.connect(show, *Ctx, &showPairing, ctx, .{});
        row.addSuffix(show.as(gtk.Widget));
        pair.add(row.as(gtk.Widget));
    }
    @import("../app/manage.zig").localServerGroup(p, a);
    const more = group(p, "Help", null);
    inline for (.{ .{ "Diagnostics", "What Renux knows about each host, to copy into a bug report", "client.diagnostics" }, .{ "Welcome pages", "The short tour from the first launch", "client.onboarding" } }) |e| {
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle(e[0]);
        row.setSubtitle(e[1]);
        const open_button = rowButton("Open");
        const H = struct {
            fn run(_: *gtk.Button, cx: *Ctx) callconv(.c) void {
                if (cx.app.current) |h| _ = App.perform(h, e[2], null, null);
            }
        };
        _ = gtk.Button.signals.clicked.connect(open_button, *Ctx, &H.run, ctx, .{});
        row.addSuffix(open_button.as(gtk.Widget));
        more.add(row.as(gtk.Widget));
    }

    // This computer's Tailscale, which Rex servers often use to let it in.
    const tsg = group(p, "Tailscale", "Read from this computer. Rex's own Tailscale settings live in the Rex app on the server's machine.");
    const ts_row = adw.ActionRow.new();
    ts_row.as(adw.PreferencesRow).setTitle("Checking Tailscale…");
    // Asked without waiting; the row is kept until the answer has been written on it.
    _ = ts_row.as(gobject.Object).ref();
    @import("../rex/tailscale.zig").read(ts_row, &tailscaleRead);
    tsg.add(ts_row.as(gtk.Widget));

    const info = group(p, "Client Info", "How this computer appears in Rex's list of clients. It applies on the next connection.");
    const label = adw.EntryRow.new();
    label.as(adw.PreferencesRow).setTitle("Label");
    if (gpa.dupeSentinel(u8, if (settings.current.client_label.len > 0) settings.current.client_label else std.mem.span(glib.getHostName()), 0)) |current| {
        defer gpa.free(current);
        label.as(gtk.Editable).setText(current.ptr);
    } else |_| {}
    label.setShowApplyButton(1);
    _ = adw.EntryRow.signals.apply.connect(label, *Ctx, &labelApplied, ctx, .{});
    info.add(label.as(gtk.Widget));
    return p.as(gtk.Widget);
}

/// Writes the connection's state on the Server page's first row, now and as it changes.
fn showStatus(ctx: *Ctx) void {
    const status = ctx.status orelse return;
    const s = ctx.app.server orelse {
        status.as(adw.PreferencesRow).setTitle("Not connected");
        status.setSubtitle("");
        if (ctx.status_retry) |r| r.setVisible(0);
        return;
    };
    setRowText(status, if (ctx.app.current) |h| h.label else "Rex", null);
    var buf: [320]u8 = undefined;
    const sub = switch (s.state) {
        .online => if (updates.available(s.rex_version)) |newer|
            std.fmt.bufPrintSentinel(&buf, "Connected · Rex {s}\nUpdate available: {s}", .{ s.rex_version orelse "", newer }, 0)
        else
            std.fmt.bufPrintSentinel(&buf, "Connected{s}{s}", .{ if (s.rex_version != null) " · Rex " else "", s.rex_version orelse "" }, 0),
        .connecting => std.fmt.bufPrintSentinel(&buf, "Connecting…", .{}, 0),
        .offline => std.fmt.bufPrintSentinel(&buf, "Offline: {s}", .{s.reason.items}, 0),
    } catch "";
    status.setSubtitle(sub.ptr);
    if (ctx.status_retry) |r| r.setVisible(1);
}

fn tailscaleRead(data: ?*anyopaque, ts: *@import("../rex/tailscale.zig").Status) void {
    const ts_row: *adw.ActionRow = @ptrCast(@alignCast(data.?));
    defer ts_row.as(gobject.Object).unref();
    if (ts.running) {
        var tb: [256]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&tb, "Signed in{s}{s}", .{ if (ts.login != null) " as " else "", ts.login orelse "" }, 0) catch "Signed in";
        ts_row.as(adw.PreferencesRow).setTitle(title.ptr);
        var sb: [256]u8 = undefined;
        const sub = std.fmt.bufPrintSentinel(&sb, "{s}{s}{d} Rex host{s} on the tailnet", .{ ts.tailnet orelse "", if (ts.tailnet != null) " · " else "", ts.rex_hosts.items.len, if (ts.rex_hosts.items.len == 1) "" else "s" }, 0) catch "";
        ts_row.setSubtitle(sub.ptr);
    } else {
        ts_row.as(adw.PreferencesRow).setTitle("Not on Tailscale");
        var wb: [256]u8 = undefined;
        const why = std.fmt.bufPrintSentinel(&wb, "{s}", .{ts.problem orelse "Tailscale isn't connected"}, 0) catch "";
        ts_row.setSubtitle(why.ptr);
    }
}

fn labelApplied(row: *adw.EntryRow, _: *Ctx) callconv(.c) void {
    settings.setString(&settings.current.client_label, std.mem.trim(u8, std.mem.span(row.as(gtk.Editable).getText()), " "));
}

// Interface.

fn interfacePage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const tabs = group(p, "Tabs", "Each session's windows, as tabs in the sidebar or above the panes");
    cards(ctx, tabs, "Tab style", settings.TabPosition, &settings.current.tab_position, &.{ "Left Side", "Right Side", "Above" }, &.{ .tabs_left, .tabs_right, .tabs_above }, App.tabsChanged);
    switchRow(ctx, tabs, "Fill available space", "Tabs above the panes share the width", &settings.current.tab_fill, App.tabsChanged);
    switchRow(ctx, tabs, "Show each process", "A tab lists every program in its window", &settings.current.tab_processes, App.tabsChanged);
    const panes_group = group(p, "Pane Behavior", null);
    switchRow(ctx, panes_group, "Focus follows mouse", "Pointing at a pane gives it the keyboard", &settings.current.focus_follows_mouse, null);
    rangePercentRow(ctx, panes_group, "Fade inactive panes", "How much panes without the keyboard dim, in percent", &settings.current.fade_inactive, 0, 60);
    switchRow(ctx, panes_group, "Fade panes for inactive windows", "Dim every pane while Renux isn't the window in use", &settings.current.fade_inactive_window, App.redrawAllPub);
    switchRow(ctx, panes_group, "Autobalance splits", "Panes share space evenly after one opens or closes", &settings.current.autobalance, null);
    switchRow(ctx, panes_group, "Match program backgrounds", "A pane's frame takes the background color of the program in it", &settings.current.match_program_bg, App.applyLook);
    switchRow(ctx, panes_group, "Rounded selection corners", null, &settings.current.rounded_selection, App.redrawAllPub);
    const hl = group(p, "Active Pane Highlight", null);
    switchRow(ctx, hl, "Show border on active pane", null, &settings.current.highlight_border, App.applyLook);
    switchRow(ctx, hl, "Animate active pane highlight", "The border fades in as focus moves", &settings.current.highlight_animate, App.applyLook);
    rangePercentRow(ctx, hl, "Highlight opacity", null, &settings.current.highlight_opacity, 10, 100);
    colorPicker(ctx, hl, "Highlight color", "The theme's accent unless one is picked", &settings.current.highlight_color, "Use Accent", App.applyLook);
    const extras = group(p, "Window", null);
    switchRow(ctx, extras, "Show window on launch", "Off starts Renux hidden; renux --toggle, bound to a desktop shortcut, shows and hides it", &settings.current.show_on_launch, null);
    switchRow(ctx, extras, "Trackpad gestures", "Swipe sideways with two fingers to switch tabs", &settings.current.trackpad_gestures, null);
    numberRow(ctx, extras, "Trackpad scroll speed", "How far text moves for the fingers' movement; 2 is what terminals on a Mac do", &settings.current.scroll_speed, 0.5, 5, 0.25, 2, App.redrawAllPub);
    numberRow(ctx, extras, "Sidebar text size", "As a multiple of the normal size", &settings.current.sidebar_text_scale, 0.8, 1.4, 0.05, 2, App.applyLook);
    switchRow(ctx, extras, "Unread badge", "The number of panes that need you, on the Dock or the desktop's launcher", &settings.current.unread_badge, null);
    const go = group(p, "Go to Anything", null);
    switchRow(ctx, go, "Show recently used paths", "Folders your panes were in, to change to again", &settings.current.recent_paths_shown, null);
    const look = group(p, "Appearance", null);
    cards(ctx, look, "Color scheme", settings.ColorScheme, &settings.current.color_scheme, &.{ "Auto", "Light", "Dark" }, &.{ .scheme_auto, .scheme_light, .scheme_dark }, App.themeChanged);
    const panes = group(p, "Panes", null);
    const Tight = struct {
        fn apply(app: *App) void {
            app.setTight(settings.current.tight);
        }
    };
    boolCards(ctx, panes, "Pane style", &settings.current.tight, "Comfortable", .panes_roomy, "Compact", .panes_compact, Tight.apply);
    switchRow(ctx, panes, "Show pane headers", "The title row with the program, folder and pane buttons", &settings.current.show_headers, App.headersChanged);
    switchRow(ctx, panes, "Use color for program icons", "Brand colors for known programs, like Rex's tab icons", &settings.current.brand_icons, App.redrawAll);
    return p.as(gtk.Widget);
}

// Themes.

const ThemePick = struct { ctx: *Ctx, value: [:0]const u8, check: *gtk.Widget };

/// Fills a picker's list with every theme, and `ctx.theme_values` with the setting for each.
fn themeNames(ctx: *Ctx, list: *gtk.StringList) void {
    const values = &ctx.theme_values;
    values.clearRetainingCapacity();
    // A name goes in the list only once its value is in: the two stay in step.
    values.append(ctx.al(), ctx.al().dupeSentinel(u8, "", 0) catch return) catch return;
    list.append("Follow host");
    for (&themes.builtins) |*t| {
        const z = ctx.al().dupeSentinel(u8, t.name, 0) catch continue;
        values.append(ctx.al(), z) catch continue;
        list.append(z.ptr);
    }
    var custom: std.ArrayList([:0]u8) = .empty;
    defer {
        for (custom.items) |c| gpa.free(c);
        custom.deinit(gpa);
    }
    theme_editor.list(&custom);
    for (custom.items) |path| {
        const base = gpa.dupeSentinel(u8, std.fs.path.basename(path), 0) catch continue;
        defer gpa.free(base);
        const value = std.fmt.allocPrintSentinel(ctx.al(), "file:{s}", .{path}, 0) catch continue;
        values.append(ctx.al(), value) catch continue;
        list.append(base.ptr);
    }
}

const Slot = struct { ctx: *Ctx, field: *[]u8 };

/// A drop-down of every theme, for the light or the dark appearance.
fn slotRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, field: *[]u8) void {
    const list = gtk.StringList.new(null);
    themeNames(ctx, list);
    const row = adw.ComboRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    row.setModel(list.as(gio.ListModel));
    list.as(gobject.Object).unref();
    for (ctx.theme_values.items, 0..) |v, i| if (std.mem.eql(u8, v, field.*)) row.setSelected(@intCast(i));
    g.add(row.as(gtk.Widget));
    const slot = ctx.keep(Slot{ .ctx = ctx, .field = field }) orelse return;
    const H = struct {
        fn picked(r: *adw.ComboRow, _: *gobject.ParamSpec, sl: *Slot) callconv(.c) void {
            const values = sl.ctx.theme_values.items;
            const i = r.getSelected();
            if (i >= values.len or std.mem.eql(u8, values[i], sl.field.*)) return;
            settings.setString(sl.field, values[i]);
            sl.ctx.app.themeChanged();
        }
    };
    _ = gobject.Object.signals.notify.connect(row, *Slot, &H.picked, slot, .{ .detail = "selected" });
}

fn customThemes(ctx: *Ctx, p: *adw.PreferencesPage) void {
    const g = group(p, "Custom Themes", "Your own themes, saved in ~/.config/renux/themes");
    const new_button = rowButton("New Theme");
    g.setHeaderSuffix(new_button.as(gtk.Widget));
    _ = gtk.Button.signals.clicked.connect(new_button, *Ctx, &newTheme, ctx, .{});
    var custom: std.ArrayList([:0]u8) = .empty;
    defer {
        for (custom.items) |c| gpa.free(c);
        custom.deinit(gpa);
    }
    theme_editor.list(&custom);
    if (custom.items.len == 0) {
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle("No custom themes");
        g.add(row.as(gtk.Widget));
    }
    for (custom.items) |path| {
        const row = adw.ActionRow.new();
        setRowText(row, std.fs.path.basename(path), null);
        const edit = rowButton("Edit");
        const del = gtk.Button.newFromIconName("user-trash-symbolic");
        del.as(gtk.Widget).addCssClass("flat");
        del.as(gtk.Widget).setValign(.center);
        del.as(gtk.Widget).setTooltipText("Delete this theme");
        const use = rowButton("Use");
        row.addSuffix(use.as(gtk.Widget));
        row.addSuffix(edit.as(gtk.Widget));
        row.addSuffix(del.as(gtk.Widget));
        g.add(row.as(gtk.Widget));
        const ct = ctx.keep(CustomTheme{
            .ctx = ctx,
            .path = ctx.al().dupeSentinel(u8, path, 0) catch continue,
            .value = std.fmt.allocPrintSentinel(ctx.al(), "file:{s}", .{path}, 0) catch continue,
        }) orelse continue;
        _ = gtk.Button.signals.clicked.connect(edit, *CustomTheme, &editTheme, ct, .{});
        _ = gtk.Button.signals.clicked.connect(del, *CustomTheme, &deleteTheme, ct, .{});
        _ = gtk.Button.signals.clicked.connect(use, *CustomTheme, &useTheme, ct, .{});
    }
}

const CustomTheme = struct { ctx: *Ctx, path: [:0]u8, value: [:0]u8 };

/// Points every theme setting that names `old` (the main theme, the light one, the dark one) at
/// `new` instead. Returns whether any did.
pub fn retarget(old: []const u8, new: []const u8) bool {
    var any = false;
    const st = &settings.current;
    for ([_]*[]u8{ &st.theme, &st.theme_light, &st.theme_dark }) |slot| {
        if (!std.mem.eql(u8, slot.*, old)) continue;
        settings.setString(slot, new);
        any = true;
    }
    return any;
}

/// The theme editor saved a theme. A new one becomes the theme in use; one that was renamed
/// keeps every place it was picked for.
fn themeSaved(data: *anyopaque, old: ?[]const u8, path: []const u8) void {
    const app: *App = @ptrCast(@alignCast(data));
    const value = std.fmt.allocPrint(gpa, "file:{s}", .{path}) catch return;
    defer gpa.free(value);
    if (old) |o| {
        if (!std.mem.eql(u8, o, path)) if (std.fmt.allocPrint(gpa, "file:{s}", .{o})) |was| {
            defer gpa.free(was);
            _ = retarget(was, value);
        } else |_| {};
    } else settings.setString(&settings.current.theme, value);
    // Also for a theme edited in place: its colors changed under the same name.
    app.themeChanged();
    if (open_ctx) |ctx| rebuildThemes(ctx);
}

fn newTheme(_: *gtk.Button, ctx: *Ctx) callconv(.c) void {
    const start = themes.active orelse (if (ctx.app.server) |s| s.host_colors else null) orelse @import("../rex/stream.zig").Colors{};
    theme_editor.open(ctx.dialog.as(gtk.Widget), null, start, ctx.app, &themeSaved);
}

fn editTheme(_: *gtk.Button, ct: *CustomTheme) callconv(.c) void {
    theme_editor.open(ct.ctx.dialog.as(gtk.Widget), ct.path, .{}, ct.ctx.app, &themeSaved);
}

fn useTheme(_: *gtk.Button, ct: *CustomTheme) callconv(.c) void {
    settings.setString(&settings.current.theme, ct.value);
    ct.ctx.app.themeChanged();
    rebuildThemes(ct.ctx);
}

fn deleteTheme(_: *gtk.Button, ct: *CustomTheme) callconv(.c) void {
    _ = glib.unlink(ct.path.ptr);
    // Wherever it was picked goes back to following the host.
    if (retarget(ct.value, "")) ct.ctx.app.themeChanged();
    rebuildThemes(ct.ctx);
}

/// Builds the Themes page again, after a custom theme comes or goes.
fn rebuildThemes(ctx: *Ctx) void {
    const stack = ctx.stack;
    const index = comptime for (sections, 0..) |sec, i| {
        if (std.mem.eql(u8, sec.title, "Themes")) break i;
    } else unreachable;
    // Not built yet: it will be made from the settings as they are when it's first shown.
    if (!ctx.built[index]) return;
    const shown = if (stack.getVisibleChildName()) |n| std.mem.eql(u8, std.mem.span(n), "Themes") else false;
    if (stack.getChildByName("Themes")) |old| stack.remove(old);
    _ = stack.addNamed(themesPage(ctx), "Themes");
    if (shown) stack.setVisibleChildName("Themes");
}

fn showPairing(_: *gtk.Button, ctx: *Ctx) callconv(.c) void {
    if (ctx.app.current) |h| _ = App.perform(h, "client.pair_device", null, null);
}

fn themesPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    ctx.theme_checks.clearRetainingCapacity();
    const look = group(p, "Appearance", null);
    switchRow(ctx, look, "Separate light and dark themes", "Follow the system's appearance with a theme for each", &settings.current.theme_follow_system, App.themeChanged);
    slotRow(ctx, look, "Light theme", &settings.current.theme_light);
    slotRow(ctx, look, "Dark theme", &settings.current.theme_dark);
    const g = group(p, "Terminal Theme", "Renux follows each host's theme unless you pick one here. A theme picked here only colors Renux; your Rex server keeps its own.");
    themeRow(ctx, g, "Follow host", "", null);
    for (&themes.builtins) |*t| themeRow(ctx, g, t.name, t.name, t);
    if (std.mem.startsWith(u8, settings.current.theme, "file:")) {
        const path = settings.current.theme["file:".len..];
        themeRow(ctx, g, std.fs.path.basename(path), settings.current.theme, null);
    }
    customThemes(ctx, p);
    const imp = group(p, "Import Theme", null);
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle("Import a Ghostty theme file");
    row.setSubtitle("It replaces the colors here and in every pane");
    const b = gtk.Button.newWithLabel("Import");
    b.as(gtk.Widget).setValign(.center);
    _ = gtk.Button.signals.clicked.connect(b, *Ctx, &importClicked, ctx, .{});
    row.addSuffix(b.as(gtk.Widget));
    imp.add(row.as(gtk.Widget));
    return p.as(gtk.Widget);
}

fn themeRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: []const u8, value: []const u8, t: ?*const themes.Theme) void {
    const row = adw.ActionRow.new();
    setRowText(row, title, null);
    if (t) |theme| {
        const swatch = gtk.DrawingArea.new();
        swatch.setContentWidth(120);
        swatch.setContentHeight(22);
        swatch.setDrawFunc(&drawSwatch, @constCast(theme), null);
        swatch.as(gtk.Widget).setValign(.center);
        row.addPrefix(swatch.as(gtk.Widget));
    }
    const check = gtk.Image.newFromIconName("object-select-symbolic");
    check.as(gtk.Widget).setVisible(@intFromBool(std.mem.eql(u8, settings.current.theme, value)));
    row.addSuffix(check.as(gtk.Widget));
    row.as(gtk.ListBoxRow).setActivatable(1);
    g.add(row.as(gtk.Widget));
    const pick = ctx.keep(ThemePick{ .ctx = ctx, .value = ctx.al().dupeSentinel(u8, value, 0) catch return, .check = check.as(gtk.Widget) }) orelse return;
    ctx.theme_checks.append(ctx.al(), pick) catch {};
    _ = adw.ActionRow.signals.activated.connect(row, *ThemePick, &themePicked, pick, .{});
}

fn themePicked(_: *adw.ActionRow, pick: *ThemePick) callconv(.c) void {
    settings.setString(&settings.current.theme, pick.value);
    for (pick.ctx.theme_checks.items) |c| c.check.setVisible(@intFromBool(c == pick));
    pick.ctx.app.themeChanged();
    redrawArt(pick.ctx);
}

fn drawSwatch(_: *gtk.DrawingArea, cr: *cairo.Context, w: c_int, h: c_int, data: ?*anyopaque) callconv(.c) void {
    const t: *const themes.Theme = @ptrCast(@alignCast(data.?));
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    setRgb(cr, t.bg);
    cr.rectangle(0, 0, fw, fh);
    cr.fill();
    for (0..8) |i| {
        setRgb(cr, t.ansi[i + 1 - @intFromBool(i == 7) * 1]);
        cr.arc(10 + @as(f64, @floatFromInt(i)) * 13, fh / 2, 4.5, 0, 2 * std.math.pi);
        cr.fill();
    }
}

fn setRgb(cr: *cairo.Context, c: u32) void {
    const rgb = Rgb.of(c);
    cr.setSourceRgb(rgb.r, rgb.g, rgb.b);
}

fn importClicked(_: *gtk.Button, ctx: *Ctx) callconv(.c) void {
    const fd = gtk.FileDialog.new();
    fd.setTitle("Import a Ghostty theme");
    // Answered with the app, not this window, which may have closed by then.
    fd.open(ctx.app.window.as(gtk.Window), null, &imported, ctx.app);
    fd.as(gobject.Object).unref();
}

fn imported(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const fd: *gtk.FileDialog = @ptrCast(source orelse return);
    const f = fd.openFinish(result, null) orelse return;
    defer f.as(gobject.Object).unref();
    const path = f.getPath() orelse return;
    defer glib.free(path);
    const p = std.mem.span(path);
    if (themes.loadGhostty(p) == null) {
        app.toasts.addToast(adw.Toast.new("That file doesn't look like a Ghostty theme"));
        return;
    }
    const value = std.fmt.allocPrint(gpa, "file:{s}", .{p}) catch return;
    defer gpa.free(value);
    settings.setString(&settings.current.theme, value);
    app.themeChanged();
    // The page again, so the imported file has its own row with the check mark.
    if (open_ctx) |ctx| rebuildThemes(ctx);
}

// Terminal.

fn terminalPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const g = group(p, "Typography", null);
    sampleRow(ctx, g, .typography);
    fontRows(ctx, g);
    numberRow(ctx, g, "Line height", "Row height as a multiple of the font's own", &settings.current.line_height, 0.8, 2, 0.05, 2, App.fontChanged);
    numberRow(ctx, g, "Letter spacing", "Extra pixels between characters", &settings.current.letter_spacing, -2, 6, 0.5, 1, App.fontChanged);
    switchRow(ctx, g, "Font ligatures", "Join character pairs such as => when the font has them", &settings.current.ligatures, App.terminalChanged);
    switchRow(ctx, g, "Font smoothing", "Off draws glyphs without antialiasing, for pixel fonts", &settings.current.font_smoothing, App.terminalChanged);
    segments(ctx, g, "Bold and italic", settings.BoldItalic, &settings.current.bold_italic, &.{ "Own Faces", "Regular" }, App.terminalChanged);

    const padding = group(p, "Padding", null);
    numberRow(ctx, padding, "Horizontal padding", "Points left and right of the text", &settings.current.pad_x, 0, 40, 1, 0, App.terminalChanged);
    numberRow(ctx, padding, "Vertical padding", "Points above and below the text", &settings.current.pad_y, 0, 40, 1, 0, App.terminalChanged);
    segments(ctx, padding, "Padding color", settings.PaddingColor, &settings.current.padding_color, &.{ "Terminal", "Theme" }, App.terminalChanged);

    const look = group(p, "Transparency", "Below 100%, the desktop shows through. On Linux, KDE and Hyprland blur it; GNOME doesn't.");
    percentRow(ctx, look, "Window", "Behind the panes and the sidebar", &settings.current.window_opacity);
    percentRow(ctx, look, "Terminals", "Floating panes stay solid", &settings.current.terminal_opacity);
    switchRow(ctx, look, "Blur", "Frost what shows through", &settings.current.blur, App.applyLook);

    const c = group(p, "Cursor", null);
    sampleRow(ctx, c, .cursor);
    segments(ctx, c, "Cursor style", settings.CursorStyle, &settings.current.cursor_style, &.{ "Program", "Block", "Bar", "Underline" }, App.redrawAll);
    numberRow(ctx, c, "Bar width", "In pixels, for the bar and underline cursors. The cursor takes the theme's accent color", &settings.current.cursor_width, 1, 6, 0.5, 1, App.redrawAll);
    switchRow(ctx, c, "Blink", "In the pane with the keyboard", &settings.current.cursor_blink, App.redrawAll);
    numberRow(ctx, c, "Blink interval", "Milliseconds between blinks", &settings.current.cursor_blink_ms, 200, 2000, 50, 0, App.terminalChanged);
    colorPicker(ctx, c, "Cursor text color", "The character under a block cursor", &settings.current.cursor_text_color, "Default", App.redrawAllPub);

    const sel = group(p, "Selection", null);
    sampleRow(ctx, sel, .selection);
    colorPicker(ctx, sel, "Background", "Selected text swaps its colors unless one is picked", &settings.current.selection_bg, "Theme", App.redrawAllPub);
    colorPicker(ctx, sel, "Foreground", null, &settings.current.selection_fg, "Theme", App.redrawAllPub);
    const colors = group(p, "Colors and Bell", null);
    switchRow(ctx, colors, "Improve text contrast", "Adjust text that would be hard to read against its background", &settings.current.improve_contrast, App.redrawAll);
    switchRow(ctx, colors, "Extended theme palette", "Make colors 16 to 255 from the theme's own colors", &settings.current.extended_palette, App.terminalChanged);
    switchRow(ctx, colors, "Flash on bell", "Briefly light up a pane when its program rings the bell", &settings.current.visual_bell, null);
    const paste = group(p, "Copy and Paste", null);
    switchRow(ctx, paste, "Animation on copy", "A Copied badge on the pane", &settings.current.copy_animation, null);
    switchRow(ctx, paste, "Copy on select", "Selected text goes straight to the clipboard. Programs that handle the mouse themselves, such as Claude Code, copy their own selections", &settings.current.copy_on_select, null);
    switchRow(ctx, paste, "Ask before pasting several lines", "Unless the program knows it's a paste, each line could run as a command", &settings.current.paste_warning, null);
    return p.as(gtk.Widget);
}

// The font is picked right on the page: a monospace family, searchable, and a size.

fn fontRows(ctx: *Ctx, g: *adw.PreferencesGroup) void {
    const current_z = gpa.dupeSentinel(u8, settings.current.font, 0) catch return;
    defer gpa.free(current_z);
    const current = pango.FontDescription.fromString(current_z.ptr);
    defer current.free();
    const current_family = if (current.getFamily()) |f| std.mem.span(f) else "Monospace";
    const current_size: f64 = @as(f64, @floatFromInt(current.getSize())) / pango.SCALE;

    // Every monospace family this computer has, in order.
    const font_names = &ctx.font_names;
    font_names.clearRetainingCapacity();
    var families: [*]*pango.FontFamily = undefined;
    var count: c_int = 0;
    pangocairo.FontMap.getDefault().listFamilies(&families, &count);
    for (families[0..@intCast(count)]) |f| if (f.isMonospace() != 0 or looksMonospace(std.mem.span(f.getName()))) {
        font_names.append(ctx.al(), ctx.al().dupeSentinel(u8, std.mem.span(f.getName()), 0) catch continue) catch {};
    };
    glib.free(@ptrCast(families));
    std.mem.sort([:0]u8, font_names.items, {}, struct {
        fn less(_: void, a: [:0]u8, b: [:0]u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.less);
    const list = gtk.StringList.new(null);
    var selected: c_uint = 0;
    var found = false;
    for (font_names.items, 0..) |n, i| {
        list.append(n.ptr);
        if (std.ascii.eqlIgnoreCase(n, current_family)) {
            selected = @intCast(i);
            found = true;
        }
    }
    if (!found) {
        // Keep a family that isn't listed, such as the generic "Monospace".
        const z = ctx.al().dupeSentinel(u8, current_family, 0) catch return;
        font_names.append(ctx.al(), z) catch return;
        list.append(z.ptr);
        selected = @intCast(font_names.items.len - 1);
    }

    const family = adw.ComboRow.new();
    family.as(adw.PreferencesRow).setTitle("Font");
    family.setModel(list.as(gio.ListModel));
    list.as(gobject.Object).unref();
    family.setExpression(gtk.PropertyExpression.new(gtk.StringObject.getGObjectType(), null, "string").as(gtk.Expression));
    family.setEnableSearch(1);
    family.setSelected(selected);
    g.add(family.as(gtk.Widget));
    ctx.font_family = family;

    const size = adw.SpinRow.newWithRange(6, 40, 1);
    size.as(adw.PreferencesRow).setTitle("Size");
    size.setValue(current_size);
    g.add(size.as(gtk.Widget));
    ctx.font_size = size;

    const preview = gtk.Label.new("The quick brown fox jumps over the lazy dog  0O 1lI {}[] => !=");
    preview.setXalign(0);
    preview.setEllipsize(.end);
    preview.as(gtk.Widget).addCssClass("font-preview");
    const preview_row = adw.PreferencesRow.new();
    preview_row.as(gtk.ListBoxRow).setActivatable(0);
    preview_row.as(gtk.ListBoxRow).setChild(preview.as(gtk.Widget));
    g.add(preview_row.as(gtk.Widget));
    ctx.font_preview = preview;
    // The sample at the top of the group shows the font now; this line is kept out of sight.
    if (preview.as(gtk.Widget).getAncestor(gtk.ListBoxRow.getGObjectType())) |row| row.setVisible(0);
    showPreview(ctx);

    _ = gobject.Object.signals.notify.connect(family, *Ctx, &familyChanged, ctx, .{ .detail = "selected" });
    _ = gobject.Object.signals.notify.connect(size, *Ctx, &sizeChanged, ctx, .{ .detail = "value" });
}

/// Some fixed-width families, Nerd Fonts among them, don't say they're monospace; their names do.
fn looksMonospace(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "Symbols Nerd") or std.mem.indexOf(u8, name, "Propo") != null) return false;
    for ([_][]const u8{ "Mono", "Nerd Font", "Code", "Term", "Console", "Courier", "Fixed" }) |hint| {
        if (std.mem.indexOf(u8, name, hint) != null) return true;
    }
    return false;
}

fn chosenFont(ctx: *Ctx, buf: []u8) ?[:0]const u8 {
    const family = ctx.font_family orelse return null;
    const size = ctx.font_size orelse return null;
    const i = family.getSelected();
    if (i >= ctx.font_names.items.len) return null;
    return std.fmt.bufPrintSentinel(buf, "{s} {d}", .{ ctx.font_names.items[i], @round(size.getValue()) }, 0) catch null;
}

fn showPreview(ctx: *Ctx) void {
    const label = ctx.font_preview orelse return;
    var buf: [256]u8 = undefined;
    const font = chosenFont(ctx, &buf) orelse return;
    const escaped = glib.markupEscapeText(font.ptr, @intCast(font.len));
    defer glib.free(escaped);
    var markup: [512]u8 = undefined;
    const m = std.fmt.bufPrintSentinel(&markup, "<span font=\"{s}\">The quick brown fox jumps over the lazy dog  0O 1lI {{}}[] =&gt; !=</span>", .{std.mem.span(escaped)}, 0) catch return;
    label.setMarkup(m.ptr);
}

fn familyChanged(_: *adw.ComboRow, _: *gobject.ParamSpec, ctx: *Ctx) callconv(.c) void {
    fontChanged(ctx);
}

fn sizeChanged(_: *adw.SpinRow, _: *gobject.ParamSpec, ctx: *Ctx) callconv(.c) void {
    fontChanged(ctx);
}

fn fontChanged(ctx: *Ctx) void {
    var buf: [256]u8 = undefined;
    const font = chosenFont(ctx, &buf) orelse return;
    if (std.mem.eql(u8, font, settings.current.font)) return;
    settings.setString(&settings.current.font, font);
    showPreview(ctx);
    ctx.app.fontChanged();
    redrawArt(ctx);
}

// Shortcuts.

fn shortcutsPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const hint_group = group(p, "Key Hints", null);
    switchRow(ctx, hint_group, "Show key sequence hints", "After a prefix such as ctrl+a, list the keys that can follow", &settings.current.key_hints, null);
    shortcuts.build(ctx.app, p, &ctx.shortcuts_page);
    return p.as(gtk.Widget);
}

// Notifications.

fn notificationsPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const st = &settings.current;
    const g = group(p, "Program Activity", "How status from programs and agents is handled");
    switchRow(ctx, g, "Show system notifications", "Only while you're looking elsewhere", &st.alerts, null);
    switchRow(ctx, g, "Play sounds", null, &st.sound, null);
    const which = group(p, "Notify When", null);
    statusSwitch(ctx, which, .blocked, "Blocked", "A program needs your permission, an answer or a password", &st.alert_blocked);
    statusSwitch(ctx, which, .failed, "Error", "A program failed", &st.alert_error);
    statusSwitch(ctx, which, .done, "Done", "A program finished", &st.alert_done);
    const sys = group(p, "Terminal Notifications", null);
    switchRow(ctx, sys, "Notifications from programs", "Programs can send notifications with OSC 9 or OSC 777", &st.terminal_notifications, null);
    return p.as(gtk.Widget);
}

// Remote hosts.

const HostRow = struct { ctx: *Ctx, index: usize };

fn hostsPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const g = group(p, "Remote Hosts", "Every host's sessions show in the sidebar, grouped by host.");
    for (settings.current.hosts.items, 0..) |h, i| {
        const row = adw.ActionRow.new();
        setRowText(row, h.label, h.url);
        const remove = gtk.Button.newWithLabel("Remove");
        remove.as(gtk.Widget).setValign(.center);
        remove.as(gtk.Widget).addCssClass("destructive-action");
        row.addSuffix(remove.as(gtk.Widget));
        g.add(row.as(gtk.Widget));
        const hr = ctx.keep(HostRow{ .ctx = ctx, .index = i }) orelse continue;
        _ = gtk.Button.signals.clicked.connect(remove, *HostRow, &removeHost, hr, .{});
    }
    if (settings.current.hosts.items.len == 0) {
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle("No saved hosts");
        row.setSubtitle("Add a Rex HTTP or HTTPS address to use its sessions here");
        g.add(row.as(gtk.Widget));
    }
    const buttons = gtk.Box.new(.horizontal, 8);
    buttons.as(gtk.Widget).setHalign(.end);
    buttons.as(gtk.Widget).setMarginTop(12);
    const import_button = gtk.Button.newWithLabel("Import From Server");
    import_button.as(gtk.Widget).setTooltipText("Add the hosts the server you're looking at already knows");
    _ = gtk.Button.signals.clicked.connect(import_button, *Ctx, &importHosts, ctx, .{});
    buttons.append(import_button.as(gtk.Widget));
    const add = gtk.Button.newWithLabel("Add Remote Host…");
    add.as(gtk.Actionable).setActionName("app.add-host");
    buttons.append(add.as(gtk.Widget));
    g.add(buttons.as(gtk.Widget));
    return p.as(gtk.Widget);
}

fn removeHost(_: *gtk.Button, hr: *HostRow) callconv(.c) void {
    const a = hr.ctx.app;
    const saved = settings.current.hosts.items;
    if (hr.index >= saved.len) return;
    const url = saved[hr.index].url;
    for (a.hosts.items) |h| if (std.mem.eql(u8, h.server.url, url)) {
        a.removeHost(h);
        break;
    };
    settings.removeHost(hr.index);
    _ = hr.ctx.dialog.close();
}

fn importHosts(_: *gtk.Button, ctx: *Ctx) callconv(.c) void {
    if (ctx.app.server) |s| s.fetchHosts();
}

test "a renamed or deleted theme is followed in every place it was picked" {
    const st = &settings.current;
    const saved = .{ st.theme, st.theme_light, st.theme_dark };
    defer {
        st.theme = saved[0];
        st.theme_light = saved[1];
        st.theme_dark = saved[2];
    }
    st.theme = try gpa.dupe(u8, "Nord");
    st.theme_light = try gpa.dupe(u8, "file:/themes/Mine");
    st.theme_dark = try gpa.dupe(u8, "file:/themes/Mine");
    defer for ([_][]u8{ st.theme, st.theme_light, st.theme_dark }) |t| gpa.free(t);
    try std.testing.expect(retarget("file:/themes/Mine", "file:/themes/Yours"));
    try std.testing.expectEqualStrings("Nord", st.theme);
    try std.testing.expectEqualStrings("file:/themes/Yours", st.theme_light);
    try std.testing.expectEqualStrings("file:/themes/Yours", st.theme_dark);
    try std.testing.expect(!retarget("file:/themes/Mine", ""));
    try std.testing.expect(retarget("file:/themes/Yours", ""));
    try std.testing.expectEqualStrings("", st.theme_dark);
}
