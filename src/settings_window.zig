//! The settings window, laid out like Rex's: sections in a sidebar, their settings on the right.
//! Everything here changes only Compy; key bindings stay in the person's Rex config.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const theme_editor = @import("theme_editor.zig");
const gdk = @import("gdk");
const cairo = @import("cairo");
const adw = @import("adw");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const settings = @import("settings.zig");
const themes = @import("themes.zig");
const icons = @import("icons.zig");
const App = @import("app.zig").App;

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

const Ctx = struct {
    app: *App,
    dialog: *adw.Dialog,
    stack: *gtk.Stack,
    list: *gtk.ListBox,
};

pub fn open(app: *App) void {
    const ctx = gpa.create(Ctx) catch return;
    ctx.* = .{ .app = app, .dialog = adw.Dialog.new(), .stack = gtk.Stack.new(), .list = gtk.ListBox.new() };
    const d = ctx.dialog;
    d.setTitle("Settings");
    d.setContentWidth(900);
    d.setContentHeight(640);
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
        _ = ctx.stack.addNamed(sec.build(ctx), sec.title.ptr);
    }
    ctx.stack.setTransitionType(.crossfade);

    const side = adw.ToolbarView.new();
    const side_header = adw.HeaderBar.new();
    side_header.setShowEndTitleButtons(0);
    side.addTopBar(side_header.as(gtk.Widget));
    side.setContent(ctx.list.as(gtk.Widget));
    const content = adw.ToolbarView.new();
    content.addTopBar(adw.HeaderBar.new().as(gtk.Widget));
    content.setContent(ctx.stack.as(gtk.Widget));
    const split = adw.NavigationSplitView.new();
    split.setSidebar(adw.NavigationPage.new(side.as(gtk.Widget), "Settings"));
    split.setContent(adw.NavigationPage.new(content.as(gtk.Widget), "Settings"));
    split.setMinSidebarWidth(200);
    d.setChild(split.as(gtk.Widget));
    // Development: COMPY_SETTINGS_PAGE opens on a page by its number.
    const first: c_int = if (std.c.getenv("COMPY_SETTINGS_PAGE")) |n| std.fmt.parseInt(c_int, std.mem.span(n), 10) catch 0 else 0;
    ctx.list.selectRow(ctx.list.getRowAtIndex(first));
    d.present(app.window.as(gtk.Widget));
}

fn closed(_: *adw.Dialog, ctx: *Ctx) callconv(.c) void {
    gpa.destroy(ctx);
}

fn picked(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, ctx: *Ctx) callconv(.c) void {
    const r = row orelse return;
    const i: usize = @intCast(r.getIndex());
    if (i < sections.len) ctx.stack.setVisibleChildName(sections[i].title.ptr);
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

const Toggle = struct { ctx: *Ctx, field: *bool, after: ?*const fn (*App) void };

/// A switch bound to one of the settings, with an optional follow-up when it changes.
fn switchRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *bool, after: ?*const fn (*App) void) void {
    const row = adw.SwitchRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |s| row.as(adw.ActionRow).setSubtitle(s.ptr);
    row.setActive(@intFromBool(field.*));
    const t = gpa.create(Toggle) catch return;
    t.* = .{ .ctx = ctx, .field = field, .after = after };
    _ = gobject.Object.signals.notify.connect(row, *Toggle, &toggled, t, .{ .detail = "active" });
    g.add(row.as(gtk.Widget));
}

fn toggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, t: *Toggle) callconv(.c) void {
    t.field.* = row.getActive() != 0;
    settings.save();
    if (t.after) |f| f(t.ctx.app);
}

const Number = struct { ctx: *Ctx, field: *f64, after: *const fn (*App) void };

/// A number spinner bound to one of the settings, applied as it changes.
fn numberRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *f64, min: f64, max: f64, step: f64, digits: c_uint, after: *const fn (*App) void) void {
    const row = adw.SpinRow.newWithRange(min, max, step);
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |s| row.as(adw.ActionRow).setSubtitle(s.ptr);
    row.setDigits(digits);
    row.setValue(field.*);
    const n = gpa.create(Number) catch return;
    n.* = .{ .ctx = ctx, .field = field, .after = after };
    _ = gobject.Object.signals.notify.connect(row, *Number, &numberChanged, n, .{ .detail = "value" });
    g.add(row.as(gtk.Widget));
}

