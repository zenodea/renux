//! Looking after Rex itself, like the Rex app: this computer's Rex server, setting agents up to
//! use Rex, a diagnostics page, and a short welcome for new people.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const app_mod = @import("app.zig");
const settings = @import("settings.zig");
const icons = @import("icons.zig");

const gpa = std.heap.c_allocator;
const App = app_mod.App;

/// Runs a rex command and returns what it printed, or null when rex isn't installed.
fn rexOutput(args: []const u8) ?[]u8 {
    const cmd = std.fmt.allocPrintSentinel(gpa, "rex --autostart=false {s}", .{args}, 0) catch return null;
    defer gpa.free(cmd);
    var out: [*:0]u8 = undefined;
    var errs: [*:0]u8 = undefined;
    var code: c_int = 0;
    if (glib.spawnCommandLineSync(cmd.ptr, &out, &errs, &code, null) == 0) return null;
    defer glib.free(errs);
    defer glib.free(out);
    return gpa.dupe(u8, std.mem.trim(u8, std.mem.span(out), " \n")) catch null;
}

fn rexInstalled() bool {
    const path = glib.findProgramInPath("rex") orelse return false;
    glib.free(path);
    return true;
}

/// Settings > Server's group for the Rex server on this computer.
pub fn localServerGroup(p: *adw.PreferencesPage, a: *App) void {
    const g = adw.PreferencesGroup.new();
    g.setTitle("Rex Server on This Computer");
    p.add(g);
    if (!rexInstalled()) {
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle("Rex isn't installed here");
        row.setSubtitle("Install Rex to run a server on this computer");
        g.add(row.as(gtk.Widget));
        return;
    }
    g.setDescription("Starts and stops the server on this computer only.");
    const row = adw.ActionRow.new();
    row.as(adw.PreferencesRow).setTitle("Status");
    const status = rexOutput("server status") orelse gpa.dupe(u8, "Unknown") catch return;
    defer gpa.free(status);
    const first_line = status[0 .. std.mem.indexOfScalar(u8, status, '\n') orelse status.len];
    const z = gpa.dupeSentinel(u8, first_line, 0) catch return;
    defer gpa.free(z);
    row.setSubtitle(z.ptr);
    row.setSubtitleLines(2);
    inline for (.{ .{ "Start", "server start" }, .{ "Stop", "server stop" } }) |b| {
        const button = gtk.Button.newWithLabel(b[0]);
        button.as(gtk.Widget).setValign(.center);
        button.as(gtk.Widget).addCssClass("flat");
        const H = struct {
            fn run(_: *gtk.Button, app: *App) callconv(.c) void {
                _ = glib.spawnCommandLineAsync("rex " ++ b[1], null);
                app.toastText(b[0] ++ "ing the Rex server");
            }
        };
        _ = gtk.Button.signals.clicked.connect(button, *App, &H.run, a, .{});
        row.addSuffix(button.as(gtk.Widget));
    }
    g.add(row.as(gtk.Widget));

    const agents = adw.ActionRow.new();
    agents.as(adw.PreferencesRow).setTitle("Agents");
    const skill = rexOutput("skill status") orelse gpa.dupe(u8, "") catch return;
    defer gpa.free(skill);
    const sz = gpa.dupeSentinel(u8, if (skill.len > 0) skill[0 .. std.mem.indexOfScalar(u8, skill, '\n') orelse skill.len] else "Let coding agents such as Claude Code use Rex", 0) catch return;
    defer gpa.free(sz);
    agents.setSubtitle(sz.ptr);
    const setup = gtk.Button.newWithLabel("Set Up");
    setup.as(gtk.Widget).setValign(.center);
    setup.as(gtk.Widget).addCssClass("flat");
    _ = gtk.Button.signals.clicked.connect(setup, *App, &setupClicked, a, .{});
    agents.addSuffix(setup.as(gtk.Widget));
    g.add(agents.as(gtk.Widget));
}

fn setupClicked(_: *gtk.Button, a: *App) callconv(.c) void {
    setupAgents(a);
}

/// Opens a tab that runs `rex skill setup`, so it asks its questions in a real terminal.
pub fn setupAgents(a: *App) void {
    a.runInNewTab("rex skill setup");
}

// Diagnostics.

/// A page of what Compy knows about each host, with a button to copy it all.
pub fn openDiagnostics(a: *App) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    text.appendSlice(gpa, "Compy for Linux\n") catch return;
    text.print(gpa, "GTK {d}.{d}.{d}, libadwaita {d}.{d}.{d}\n", .{ gtk.getMajorVersion(), gtk.getMinorVersion(), gtk.getMicroVersion(), adw.getMajorVersion(), adw.getMinorVersion(), adw.getMicroVersion() }) catch return;
    for (a.hosts.items) |h| {
        const s = h.server;
        text.print(gpa, "\nHost {s}\n  address: {s}\n  state: {s}\n", .{ h.label, s.url, @tagName(s.state) }) catch return;
        if (s.rex_version) |v| text.print(gpa, "  Rex: {s}\n", .{v}) catch return;
        if (s.state == .offline) text.print(gpa, "  reason: {s}\n", .{s.reason.items}) catch return;
        var windows: usize = 0;
        var panes: usize = 0;
        for (s.sessions.items) |session| if (s.sessionView(session.id)) |v| {
            windows += v.windows.len;
            for (v.windows) |w| for (w.layers) |l| {
                panes += l.blocks.len;
            };
        };
        text.print(gpa, "  sessions: {d}, tabs: {d}, panes: {d}, streams: {d}\n  key bindings: {d}, actions: {d}\n", .{ s.sessions.items.len, windows, panes, s.streams.count(), s.bindings.len, s.actions.len }) catch return;
    }
    text.append(gpa, 0) catch return;

    const dialog = adw.Dialog.new();
    dialog.setTitle("Diagnostics");
    dialog.setContentWidth(560);
    dialog.setContentHeight(480);
    const view = adw.ToolbarView.new();
    const header = adw.HeaderBar.new();
    const copy = gtk.Button.newWithLabel("Copy Debug Info");
    header.packStart(copy.as(gtk.Widget));
    view.addTopBar(header.as(gtk.Widget));
    const label = gtk.Label.new(@ptrCast(text.items.ptr));
    label.setSelectable(1);
    label.setXalign(0);
    label.setYalign(0);
    label.as(gtk.Widget).addCssClass("diagnostics-text");
    label.as(gtk.Widget).setMarginStart(16);
    label.as(gtk.Widget).setMarginEnd(16);
    label.as(gtk.Widget).setMarginTop(12);
    const scroller = gtk.ScrolledWindow.new();
    scroller.setChild(label.as(gtk.Widget));
    view.setContent(scroller.as(gtk.Widget));
    dialog.setChild(view.as(gtk.Widget));
    const H = struct {
        fn copied(_: *gtk.Button, l: *gtk.Label) callconv(.c) void {
            l.as(gtk.Widget).getClipboard().setText(l.getText());
        }
    };
    _ = gtk.Button.signals.clicked.connect(copy, *gtk.Label, &H.copied, label, .{});
    dialog.present(a.window.as(gtk.Widget));
}

