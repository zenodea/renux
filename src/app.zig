//! The Compy window: sessions and their windows in a sidebar, the chosen window's panes on the
//! right, and a connect page until a server is set.
const std = @import("std");
const builtin = @import("builtin");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const gdk = @import("gdk");
const gsk = @import("gsk");
const adw = @import("adw");
const server_mod = @import("server.zig");
const view = @import("view.zig");
const termview = @import("termview.zig");
const Server = server_mod.Server;
const Workspace = @import("workspace.zig").Workspace;
const config = @import("config.zig");
const theme = @import("theme.zig");

const gpa = std.heap.c_allocator;

const css =
    \\.workspace { background-color: @window_bg_color; }
    \\.pane { border-radius: 10px; outline: 1px solid @compy_stroke_subtle; outline-offset: -1px; }
    \\.pane.focused { outline: 1px solid alpha(@accent_bg_color, 0.9); outline-offset: -1px; }
    \\.session-heading { font-weight: 600; font-size: 0.8em; color: @compy_secondary; margin: 14px 8px 2px 8px; }
    \\.connect-box { margin: 0 24px; }
;

const Row = struct { session_id: []u8, window_id: []u8 };

pub const App = struct {
    app: *adw.Application,
    window: *adw.ApplicationWindow = undefined,
    toasts: *adw.ToastOverlay = undefined,
    sidebar: *gtk.ListBox = undefined,
    split: *adw.OverlaySplitView = undefined,
    stack: *gtk.Stack = undefined,
    status: *adw.StatusPage = undefined,
    retry_button: *gtk.Button = undefined,
    title: *adw.WindowTitle = undefined,
    entry: *gtk.Entry = undefined,
    server: ?*Server = null,
    workspace: ?*Workspace = null,
    rows: std.ArrayList(?Row) = .empty,
    /// The window the person is looking at, which may differ from the session's active one.
    session_id: ?[]u8 = null,
    window_id: ?[]u8 = null,
    rebuilding: bool = false,
    was_online: bool = false,
    theme_css: ?*gtk.CssProvider = null,
    theme_for: ?@import("stream.zig").Colors = null,

    pub fn create() !*App {
        const a = try gpa.create(App);
        a.* = .{ .app = adw.Application.new("dev.compy.linux", .{}) };
        _ = gio.Application.signals.activate.connect(a.app, *App, &activate, a, .{});
        return a;
    }

    pub fn run(a: *App) c_int {
        return a.app.as(gio.Application).run(0, null);
    }

    fn activate(_: *adw.Application, a: *App) callconv(.c) void {
        termview.font = termview.Font.init(config.fontName());
        const provider = gtk.CssProvider.new();
        provider.loadFromString(css);
        gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        a.applyTheme();
        a.window = adw.ApplicationWindow.new(a.app.as(gtk.Application));
        const win = a.window.as(gtk.Window);
        win.setDefaultSize(1180, 760);
        win.setTitle("Compy");

        // Sidebar.
        a.sidebar = gtk.ListBox.new();
        a.sidebar.as(gtk.Widget).addCssClass("navigation-sidebar");
        _ = gtk.ListBox.signals.row_activated.connect(a.sidebar, *App, &rowActivated, a, .{});
        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .automatic);
        scroller.setChild(a.sidebar.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        const side_header = adw.HeaderBar.new();
        side_header.setTitleWidget(adw.WindowTitle.new("Compy", "").as(gtk.Widget));
        const new_session = gtk.Button.newFromIconName("list-add-symbolic");
        new_session.as(gtk.Widget).setTooltipText("New session");
        new_session.as(gtk.Actionable).setActionName("app.new-session");
        side_header.packStart(new_session.as(gtk.Widget));
        const side = adw.ToolbarView.new();
        side.addTopBar(side_header.as(gtk.Widget));
        side.setContent(scroller.as(gtk.Widget));

        // Content.
        a.title = adw.WindowTitle.new("Compy", "");
        const header = adw.HeaderBar.new();
        header.setTitleWidget(a.title.as(gtk.Widget));
        header.packEnd(paneMenu().as(gtk.Widget));
        const new_window = gtk.Button.newFromIconName("tab-new-symbolic");
        new_window.as(gtk.Widget).setTooltipText("New window");
        new_window.as(gtk.Actionable).setActionName("app.new-window");
        header.packEnd(new_window.as(gtk.Widget));

        a.stack = gtk.Stack.new();
        a.stack.setTransitionType(.crossfade);
        a.status = adw.StatusPage.new();
        a.retry_button = gtk.Button.newWithLabel("Try again");
        a.retry_button.as(gtk.Widget).addCssClass("pill");
        a.retry_button.as(gtk.Widget).setHalign(.center);
        a.retry_button.as(gtk.Actionable).setActionName("app.retry");
        a.status.setChild(a.retry_button.as(gtk.Widget));
        _ = a.stack.addNamed(a.status.as(gtk.Widget), "status");
        _ = a.stack.addNamed(a.connectPage(), "connect");

        const content = adw.ToolbarView.new();
        content.addTopBar(header.as(gtk.Widget));
        content.setContent(a.stack.as(gtk.Widget));

        const split = adw.OverlaySplitView.new();
        a.split = split;
        split.setSidebar(side.as(gtk.Widget));
        split.setContent(content.as(gtk.Widget));
        split.setMinSidebarWidth(200);
        split.setMaxSidebarWidth(280);

        a.toasts = adw.ToastOverlay.new();
        a.toasts.setChild(split.as(gtk.Widget));
        a.window.setContent(a.toasts.as(gtk.Widget));

        a.addActions();
        installShotHook(a);

        if (config.serverUrl()) |url| {
            defer gpa.free(url);
            a.connect(url);
        } else {
            a.stack.setVisibleChildName("connect");
        }
        win.present();
    }

    fn connectPage(a: *App) *gtk.Widget {
        const page = adw.StatusPage.new();
        page.setIconName("network-server-symbolic");
        page.setTitle("Connect to Rex");
        page.setDescription("Enter the address your Rex server listens on, such as http://my-mac:8765.");
        const box = gtk.Box.new(.vertical, 12);
        box.as(gtk.Widget).addCssClass("connect-box");
        box.as(gtk.Widget).setHalign(.center);
        a.entry = gtk.Entry.new();
        a.entry.setPlaceholderText("http://host:port");
        a.entry.as(gtk.Widget).setSizeRequest(360, -1);
        _ = gtk.Entry.signals.activate.connect(a.entry, *App, &connectClicked, a, .{});
        const button = gtk.Button.newWithLabel("Connect");
        button.as(gtk.Widget).addCssClass("suggested-action");
        button.as(gtk.Widget).addCssClass("pill");
        button.as(gtk.Widget).setHalign(.center);
        _ = gtk.Button.signals.clicked.connect(button, *App, &connectButton, a, .{});
        box.append(a.entry.as(gtk.Widget));
        box.append(button.as(gtk.Widget));
        page.setChild(box.as(gtk.Widget));
        return page.as(gtk.Widget);
    }

    fn connectButton(_: *gtk.Button, a: *App) callconv(.c) void {
        connectClicked(a.entry, a);
    }

    fn connectClicked(entry: *gtk.Entry, a: *App) callconv(.c) void {
        const raw = std.mem.trim(u8, std.mem.span(entry.as(gtk.Editable).getText()), " ");
        if (raw.len == 0) return;
        const url = if (std.mem.indexOf(u8, raw, "://") == null)
            std.fmt.allocPrint(gpa, "http://{s}", .{raw}) catch return
        else
            gpa.dupe(u8, raw) catch return;
        defer gpa.free(url);
        config.saveServerUrl(url);
        a.connect(url);
    }

    fn connect(a: *App, url: []const u8) void {
        if (a.server) |s| {
            if (a.workspace) |w| w.clear();
            s.destroy();
        }
        const s = Server.create(url) catch return;
        s.observer = .{ .ctx = a, .changed = serverChanged };
        s.performer = .{ .ctx = a, .perform = perform };
        a.server = s;
        const ws = Workspace.create(s) catch return;
        a.workspace = ws;
        if (a.stack.getChildByName("workspace")) |old| a.stack.remove(old);
        _ = a.stack.addNamed(ws.root, "workspace");
        a.showState();
    }

    // Following the server.

    fn serverChanged(ctx: *anyopaque, what: server_mod.Change, session_id: ?[]const u8) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        switch (what) {
            .state => {
                a.applyTheme();
                a.showState();
            },
            .sessions => {
                a.ensureSelection();
                a.rebuildSidebar();
            },
            .view => {
                a.ensureSelection();
                a.rebuildSidebar();
                if (a.session_id) |sel| if (session_id) |sid| if (std.mem.eql(u8, sel, sid)) a.showSelected();
            },
            .message => {
                const s = a.server orelse return;
                const text = gpa.dupeSentinel(u8, s.message.items, 0) catch return;
                defer gpa.free(text);
                a.toasts.addToast(adw.Toast.new(text.ptr));
            },
        }
    }

    /// Colors the whole window from the host's terminal theme, once it is known.
    fn applyTheme(a: *App) void {
        const colors = if (a.server) |s| s.host_colors else null;
        if (a.theme_css != null) {
            if (colors == null) return;
            if (a.theme_for) |old| if (std.meta.eql(old, colors.?)) return;
        }
        a.theme_for = colors;
        const palette = theme.Palette.from(colors orelse .{});
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        palette.css(&out.writer) catch return;
        out.writer.writeByte(0) catch return;
        const provider = a.theme_css orelse blk: {
            const p = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, p.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            a.theme_css = p;
            break :blk p;
        };
        provider.loadFromString(@ptrCast(out.written().ptr));
        adw.StyleManager.getDefault().setColorScheme(if (palette.dark) .force_dark else .force_light);
    }

    fn showState(a: *App) void {
        const s = a.server orelse return;
        switch (s.state) {
            .online => {
                a.stack.setVisibleChildName("workspace");
                if (!a.was_online) if (a.workspace) |w| w.resendSizes();
                a.was_online = true;
            },
            .connecting => if (!a.was_online) {
                a.status.setIconName("network-transmit-receive-symbolic");
                a.status.setTitle("Connecting…");
                a.status.setDescription(null);
                a.retry_button.as(gtk.Widget).setVisible(0);
                a.stack.setVisibleChildName("status");
            },
            .offline => {
                a.was_online = false;
                const reason = gpa.dupeSentinel(u8, s.reason.items, 0) catch return;
                defer gpa.free(reason);
                a.status.setIconName("network-offline-symbolic");
                a.status.setTitle("Can't reach Rex");
                a.status.setDescription(reason.ptr);
                a.retry_button.as(gtk.Widget).setVisible(1);
                a.stack.setVisibleChildName("status");
            },
        }
    }

    /// Picks a session and window to show when none is picked or the picked one went away.
    fn ensureSelection(a: *App) void {
        const s = a.server orelse return;
        if (a.session_id) |sel| {
            var found = false;
            for (s.sessions.items) |session| if (std.mem.eql(u8, session.id, sel)) {
                found = true;
            };
            if (found) {
                if (s.sessionView(sel)) |v| {
                    if (a.window_id) |wid| if (v.window(wid) == null) setSlot(&a.window_id, null);
                }
                return;
            }
            setSlot(&a.session_id, null);
            setSlot(&a.window_id, null);
        }
        if (s.sessions.items.len == 0) return;
        setSlot(&a.session_id, s.sessions.items[0].id);
        a.showSelected();
    }

    fn showSelected(a: *App) void {
        const s = a.server orelse return;
        const ws = a.workspace orelse return;
        const sid = a.session_id orelse return;
        const v = s.sessionView(sid) orelse return;
        const w = (if (a.window_id) |wid| v.window(wid) else null) orelse v.activeWindow();
        ws.show(sid, w);
        var title_buf: [256]u8 = undefined;
        const title = if (w) |win| windowTitle(&title_buf, win, v) else "No windows";
        const label = sessionLabel(s, sid);
        var sub_buf: [256]u8 = undefined;
        const sub = std.fmt.bufPrintSentinel(&sub_buf, "{s}", .{label}, 0) catch "";
        a.title.setTitle(title.ptr);
        a.title.setSubtitle(sub.ptr);
        a.selectSidebarRow();
    }

    fn rebuildSidebar(a: *App) void {
        const s = a.server orelse return;
        a.rebuilding = true;
        defer a.rebuilding = false;
        a.sidebar.removeAll();
        for (a.rows.items) |r| if (r) |row| {
            gpa.free(row.session_id);
            gpa.free(row.window_id);
        };
        a.rows.clearRetainingCapacity();
        for (s.sessions.items) |session| {
            var buf: [256]u8 = undefined;
            const heading = std.fmt.bufPrintSentinel(&buf, "{s}", .{if (session.label.len > 0) session.label else "Session"}, 0) catch continue;
            const label = gtk.Label.new(heading.ptr);
            label.setXalign(0);
            label.as(gtk.Widget).addCssClass("session-heading");
            const head_row = gtk.ListBoxRow.new();
            head_row.setChild(label.as(gtk.Widget));
            head_row.setActivatable(0);
            head_row.setSelectable(0);
            a.sidebar.append(head_row.as(gtk.Widget));
            a.rows.append(gpa, null) catch {};
            const v = s.sessionView(session.id) orelse continue;
            for (v.windows) |*w| {
                var tbuf: [256]u8 = undefined;
                const title = windowTitle(&tbuf, w, v);
                const item = gtk.Label.new(title.ptr);
                item.setXalign(0);
                item.setEllipsize(.end);
                const row = gtk.ListBoxRow.new();
                row.setChild(item.as(gtk.Widget));
                a.sidebar.append(row.as(gtk.Widget));
                a.rows.append(gpa, .{
                    .session_id = gpa.dupe(u8, session.id) catch continue,
                    .window_id = gpa.dupe(u8, w.id) catch continue,
                }) catch {};
            }
        }
        a.selectSidebarRow();
    }

    fn selectSidebarRow(a: *App) void {
        const s = a.server orelse return;
        const sid = a.session_id orelse return;
        const v = s.sessionView(sid) orelse return;
        const shown = (if (a.window_id) |wid| v.window(wid) else null) orelse v.activeWindow() orelse return;
        for (a.rows.items, 0..) |r, i| if (r) |row| {
            if (std.mem.eql(u8, row.session_id, sid) and std.mem.eql(u8, row.window_id, shown.id)) {
                const was = a.rebuilding;
                a.rebuilding = true;
                a.sidebar.selectRow(a.sidebar.getRowAtIndex(@intCast(i)));
                a.rebuilding = was;
                return;
            }
        };
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, a: *App) callconv(.c) void {
        if (a.rebuilding) return;
        const index: usize = @intCast(row.getIndex());
        if (index >= a.rows.items.len) return;
        const r = a.rows.items[index] orelse return;
        setSlot(&a.session_id, r.session_id);
        setSlot(&a.window_id, r.window_id);
        if (a.server) |s| s.focusWindow(r.session_id, r.window_id);
        a.showSelected();
        if (a.workspace) |w| w.grabFocus();
    }

    // client.* actions. Key bindings live in the person's Lua config on the server; the server
    // runs its own actions and asks the client for these.

    fn perform(ctx: *anyopaque, action: []const u8, args: ?@import("json.zig").Value, session_id: ?[]const u8) bool {
        const a: *App = @ptrCast(@alignCast(ctx));
        const J = @import("json.zig");
        if (session_id) |sid| if (!eqlOpt(a.session_id, sid)) {
            setSlot(&a.session_id, sid);
            setSlot(&a.window_id, null);
        };
        if (std.mem.eql(u8, action, "session.select")) {
            setSlot(&a.window_id, J.str(args, "window_id"));
            a.showSelected();
            a.rebuildSidebar();
            return true;
        }
        if (std.mem.eql(u8, action, "client.tab.new")) return a.did(newWindow);
        if (std.mem.eql(u8, action, "client.tab.close")) {
            const s = a.server orelse return false;
            const sid = a.session_id orelse return false;
            const w = a.shownWindow() orelse return false;
            s.closeWindow(sid, w.id);
            return true;
        }
        if (std.mem.eql(u8, action, "client.tab.next")) return a.stepWindow(1);
        if (std.mem.eql(u8, action, "client.tab.previous")) return a.stepWindow(-1);
        if (std.mem.eql(u8, action, "client.tab.goto")) {
            const index = J.int(args, "index") orelse return false;
            return a.gotoWindow(index - 1);
        }
        if (std.mem.eql(u8, action, "client.sidebar.toggle")) {
            a.split.setShowSidebar(@intFromBool(a.split.getShowSidebar() == 0));
            return true;
        }
        return false;
    }

    fn did(a: *App, comptime f: fn (*App) void) bool {
        f(a);
        return true;
    }

    fn shownWindow(a: *App) ?*const view.Window {
        const s = a.server orelse return null;
        const v = s.sessionView(a.session_id orelse return null) orelse return null;
        return (if (a.window_id) |wid| v.window(wid) else null) orelse v.activeWindow();
    }

    fn stepWindow(a: *App, delta: i64) bool {
        const s = a.server orelse return false;
        const v = s.sessionView(a.session_id orelse return false) orelse return false;
        const w = a.shownWindow() orelse return false;
        const n: i64 = @intCast(v.windows.len);
        for (v.windows, 0..) |*other, i| if (other == w) return a.gotoWindow(@mod(@as(i64, @intCast(i)) + delta, n));
        return false;
    }

    fn gotoWindow(a: *App, index: i64) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const v = s.sessionView(sid) orelse return false;
        if (index < 0 or index >= v.windows.len) return false;
        const w = v.windows[@intCast(index)];
        setSlot(&a.window_id, w.id);
        s.focusWindow(sid, w.id);
        a.showSelected();
        if (a.workspace) |ws| ws.grabFocus();
        return true;
    }

    // Actions, for the menu.

    fn addActions(a: *App) void {
        const entries = [_]struct { [:0]const u8, *const fn (*App) void, [:0]const u8 }{
            .{ "split-right", splitRight, "" },
            .{ "split-down", splitDown, "" },
            .{ "close-pane", closePane, "" },
            .{ "zoom-pane", zoomPane, "" },
            .{ "new-window", newWindow, "" },
            .{ "new-session", newSession, "" },
            .{ "paste", paste, "" },
            .{ "retry", retry, "" },
            .{ "change-server", changeServer, "" },
        };
        inline for (entries) |e| {
            const action = gio.SimpleAction.new(e[0], null);
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, _: ?*glib.Variant, app: *App) callconv(.c) void {
                    e[1](app);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
            if (e[2].len > 0) {
                const accels = [_:null]?[*:0]const u8{e[2].ptr};
                var name_buf: [64]u8 = undefined;
                const name = std.fmt.bufPrintSentinel(&name_buf, "app.{s}", .{e[0]}, 0) catch unreachable;
                a.app.as(gtk.Application).setAccelsForAction(name.ptr, &accels);
            }
        }
    }

    fn target(a: *App) ?struct { *Server, []const u8, []const u8 } {
        const s = a.server orelse return null;
        const ws = a.workspace orelse return null;
        const sid = a.session_id orelse return null;
        const block = ws.focusedBlock() orelse return null;
        return .{ s, sid, block };
    }

    fn splitRight(a: *App) void {
        const t = a.target() orelse return;
        t[0].newSplit(t[1], t[2], true, false);
    }

    fn splitDown(a: *App) void {
        const t = a.target() orelse return;
        t[0].newSplit(t[1], t[2], false, false);
    }

    fn closePane(a: *App) void {
        const t = a.target() orelse return;
        t[0].closeBlock(t[1], t[2]);
    }

    fn zoomPane(a: *App) void {
        const t = a.target() orelse return;
        const v = t[0].sessionView(t[1]) orelse return;
        const w = v.windowOf(t[2]) orelse return;
        t[0].zoomBlock(t[1], t[2], w.zoomed_block_id == null);
    }

    fn newWindow(a: *App) void {
        const s = a.server orelse return;
        const sid = a.session_id orelse return;
        setSlot(&a.window_id, null); // follow the new active window
        s.newWindow(sid);
    }

    fn newSession(a: *App) void {
        const s = a.server orelse return;
        s.createSession("");
    }

    fn paste(a: *App) void {
        const ws = a.workspace orelse return;
        _ = ws;
    }

    fn retry(a: *App) void {
        if (a.server) |s| s.retry();
    }

    fn changeServer(a: *App) void {
        a.stack.setVisibleChildName("connect");
    }
};