fn numberChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, n: *Number) callconv(.c) void {
    const v = row.getValue();
    if (v == n.field.*) return;
    n.field.* = v;
    settings.save();
    n.after(n.ctx.app);
}

const Percent = struct { ctx: *Ctx, field: *f64 };

/// A 20 to 100 percent spinner for an opacity, stored as 0.2 to 1.
fn percentRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: [:0]const u8, field: *f64) void {
    rangePercentRow(ctx, g, title, subtitle, field, 20, 100);
}

fn rangePercentRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *f64, min: f64, max: f64) void {
    const row = adw.SpinRow.newWithRange(min, max, 5);
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |sub| row.as(adw.ActionRow).setSubtitle(sub.ptr);
    row.setValue(@round(field.* * 100));
    const n = gpa.create(Percent) catch return;
    n.* = .{ .ctx = ctx, .field = field };
    _ = gobject.Object.signals.notify.connect(row, *Percent, &percentChanged, n, .{ .detail = "value" });
    g.add(row.as(gtk.Widget));
}

fn percentChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, n: *Percent) callconv(.c) void {
    n.field.* = row.getValue() / 100;
    settings.save();
    n.ctx.app.applyLook();
}

const ColorCtx = struct { ctx: *Ctx, field: *u32, after: *const fn (*App) void };

/// A color setting: a picked color, or none (0) for the default that `reset` names.
fn colorPicker(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, subtitle: ?[:0]const u8, field: *u32, reset: [:0]const u8, after: *const fn (*App) void) void {
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    if (subtitle) |sub| row.setSubtitle(sub.ptr);
    const button = gtk.ColorDialogButton.new(gtk.ColorDialog.new());
    button.as(gtk.Widget).setValign(.center);
    const c = field.*;
    if (c != 0) {
        const rgba: gdk.RGBA = .{ .f_red = @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255, .f_green = @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255, .f_blue = @as(f32, @floatFromInt(c & 0xff)) / 255, .f_alpha = 1 };
        button.setRgba(&rgba);
    }
    const default = gtk.Button.newWithLabel(reset.ptr);
    default.as(gtk.Widget).addCssClass("flat");
    default.as(gtk.Widget).setValign(.center);
    row.addSuffix(default.as(gtk.Widget));
    row.addSuffix(button.as(gtk.Widget));
    const cc = gpa.create(ColorCtx) catch return;
    cc.* = .{ .ctx = ctx, .field = field, .after = after };
    const H = struct {
        fn picked(b: *gtk.ColorDialogButton, _: *gobject.ParamSpec, x: *ColorCtx) callconv(.c) void {
            const v = b.getRgba();
            const byte = struct {
                fn f(t: f32) u32 {
                    return @intFromFloat(@round(std.math.clamp(t, 0, 1) * 255));
                }
            }.f;
            x.field.* = (byte(v.f_red) << 16) | (byte(v.f_green) << 8) | byte(v.f_blue);
            // Pure black is kept as the next shade up, since 0 means the default.
            if (x.field.* == 0) x.field.* = 1;
            settings.save();
            x.after(x.ctx.app);
        }
        fn cleared(_: *gtk.Button, x: *ColorCtx) callconv(.c) void {
            x.field.* = 0;
            settings.save();
            x.after(x.ctx.app);
        }
    };
    _ = gobject.Object.signals.notify.connect(button, *ColorCtx, &H.picked, cc, .{ .detail = "rgba" });
    _ = gtk.Button.signals.clicked.connect(default, *ColorCtx, &H.cleared, cc, .{});
    g.add(row.as(gtk.Widget));
}