// Welcome.

const Tip = struct { title: [:0]const u8, text: [:0]const u8, icon: icons.Kind };

const tips = [_]Tip{
    .{ .title = "Welcome to Compy", .text = "A Rex client for Linux. Your sessions, tabs and panes live on the Rex server, so they're the same here, in the Rex app and on your phone.", .icon = .terminal },
    .{ .title = "Your keys come from Rex", .text = "Bindings in your Rex config work here, prefixes included. After a prefix such as ctrl+a, Compy lists the keys that can follow.", .icon = .keyboard },
    .{ .title = "Find anything", .text = "Go to Anything searches every session, tab, pane and recent folder. The activity panel shows what each program is doing, with the ones that need you first.", .icon = .search },
    .{ .title = "Make it yours", .text = "Settings has themes, fonts, transparency, tab styles and more. A shortcut you record there takes the place of your config's keys for that action.", .icon = .palette },
};

/// A few pages about Compy, shown on first launch and from client.onboarding.
pub fn openWelcome(a: *App) void {
    const dialog = adw.Dialog.new();
    dialog.setContentWidth(480);
    dialog.setContentHeight(420);
    const box = gtk.Box.new(.vertical, 12);
    box.as(gtk.Widget).setMarginBottom(18);
    const carousel = adw.Carousel.new();
    carousel.as(gtk.Widget).setVexpand(1);
    for (tips) |t| {
        const pg = gtk.Box.new(.vertical, 14);
        pg.as(gtk.Widget).setHexpand(1);
        pg.as(gtk.Widget).setValign(.center);
        pg.as(gtk.Widget).setMarginStart(36);
        pg.as(gtk.Widget).setMarginEnd(36);
        const icon = icons.image(t.icon, 56);
        icon.addCssClass("welcome-icon");
        pg.append(icon);
        const title = gtk.Label.new(t.title.ptr);
        title.as(gtk.Widget).addCssClass("title-1");
        title.setWrap(1);
        title.setJustify(.center);
        pg.append(title.as(gtk.Widget));
        const text = gtk.Label.new(t.text.ptr);
        text.setWrap(1);
        text.setJustify(.center);
        text.setMaxWidthChars(40);
        text.as(gtk.Widget).addCssClass("dim-label");
        pg.append(text.as(gtk.Widget));
        carousel.append(pg.as(gtk.Widget));
    }
    box.append(carousel.as(gtk.Widget));
    const dots = adw.CarouselIndicatorDots.new();
    dots.setCarousel(carousel);
    box.append(dots.as(gtk.Widget));
    const next = gtk.Button.newWithLabel("Next");
    next.as(gtk.Widget).addCssClass("pill");
    next.as(gtk.Widget).addCssClass("suggested-action");
    next.as(gtk.Widget).setHalign(.center);
    box.append(next.as(gtk.Widget));
    dialog.setChild(box.as(gtk.Widget));
    const Ctx = struct { carousel: *adw.Carousel, dialog: *adw.Dialog, button: *gtk.Button };
    const c = gpa.create(Ctx) catch return;
    c.* = .{ .carousel = carousel, .dialog = dialog, .button = next };
    const H = struct {
        fn clicked(_: *gtk.Button, x: *Ctx) callconv(.c) void {
            const at: c_uint = @intFromFloat(@round(x.carousel.getPosition()));
            if (at + 1 >= x.carousel.getNPages()) {
                _ = x.dialog.close();
                return;
            }
            x.carousel.scrollTo(x.carousel.getNthPage(at + 1), 1);
        }
        fn moved(car: *adw.Carousel, index: c_uint, x: *Ctx) callconv(.c) void {
            x.button.setLabel(if (index + 1 >= car.getNPages()) "Get Started" else "Next");
        }
        fn closed(_: *adw.Dialog, x: *Ctx) callconv(.c) void {
            settings.current.welcomed = true;
            settings.save();
            gpa.destroy(x);
        }
    };
    _ = gtk.Button.signals.clicked.connect(next, *Ctx, &H.clicked, c, .{});
    _ = adw.Carousel.signals.page_changed.connect(carousel, *Ctx, &H.moved, c, .{});
    _ = adw.Dialog.signals.closed.connect(dialog, *Ctx, &H.closed, c, .{});
    dialog.present(a.window.as(gtk.Widget));
}