fn paneMenu() *gtk.MenuButton {
    const menu = gio.Menu.new();
    const panes = gio.Menu.new();
    panes.append("Split right", "app.split-right");
    panes.append("Split down", "app.split-down");
    panes.append("Zoom pane", "app.zoom-pane");
    panes.append("Close pane", "app.close-pane");
    menu.appendSection(null, panes.as(gio.MenuModel));
    const other = gio.Menu.new();
    other.append("New window", "app.new-window");
    other.append("New session", "app.new-session");
    other.append("Change server…", "app.change-server");
    menu.appendSection(null, other.as(gio.MenuModel));
    const button = gtk.MenuButton.new();
    button.setIconName("open-menu-symbolic");
    button.setMenuModel(menu.as(gio.MenuModel));
    return button;
}

fn windowTitle(buf: []u8, w: *const view.Window, v: *const view.SessionView) [:0]const u8 {
    if (w.title()) |t| return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
    // Rex generated the label, so the first pane's says more.
    for (w.layers) |l| for (l.blocks) |b| if (b.label.len > 0) {
        return std.fmt.bufPrintSentinel(buf, "{s}", .{b.label}, 0) catch "Window";
    };
    for (v.windows, 0..) |*other, i| if (other == w) {
        return std.fmt.bufPrintSentinel(buf, "Window {d}", .{i + 1}, 0) catch "Window";
    };
    return "Window";
}