/// Segmented buttons for an enum setting, like Rex's Comfortable / Compact.
fn segments(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, comptime E: type, field: *E, labels: []const [:0]const u8, after: *const fn (*App) void) void {
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    const box = gtk.Box.new(.horizontal, 0);
    box.as(gtk.Widget).addCssClass("linked");
    box.as(gtk.Widget).setValign(.center);
    var first: ?*gtk.ToggleButton = null;
    inline for (comptime std.enums.values(E), 0..) |value, i| {
        const b = gtk.ToggleButton.newWithLabel(labels[i].ptr);
        if (first) |fb| b.setGroup(fb) else first = b;
        b.setActive(@intFromBool(field.* == value));
        const Seg = struct {
            fn changed(btn: *gtk.ToggleButton, s: *SegCtx(E)) callconv(.c) void {
                if (btn.getActive() == 0) return;
                s.field.* = value;
                settings.save();
                s.after(s.ctx.app);
            }
        };
        const sc = gpa.create(SegCtx(E)) catch return;
        sc.* = .{ .ctx = ctx, .field = field, .after = after };
        _ = gtk.ToggleButton.signals.toggled.connect(b, *SegCtx(E), &Seg.changed, sc, .{});
        box.append(b.as(gtk.Widget));
    }
    row.addSuffix(box.as(gtk.Widget));
    g.add(row.as(gtk.Widget));
}

fn SegCtx(comptime E: type) type {
    return struct { ctx: *Ctx, field: *E, after: *const fn (*App) void };
}

fn suffixLabel(row: *adw.ActionRow, text: []const u8) void {
    const z = gpa.dupeSentinel(u8, text, 0) catch return;
    defer gpa.free(z);
    const l = gtk.Label.new(z.ptr);
    l.as(gtk.Widget).addCssClass("dim-label");
    row.addSuffix(l.as(gtk.Widget));
}

fn nothing(_: *App) void {}

// Server.

fn serverPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const a = ctx.app;
    const g = group(p, "Rex Server", "The server Compy is showing now. Add more under Remote Hosts.");
    const status = adw.ActionRow.new();
    if (a.server) |s| {
        var buf: [256]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&buf, "{s}", .{if (a.current) |h| h.label else "Rex"}, 0) catch "Rex";
        status.as(adw.PreferencesRow).setTitle(title.ptr);
        var sbuf: [320]u8 = undefined;
        const sub = switch (s.state) {
            .online => std.fmt.bufPrintSentinel(&sbuf, "Connected{s}{s}", .{ if (s.rex_version != null) " · Rex " else "", s.rex_version orelse "" }, 0),
            .connecting => std.fmt.bufPrintSentinel(&sbuf, "Connecting…", .{}, 0),
            .offline => std.fmt.bufPrintSentinel(&sbuf, "Offline: {s}", .{s.reason.items}, 0),
        } catch "";
        status.setSubtitle(sub.ptr);
        const retry = gtk.Button.newWithLabel("Reconnect");
        retry.as(gtk.Widget).setValign(.center);
        retry.as(gtk.Actionable).setActionName("app.retry");
        status.addSuffix(retry.as(gtk.Widget));
        g.add(status.as(gtk.Widget));
        const addr = adw.ActionRow.new();
        addr.as(adw.PreferencesRow).setTitle("Address");
        const z = gpa.dupeSentinel(u8, s.url, 0) catch "";
        addr.setSubtitle(z.ptr);
        addr.setSubtitleSelectable(1);
        g.add(addr.as(gtk.Widget));
    } else {
        status.as(adw.PreferencesRow).setTitle("Not connected");
        g.add(status.as(gtk.Widget));
    }

    // This computer's Tailscale, which Rex servers often use to let it in.
    const tsg = group(p, "Tailscale", "Read from this computer. Rex's own Tailscale settings live in the Rex app on the server's machine.");
    var ts = @import("tailscale.zig").read();
    defer ts.deinit();
    const ts_row = adw.ActionRow.new();
    if (ts.running) {
        var tb: [256]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&tb, "Signed in{s}{s}", .{ if (ts.login != null) " as " else "", ts.login orelse "" }, 0) catch "Signed in";
        ts_row.as(adw.PreferencesRow).setTitle(title.ptr);
        var sb: [256]u8 = undefined;
        const sub = std.fmt.bufPrintSentinel(&sb, "{s}{s}{d} Rex host{s} on the tailnet", .{ ts.tailnet orelse "", if (ts.tailnet != null) " · " else "", ts.rex_hosts.items.len, if (ts.rex_hosts.items.len == 1) "" else "s" }, 0) catch "";
        ts_row.setSubtitle(sub.ptr);
    } else {
        ts_row.as(adw.PreferencesRow).setTitle("Not on Tailscale");
        const why = gpa.dupeSentinel(u8, ts.problem orelse "Tailscale isn't connected", 0) catch "";
        ts_row.setSubtitle(why.ptr);
    }
    tsg.add(ts_row.as(gtk.Widget));

    const info = group(p, "Client Info", "How this computer appears in Rex's list of clients. It applies on the next connection.");
    const label = adw.EntryRow.new();
    label.as(adw.PreferencesRow).setTitle("Label");
    const current = gpa.dupeSentinel(u8, if (settings.current.client_label.len > 0) settings.current.client_label else std.mem.span(glib.getHostName()), 0) catch "";
    label.as(gtk.Editable).setText(current.ptr);
    label.setShowApplyButton(1);
    _ = adw.EntryRow.signals.apply.connect(label, *Ctx, &labelApplied, ctx, .{});
    info.add(label.as(gtk.Widget));
    return p.as(gtk.Widget);
}

fn labelApplied(row: *adw.EntryRow, _: *Ctx) callconv(.c) void {
    settings.setString(&settings.current.client_label, std.mem.trim(u8, std.mem.span(row.as(gtk.Editable).getText()), " "));
}

// Interface.

fn interfacePage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const tabs = group(p, "Tabs", "Each session's windows, as tabs in the sidebar or above the panes");
    segments(ctx, tabs, "Tabs", settings.TabPosition, &settings.current.tab_position, &.{ "Left", "Right", "Above" }, App.tabsChanged);
    switchRow(ctx, tabs, "Fill available space", "Tabs above the panes share the width", &settings.current.tab_fill, App.tabsChanged);
    switchRow(ctx, tabs, "Show each process", "A tab lists every program in its window", &settings.current.tab_processes, App.tabsChanged);
    const panes_group = group(p, "Pane Behavior", null);
    switchRow(ctx, panes_group, "Focus follows mouse", "Pointing at a pane gives it the keyboard", &settings.current.focus_follows_mouse, null);
    rangePercentRow(ctx, panes_group, "Fade inactive panes", "How much panes without the keyboard dim, in percent", &settings.current.fade_inactive, 0, 60);
    switchRow(ctx, panes_group, "Fade panes for inactive windows", "Dim every pane while Compy isn't the window in use", &settings.current.fade_inactive_window, App.redrawAllPub);
    switchRow(ctx, panes_group, "Autobalance splits", "Panes share space evenly after one opens or closes", &settings.current.autobalance, null);
    switchRow(ctx, panes_group, "Match program backgrounds", "A pane's frame takes the background color of the program in it", &settings.current.match_program_bg, App.applyLook);
    switchRow(ctx, panes_group, "Rounded selection corners", null, &settings.current.rounded_selection, App.redrawAllPub);
    const hl = group(p, "Active Pane Highlight", null);
    switchRow(ctx, hl, "Show border on active pane", null, &settings.current.highlight_border, App.applyLook);
    switchRow(ctx, hl, "Animate active pane highlight", "The border fades in as focus moves", &settings.current.highlight_animate, App.applyLook);
    rangePercentRow(ctx, hl, "Highlight opacity", null, &settings.current.highlight_opacity, 10, 100);
    colorPicker(ctx, hl, "Highlight color", "The theme's accent unless one is picked", &settings.current.highlight_color, "Use Accent", App.applyLook);
    const go = group(p, "Go to Anything", null);
    switchRow(ctx, go, "Show recently used paths", "Folders your panes were in, to change to again", &settings.current.recent_paths_shown, null);
    const look = group(p, "Appearance", null);
    segments(ctx, look, "Color scheme", settings.ColorScheme, &settings.current.color_scheme, &.{ "Auto", "Light", "Dark" }, App.themeChanged);
    const panes = group(p, "Panes", null);
    const TightBool = struct {
        fn apply(app: *App) void {
            app.setTight(settings.current.tight);
        }
    };
    const PaneStyle = enum(u1) { comfortable, compact };
    const style = gpa.create(PaneStyle) catch unreachable;
    style.* = if (settings.current.tight) .compact else .comfortable;
    const Apply = struct {
        var target: *PaneStyle = undefined;
        fn run(app: *App) void {
            settings.current.tight = target.* == .compact;
            settings.save();
            TightBool.apply(app);
        }
    };
    Apply.target = style;
    segments(ctx, panes, "Pane style", PaneStyle, style, &.{ "Comfortable", "Compact" }, Apply.run);
    switchRow(ctx, panes, "Show pane headers", "The title row with the program, folder and pane buttons", &settings.current.show_headers, App.headersChanged);
    switchRow(ctx, panes, "Use color for program icons", "Brand colors for known programs, like Rex's tab icons", &settings.current.brand_icons, App.redrawAll);
    return p.as(gtk.Widget);
}