fn sessionLabel(s: *Server, id: []const u8) []const u8 {
    for (s.sessions.items) |session| if (std.mem.eql(u8, session.id, id)) return if (session.label.len > 0) session.label else "Session";
    return "";
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

fn setSlot(slot: *?[]u8, value: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (value) |v| gpa.dupe(u8, v) catch null else null;
}

// Development: SIGUSR1 saves a picture of the window to $COMPY_SHOT, since macOS won't let a
// terminal capture another app's window without asking.

var shot_app: ?*App = null;

fn installShotHook(a: *App) void {
    if (std.c.getenv("COMPY_SHOT") == null) return;
    shot_app = a;
    _ = @import("glibunix").signalAdd(@intFromEnum(std.posix.SIG.USR1), &takeShot, null);
}

fn takeShot(_: ?*anyopaque) callconv(.c) c_int {
    const a = shot_app orelse return 1;
    const path = std.c.getenv("COMPY_SHOT") orelse return 1;
    const w = a.window.as(gtk.Widget);
    const paintable = gtk.WidgetPaintable.new(w);
    defer paintable.as(gobject.Object).unref();
    const width: f64 = @floatFromInt(w.getWidth());
    const height: f64 = @floatFromInt(w.getHeight());
    const snap = gtk.Snapshot.new();
    paintable.as(gdk.Paintable).snapshot(snap.as(gdk.Snapshot), width, height);
    const node = snap.freeToNode() orelse return 1;
    defer node.unref();
    const renderer = a.window.as(gtk.Native).getRenderer() orelse return 1;
    const texture = renderer.renderTexture(node, null);
    defer texture.as(gobject.Object).unref();
    _ = texture.saveToPng(path);
    return 1;
}