// Themes.

const ThemePick = struct { ctx: *Ctx, value: [:0]const u8, check: *gtk.Widget };

var theme_checks: std.ArrayList(*ThemePick) = .empty;

/// Theme values for the light and dark pickers: "" follows the host.
var theme_values: std.ArrayList([:0]u8) = .empty;

fn themeNames(list: *gtk.StringList) void {
    for (theme_values.items) |v| gpa.free(v);
    theme_values.clearRetainingCapacity();
    list.append("Follow host");
    theme_values.append(gpa, gpa.dupeSentinel(u8, "", 0) catch return) catch return;
    for (&themes.builtins) |*t| {
        const z = gpa.dupeSentinel(u8, t.name, 0) catch continue;
        list.append(z.ptr);
        theme_values.append(gpa, z) catch {};
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
        list.append(base.ptr);
        theme_values.append(gpa, std.fmt.allocPrintSentinel(gpa, "file:{s}", .{path}, 0) catch continue) catch {};
    }
}

const Slot = struct { ctx: *Ctx, field: *[]u8 };

/// A drop-down of every theme, for the light or the dark appearance.
fn slotRow(ctx: *Ctx, g: *adw.PreferencesGroup, title: [:0]const u8, field: *[]u8) void {
    const list = gtk.StringList.new(null);
    themeNames(list);
    const row = adw.ComboRow.new();
    row.as(adw.PreferencesRow).setTitle(title.ptr);
    row.setModel(list.as(gio.ListModel));
    for (theme_values.items, 0..) |v, i| if (std.mem.eql(u8, v, field.*)) row.setSelected(@intCast(i));
    const slot = gpa.create(Slot) catch return;
    slot.* = .{ .ctx = ctx, .field = field };
    const H = struct {
        fn picked(r: *adw.ComboRow, _: *gobject.ParamSpec, sl: *Slot) callconv(.c) void {
            const i = r.getSelected();
            if (i >= theme_values.items.len) return;
            settings.setString(sl.field, theme_values.items[i]);
            sl.ctx.app.themeChanged();
        }
    };
    _ = gobject.Object.signals.notify.connect(row, *Slot, &H.picked, slot, .{ .detail = "selected" });
    g.add(row.as(gtk.Widget));
}

fn customThemes(ctx: *Ctx, p: *adw.PreferencesPage) void {
    const g = group(p, "Custom Themes", "Your own themes, saved in ~/.config/compy/themes");
    const new_button = gtk.Button.newWithLabel("New Theme");
    new_button.as(gtk.Widget).addCssClass("flat");
    new_button.as(gtk.Widget).setValign(.center);
    g.setHeaderSuffix(new_button.as(gtk.Widget));
    _ = gtk.Button.signals.clicked.connect(new_button, *Ctx, &newTheme, ctx, .{});
    var custom: std.ArrayList([:0]u8) = .empty;
    defer custom.deinit(gpa);
    theme_editor.list(&custom);
    if (custom.items.len == 0) {
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle("No custom themes");
        g.add(row.as(gtk.Widget));
    }
    for (custom.items) |path| {
        const row = adw.ActionRow.new();
        const base = gpa.dupeSentinel(u8, std.fs.path.basename(path), 0) catch continue;
        defer gpa.free(base);
        row.as(adw.PreferencesRow).setTitle(base.ptr);
        const value = std.fmt.allocPrintSentinel(gpa, "file:{s}", .{path}, 0) catch continue;
        const edit = gtk.Button.newWithLabel("Edit");
        edit.as(gtk.Widget).addCssClass("flat");
        edit.as(gtk.Widget).setValign(.center);
        const del = gtk.Button.newFromIconName("user-trash-symbolic");
        del.as(gtk.Widget).addCssClass("flat");
        del.as(gtk.Widget).setValign(.center);
        del.as(gtk.Widget).setTooltipText("Delete this theme");
        const use = gtk.Button.newWithLabel("Use");
        use.as(gtk.Widget).addCssClass("flat");
        use.as(gtk.Widget).setValign(.center);
        row.addSuffix(use.as(gtk.Widget));
        row.addSuffix(edit.as(gtk.Widget));
        row.addSuffix(del.as(gtk.Widget));
        const ct = gpa.create(CustomTheme) catch continue;
        ct.* = .{ .ctx = ctx, .path = path, .value = value };
        _ = gtk.Button.signals.clicked.connect(edit, *CustomTheme, &editTheme, ct, .{});
        _ = gtk.Button.signals.clicked.connect(del, *CustomTheme, &deleteTheme, ct, .{});
        _ = gtk.Button.signals.clicked.connect(use, *CustomTheme, &useTheme, ct, .{});
        g.add(row.as(gtk.Widget));
    }
}

const CustomTheme = struct { ctx: *Ctx, path: [:0]u8, value: [:0]u8 };

fn themeSaved(data: *anyopaque, path: []const u8) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data));
    const value = std.fmt.allocPrint(gpa, "file:{s}", .{path}) catch return;
    defer gpa.free(value);
    settings.setString(&settings.current.theme, value);
    ctx.app.themeChanged();
    rebuildThemes(ctx);
}

fn newTheme(_: *gtk.Button, ctx: *Ctx) callconv(.c) void {
    const start = themes.active orelse (if (ctx.app.server) |s| s.host_colors else null) orelse @import("stream.zig").Colors{};
    theme_editor.open(ctx.dialog.as(gtk.Widget), null, start, ctx, &themeSaved);
}

fn editTheme(_: *gtk.Button, ct: *CustomTheme) callconv(.c) void {
    theme_editor.open(ct.ctx.dialog.as(gtk.Widget), ct.path, .{}, ct.ctx, &themeSaved);
}

fn useTheme(_: *gtk.Button, ct: *CustomTheme) callconv(.c) void {
    settings.setString(&settings.current.theme, ct.value);
    ct.ctx.app.themeChanged();
    rebuildThemes(ct.ctx);
}

fn deleteTheme(_: *gtk.Button, ct: *CustomTheme) callconv(.c) void {
    _ = glib.unlink(ct.path.ptr);
    if (std.mem.eql(u8, settings.current.theme, ct.value)) {
        settings.setString(&settings.current.theme, "");
        ct.ctx.app.themeChanged();
    }
    rebuildThemes(ct.ctx);
}

/// Builds the Themes page again, after a custom theme comes or goes.
fn rebuildThemes(ctx: *Ctx) void {
    const stack = ctx.stack;
    if (stack.getChildByName("Themes")) |old| stack.remove(old);
    _ = stack.addNamed(themesPage(ctx), "Themes");
    stack.setVisibleChildName("Themes");
}

fn themesPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    theme_checks.clearRetainingCapacity();
    const look = group(p, "Appearance", null);
    switchRow(ctx, look, "Separate light and dark themes", "Follow the system's appearance with a theme for each", &settings.current.theme_follow_system, App.themeChanged);
    slotRow(ctx, look, "Light theme", &settings.current.theme_light);
    slotRow(ctx, look, "Dark theme", &settings.current.theme_dark);
    const g = group(p, "Terminal Theme", "Compy follows each host's theme unless you pick one here. A theme picked here only colors Compy; your Rex server keeps its own.");
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
    const tz = gpa.dupeSentinel(u8, title, 0) catch return;
    row.as(adw.PreferencesRow).setTitle(tz.ptr);
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
    const pick = gpa.create(ThemePick) catch return;
    pick.* = .{ .ctx = ctx, .value = gpa.dupeSentinel(u8, value, 0) catch return, .check = check.as(gtk.Widget) };
    theme_checks.append(gpa, pick) catch {};
    _ = adw.ActionRow.signals.activated.connect(row, *ThemePick, &themePicked, pick, .{});
    g.add(row.as(gtk.Widget));
}

fn themePicked(_: *adw.ActionRow, pick: *ThemePick) callconv(.c) void {
    settings.setString(&settings.current.theme, pick.value);
    for (theme_checks.items) |c| c.check.setVisible(@intFromBool(c == pick));
    pick.ctx.app.themeChanged();
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
    cr.setSourceRgb(@as(f64, @floatFromInt((c >> 16) & 0xff)) / 255, @as(f64, @floatFromInt((c >> 8) & 0xff)) / 255, @as(f64, @floatFromInt(c & 0xff)) / 255);
}

fn importClicked(_: *gtk.Button, ctx: *Ctx) callconv(.c) void {
    const fd = gtk.FileDialog.new();
    fd.setTitle("Import a Ghostty theme");
    fd.open(ctx.app.window.as(gtk.Window), null, &imported, ctx);
}

fn imported(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const fd: *gtk.FileDialog = @ptrCast(source orelse return);
    const f = fd.openFinish(result, null) orelse return;
    defer f.as(gobject.Object).unref();
    const path = f.getPath() orelse return;
    defer glib.free(path);
    const p = std.mem.span(path);
    if (themes.loadGhostty(p) == null) {
        ctx.app.toasts.addToast(adw.Toast.new("That file doesn't look like a Ghostty theme"));
        return;
    }
    const value = std.fmt.allocPrint(gpa, "file:{s}", .{p}) catch return;
    defer gpa.free(value);
    settings.setString(&settings.current.theme, value);
    ctx.app.themeChanged();
    for (theme_checks.items) |c| c.check.setVisible(0);
}

// Terminal.

fn terminalPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const g = group(p, "Typography", null);
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
    segments(ctx, c, "Cursor style", settings.CursorStyle, &settings.current.cursor_style, &.{ "Program", "Block", "Bar", "Underline" }, App.redrawAll);
    numberRow(ctx, c, "Bar width", "In pixels, for the bar and underline cursors. The cursor takes the theme's accent color", &settings.current.cursor_width, 1, 6, 0.5, 1, App.redrawAll);
    switchRow(ctx, c, "Blink", "In the pane with the keyboard", &settings.current.cursor_blink, App.redrawAll);
    numberRow(ctx, c, "Blink interval", "Milliseconds between blinks", &settings.current.cursor_blink_ms, 200, 2000, 50, 0, App.terminalChanged);
    colorPicker(ctx, c, "Cursor text color", "The character under a block cursor", &settings.current.cursor_text_color, "Default", App.redrawAllPub);

    const colors = group(p, "Colors and Bell", null);
    switchRow(ctx, colors, "Improve text contrast", "Adjust text that would be hard to read against its background", &settings.current.improve_contrast, App.redrawAll);
    colorPicker(ctx, colors, "Selection background", "Selected text swaps its colors unless one is picked", &settings.current.selection_bg, "Default", App.redrawAllPub);
    colorPicker(ctx, colors, "Selection foreground", null, &settings.current.selection_fg, "Default", App.redrawAllPub);
    switchRow(ctx, colors, "Extended theme palette", "Make colors 16 to 255 from the theme's own colors", &settings.current.extended_palette, App.terminalChanged);
    switchRow(ctx, colors, "Flash on bell", "Briefly light up a pane when its program rings the bell", &settings.current.visual_bell, null);
    const paste = group(p, "Copy and Paste", null);
    switchRow(ctx, paste, "Animation on copy", "A Copied badge on the pane", &settings.current.copy_animation, null);
    switchRow(ctx, paste, "Copy on select", "Selected text goes straight to the clipboard. Programs that handle the mouse themselves, such as Claude Code, copy their own selections", &settings.current.copy_on_select, null);
    switchRow(ctx, paste, "Ask before pasting several lines", "Unless the program knows it's a paste, each line could run as a command", &settings.current.paste_warning, null);
    return p.as(gtk.Widget);
}

// The font is picked right on the page: a monospace family, searchable, and a size.

var font_family: ?*adw.ComboRow = null;
var font_size: ?*adw.SpinRow = null;
var font_names: std.ArrayList([:0]u8) = .empty;
var font_preview: ?*gtk.Label = null;

fn fontRows(ctx: *Ctx, g: *adw.PreferencesGroup) void {
    const current_z = gpa.dupeSentinel(u8, settings.current.font, 0) catch return;
    defer gpa.free(current_z);
    const current = pango.FontDescription.fromString(current_z.ptr);
    defer current.free();
    const current_family = if (current.getFamily()) |f| std.mem.span(f) else "Monospace";
    const current_size: f64 = @as(f64, @floatFromInt(current.getSize())) / pango.SCALE;

    // Every monospace family this computer has, in order.
    for (font_names.items) |n| gpa.free(n);
    font_names.clearRetainingCapacity();
    var families: [*]*pango.FontFamily = undefined;
    var count: c_int = 0;
    pangocairo.FontMap.getDefault().listFamilies(&families, &count);
    for (families[0..@intCast(count)]) |f| if (f.isMonospace() != 0 or looksMonospace(std.mem.span(f.getName()))) {
        font_names.append(gpa, gpa.dupeSentinel(u8, std.mem.span(f.getName()), 0) catch continue) catch {};
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
        const z = gpa.dupeSentinel(u8, current_family, 0) catch return;
        list.append(z.ptr);
        font_names.append(gpa, z) catch {};
        selected = @intCast(font_names.items.len - 1);
    }

    const family = adw.ComboRow.new();
    family.as(adw.PreferencesRow).setTitle("Font");
    family.setModel(list.as(gio.ListModel));
    family.setExpression(gtk.PropertyExpression.new(gtk.StringObject.getGObjectType(), null, "string").as(gtk.Expression));
    family.setEnableSearch(1);
    family.setSelected(selected);
    g.add(family.as(gtk.Widget));
    font_family = family;

    const size = adw.SpinRow.newWithRange(6, 40, 1);
    size.as(adw.PreferencesRow).setTitle("Size");
    size.setValue(current_size);
    g.add(size.as(gtk.Widget));
    font_size = size;

    const preview = gtk.Label.new("The quick brown fox jumps over the lazy dog  0O 1lI {}[] => !=");
    preview.setXalign(0);
    preview.setEllipsize(.end);
    preview.as(gtk.Widget).addCssClass("font-preview");
    const preview_row = adw.PreferencesRow.new();
    preview_row.as(gtk.ListBoxRow).setActivatable(0);
    preview_row.as(gtk.ListBoxRow).setChild(preview.as(gtk.Widget));
    g.add(preview_row.as(gtk.Widget));
    font_preview = preview;
    showPreview();

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

fn chosenFont(buf: []u8) ?[:0]const u8 {
    const family = font_family orelse return null;
    const size = font_size orelse return null;
    const i = family.getSelected();
    if (i >= font_names.items.len) return null;
    return std.fmt.bufPrintSentinel(buf, "{s} {d}", .{ font_names.items[i], @round(size.getValue()) }, 0) catch null;
}

fn showPreview() void {
    const label = font_preview orelse return;
    var buf: [256]u8 = undefined;
    const font = chosenFont(&buf) orelse return;
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
    const font = chosenFont(&buf) orelse return;
    if (std.mem.eql(u8, font, settings.current.font)) return;
    settings.setString(&settings.current.font, font);
    showPreview();
    ctx.app.fontChanged();
}

// Shortcuts.

fn shortcutsPage(ctx: *Ctx) *gtk.Widget {
    const p = page();
    const hint_group = group(p, "Key Hints", null);
    switchRow(ctx, hint_group, "Show key sequence hints", "After a prefix such as ctrl+a, list the keys that can follow", &settings.current.key_hints, null);
    @import("shortcuts.zig").build(ctx.app, p);
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
    switchRow(ctx, which, "Blocked", "A program needs your permission, an answer or a password", &st.alert_blocked, null);
    switchRow(ctx, which, "Error", "A program failed", &st.alert_error, null);
    switchRow(ctx, which, "Done", "A program finished", &st.alert_done, null);
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
        row.as(adw.PreferencesRow).setTitle((gpa.dupeSentinel(u8, h.label, 0) catch continue).ptr);
        row.setSubtitle((gpa.dupeSentinel(u8, h.url, 0) catch continue).ptr);
        const remove = gtk.Button.newWithLabel("Remove");
        remove.as(gtk.Widget).setValign(.center);
        remove.as(gtk.Widget).addCssClass("destructive-action");
        const hr = gpa.create(HostRow) catch continue;
        hr.* = .{ .ctx = ctx, .index = i };
        _ = gtk.Button.signals.clicked.connect(remove, *HostRow, &removeHost, hr, .{});
        row.addSuffix(remove.as(gtk.Widget));
        g.add(row.as(gtk.Widget));
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
