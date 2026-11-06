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
const icons = @import("icons.zig");

const gpa = std.heap.c_allocator;

const css =
    \\window.compy, window.compy .sidebar-pane { background-color: @compy_shell; }
    \\.compy-sidebar headerbar { background: none; box-shadow: none; min-height: 42px; }
    \\.compy-sidebar list { background: none; }
    \\.compy-sidebar list > row { border-radius: 8px; min-height: 34px; padding: 0 4px 0 8px; margin: 1px 8px; }
    \\.compy-sidebar list > row:selected { background-color: alpha(@window_fg_color, 0.09); }
    \\.compy-sidebar list > row:hover:not(:selected) { background-color: alpha(@window_fg_color, 0.04); }
    \\.compy-sidebar .row-title { font-size: 0.95em; }
    \\.row-more { opacity: 0; }
    \\row:hover .row-more, row:selected .row-more { opacity: 0.6; }
    \\.session-heading { font-size: 0.82em; color: @compy_secondary; margin: 14px 12px 4px 12px; }
    \\.sidebar-footer { padding: 6px 10px 10px 10px; }
    \\.content .workspace { margin: 8px 8px 8px 0; }
    \\.content.alone .workspace { margin: 0 8px 8px 8px; }
    \\.top-strip { min-height: 38px; padding: 0 8px; }
    \\.pane-card { background-color: @view_bg_color; border-radius: 11px; border: 1px solid @compy_stroke_subtle; }
    \\.pane-card.focused { border-color: alpha(@accent_bg_color, 0.85); box-shadow: 0 0 0 1px alpha(@accent_bg_color, 0.35); }
    \\.pane-card.floating { box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.pane-card.floating.focused { box-shadow: 0 0 0 1px alpha(@accent_bg_color, 0.35), 0 8px 28px alpha(black, 0.45); }
    \\.pane-title { min-height: 34px; padding: 0 4px 0 12px; }
    \\.pane-title .title { font-weight: 500; font-size: 0.95em; }
    \\.pane-card:not(.focused) .pane-title .title { color: @compy_secondary; }
    \\.pane-tools { opacity: 0; transition: opacity 120ms; }
    \\.pane-card.focused .pane-tools, .pane-card:hover .pane-tools { opacity: 1; }
    \\.icon-button { min-width: 26px; min-height: 26px; padding: 0; border-radius: 7px; opacity: 0.5; }
    \\.icon-button:hover { opacity: 1; background-color: alpha(@window_fg_color, 0.08); }
    \\.find-bar { padding: 8px 8px 0 0; }
    \\.content.alone .find-bar { padding-left: 8px; }
    \\.find-count { color: @compy_secondary; font-size: 0.9em; min-width: 52px; }
    \\.tray-chip { border-radius: 9px; padding: 4px 10px 4px 6px; background-color: @popover_bg_color; box-shadow: 0 2px 10px alpha(black, 0.3); }
    \\window.tight .content .workspace { margin: 0; }
    \\window.tight .pane-card { border-radius: 0; border: none; box-shadow: none; }
    \\window.tight .workspace { background-color: @compy_stroke_subtle; }
    \\window.tight .pane-card.focused .pane-title .title { color: @accent_color; }
    \\window.tight .pane-card.floating { border: 1px solid @compy_stroke; border-radius: 8px; box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.connect-box { margin: 0 24px; }
;

const Row = struct { session_id: []u8, window_id: []u8, label: ?*gtk.Label = null, line: ?*gtk.Box = null, tile: ?*gtk.Widget = null };

pub const App = struct {
    app: *adw.Application,
    window: *adw.ApplicationWindow = undefined,
    toasts: *adw.ToastOverlay = undefined,
    sidebar: *gtk.ListBox = undefined,
    split: *adw.OverlaySplitView = undefined,
    card: *gtk.Widget = undefined,
    card_start: *gtk.Widget = undefined,
    stack: *gtk.Stack = undefined,
    status: *adw.StatusPage = undefined,
    retry_button: *gtk.Button = undefined,
    find_bar: *gtk.Revealer = undefined,
    find_entry: *gtk.SearchEntry = undefined,
    find_count: *gtk.Label = undefined,
    find_total: usize = 0,
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
        win.as(gtk.Widget).addCssClass("compy");

        // Sidebar: window controls and a menu on top, sessions and their windows, then a footer.
        a.sidebar = gtk.ListBox.new();
        a.sidebar.as(gtk.Widget).addCssClass("navigation-sidebar");
        _ = gtk.ListBox.signals.row_activated.connect(a.sidebar, *App, &rowActivated, a, .{});
        const scroller = gtk.ScrolledWindow.new();
        scroller.setPolicy(.never, .automatic);
        scroller.setChild(a.sidebar.as(gtk.Widget));
        scroller.as(gtk.Widget).setVexpand(1);
        const side_header = adw.HeaderBar.new();
        side_header.setShowTitle(0);
        side_header.packStart(icons.button(.sidebar, "Hide sidebar", "app.toggle-sidebar").as(gtk.Widget));
        side_header.packEnd(menuButton(appMenu(), "More").as(gtk.Widget));
        const footer = gtk.Box.new(.horizontal, 2);
        footer.as(gtk.Widget).addCssClass("sidebar-footer");
        footer.append(icons.button(.plus, "New session", "app.new-session").as(gtk.Widget));
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        footer.append(spacer.as(gtk.Widget));
        footer.append(icons.button(.server, "Change server", "app.change-server").as(gtk.Widget));
        const side = adw.ToolbarView.new();
        side.as(gtk.Widget).addCssClass("compy-sidebar");
        side.addTopBar(side_header.as(gtk.Widget));
        side.addBottomBar(footer.as(gtk.Widget));
        side.setContent(scroller.as(gtk.Widget));

        // Content: the panes, each its own card, on the window's background. While the sidebar is
        // hidden, a slim strip above them carries the window controls and the sidebar toggle.
        const strip = gtk.Box.new(.horizontal, 4);
        strip.as(gtk.Widget).addCssClass("top-strip");
        strip.append(gtk.WindowControls.new(.start).as(gtk.Widget));
        strip.append(icons.button(.sidebar, "Show sidebar", "app.toggle-sidebar").as(gtk.Widget));
        const strip_space = gtk.Box.new(.horizontal, 0);
        strip_space.as(gtk.Widget).setHexpand(1);
        strip.append(strip_space.as(gtk.Widget));
        strip.append(gtk.WindowControls.new(.end).as(gtk.Widget));
        const strip_handle = gtk.WindowHandle.new();
        strip_handle.setChild(strip.as(gtk.Widget));
        strip_handle.as(gtk.Widget).setVisible(0);
        a.card_start = strip_handle.as(gtk.Widget);

        a.stack = gtk.Stack.new();
        a.stack.setTransitionType(.crossfade);
        a.stack.as(gtk.Widget).setVexpand(1);
        a.status = adw.StatusPage.new();
        a.retry_button = gtk.Button.newWithLabel("Try again");
        a.retry_button.as(gtk.Widget).addCssClass("pill");
        a.retry_button.as(gtk.Widget).setHalign(.center);
        a.retry_button.as(gtk.Actionable).setActionName("app.retry");
        a.status.setChild(a.retry_button.as(gtk.Widget));
        _ = a.stack.addNamed(a.status.as(gtk.Widget), "status");
        _ = a.stack.addNamed(a.connectPage(), "connect");

        // Find, under the title.
        const find_row = gtk.Box.new(.horizontal, 4);
        find_row.as(gtk.Widget).addCssClass("find-bar");
        a.find_entry = gtk.SearchEntry.new();
        a.find_entry.as(gtk.Widget).setHexpand(1);
        a.find_entry.setPlaceholderText("Find in pane");
        _ = gtk.SearchEntry.signals.search_changed.connect(a.find_entry, *App, &findChanged, a, .{});
        _ = gtk.SearchEntry.signals.activate.connect(a.find_entry, *App, &findNextSignal, a, .{});
        _ = gtk.SearchEntry.signals.next_match.connect(a.find_entry, *App, &findNextSignal, a, .{});
        _ = gtk.SearchEntry.signals.previous_match.connect(a.find_entry, *App, &findPrevSignal, a, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(a.find_entry, *App, &findStopSignal, a, .{});
        a.find_count = gtk.Label.new("");
        a.find_count.as(gtk.Widget).addCssClass("find-count");
        find_row.append(a.find_entry.as(gtk.Widget));
        find_row.append(a.find_count.as(gtk.Widget));
        find_row.append(icons.button(.up, "Newer match", "app.find-prev").as(gtk.Widget));
        find_row.append(icons.button(.down, "Older match", "app.find-next").as(gtk.Widget));
        find_row.append(icons.button(.close, "Close find", "app.find-close").as(gtk.Widget));
        a.find_bar = gtk.Revealer.new();
        a.find_bar.setChild(find_row.as(gtk.Widget));
        a.find_bar.setTransitionType(.slide_down);

        const card = gtk.Box.new(.vertical, 0);
        card.as(gtk.Widget).addCssClass("content");
        card.append(a.card_start);
        card.append(a.find_bar.as(gtk.Widget));
        card.append(a.stack.as(gtk.Widget));
        a.card = card.as(gtk.Widget);

        const split = adw.OverlaySplitView.new();
        a.split = split;
        split.setSidebar(side.as(gtk.Widget));
        split.setContent(card.as(gtk.Widget));
        split.setMinSidebarWidth(220);
        split.setMaxSidebarWidth(280);
        _ = gobject.Object.signals.notify.connect(split, *App, &sidebarShown, a, .{ .detail = "show-sidebar" });

        a.toasts = adw.ToastOverlay.new();
        a.toasts.setChild(split.as(gtk.Widget));
        a.window.setContent(a.toasts.as(gtk.Widget));

        a.addActions();
        a.setTight(config.tight());
        installShotHook(a);

        if (config.serverUrl()) |url| {
            defer gpa.free(url);
            a.connect(url);
        } else {
            a.stack.setVisibleChildName("connect");
        }
        // When driven by tests, show the window without taking the keyboard from what the person
        // is using; otherwise their typing lands in Compy.
        if (std.c.getenv("COMPY_SHOT") != null) win.as(gtk.Widget).setVisible(1) else win.present();
    }

    fn sidebarShown(split: *adw.OverlaySplitView, _: *gobject.ParamSpec, a: *App) callconv(.c) void {
        const shown = split.getShowSidebar() != 0;
        a.card_start.setVisible(@intFromBool(!shown));
        if (shown) a.card.removeCssClass("alone") else a.card.addCssClass("alone");
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
            .block => {
                const block = session_id orelse return;
                if (a.workspace) |w| w.blockChanged(block);
                a.refreshRows();
            },
            .alert => a.showAlert(),
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
                const title = a.rowTitle(&tbuf, w, v);
                const item = gtk.Label.new(title.ptr);
                item.setXalign(0);
                item.setEllipsize(.end);
                item.as(gtk.Widget).addCssClass("row-title");
                item.as(gtk.Widget).setHexpand(1);
                const line = gtk.Box.new(.horizontal, 8);
                const tile = rowTile(s, w);
                line.append(tile);
                line.append(item.as(gtk.Widget));
                const more = menuButton(windowMenu(session.id, w.id), "Window");
                more.as(gtk.Widget).addCssClass("row-more");
                line.append(more.as(gtk.Widget));
                const row = gtk.ListBoxRow.new();
                row.setChild(line.as(gtk.Widget));
                a.sidebar.append(row.as(gtk.Widget));
                a.rows.append(gpa, .{
                    .session_id = gpa.dupe(u8, session.id) catch continue,
                    .window_id = gpa.dupe(u8, w.id) catch continue,
                    .label = item,
                    .line = line,
                    .tile = tile,
                }) catch {};
            }
        }
        a.selectSidebarRow();
    }

    /// A window's row shows its focused pane: that pane's program and title, like Rex.
    fn rowTitle(a: *App, buf: []u8, w: *const view.Window, v: *const view.SessionView) [:0]const u8 {
        if (a.workspace) |ws| if (w.focused_block_id) |fb| for (ws.panes.items) |p| if (std.mem.eql(u8, p.block_id, fb)) {
            var tb: [256]u8 = undefined;
            const t = p.term.title(&tb);
            return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
        };
        if (w.title()) |t| return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
        const s = a.server orelse return windowTitle(buf, w, v);
        if (w.focused_block_id) |fb| if (s.blockInfo(fb)) |info| if (info.program) |prog| {
            var fbuf: [256]u8 = undefined;
            const name = std.mem.trimStart(u8, prog[0 .. std.mem.indexOfScalar(u8, prog, '/') orelse prog.len], "-");
            if (info.folder) |f| return std.fmt.bufPrintSentinel(buf, "{s} {s}", .{ name, @import("programs.zig").shortFolder(&fbuf, f) }, 0) catch "Window";
            return std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch "Window";
        };
        return windowTitle(buf, w, v);
    }

    /// Updates row titles and tiles in place, since block details change often.
    fn refreshRows(a: *App) void {
        const s = a.server orelse return;
        for (a.rows.items) |r| if (r) |row| {
            const v = s.sessionView(row.session_id) orelse continue;
            const w = v.window(row.window_id) orelse continue;
            var buf: [256]u8 = undefined;
            if (row.label) |l| l.setText(a.rowTitle(&buf, w, v).ptr);
            if (row.tile) |t| t.queueDraw();
        };
    }

    fn showAlert(a: *App) void {
        const s = a.server orelse return;
        const active = a.window.as(gtk.Window).isActive() != 0;
        const shown = if (a.workspace) |ws| ws.isShown(s.alert_block.items) else false;
        // Someone looking at the pane already sees it.
        if (active and shown) return;
        const text = gpa.dupeSentinel(u8, s.alert_text.items, 0) catch return;
        defer gpa.free(text);
        const n = gio.Notification.new("Compy");
        n.setBody(text.ptr);
        var tbuf: [512]u8 = undefined;
        const where = std.fmt.bufPrintSentinel(&tbuf, "{s} {s}", .{ s.alert_session.items, s.alert_block.items }, 0) catch return;
        n.setDefaultActionAndTargetValue("app.show-block", glib.Variant.newString(where.ptr));
        var ibuf: [128]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&ibuf, "block-{s}", .{s.alert_block.items}, 0) catch return;
        a.app.as(gio.Application).sendNotification(id.ptr, n);
        n.as(gobject.Object).unref();
    }

    fn showBlockAction(a: *App, session_id: []const u8, block_id: []const u8) void {
        const s = a.server orelse return;
        setSlot(&a.session_id, session_id);
        if (s.sessionView(session_id)) |v| if (v.windowOf(block_id)) |w| {
            setSlot(&a.window_id, w.id);
            s.focusWindow(session_id, w.id);
        };
        s.focusBlock(session_id, block_id);
        a.showSelected();
        a.rebuildSidebar();
        a.window.as(gtk.Window).present();
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
        if (std.mem.eql(u8, action, "client.find.open")) return a.did(openFind);
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
            .{ "toggle-sidebar", toggleSidebar, "" },
            .{ "find", openFind, "" },
            .{ "find-next", findNext, "" },
            .{ "find-prev", findPrev, "" },
            .{ "find-close", closeFind, "" },
        };
        // A pane's own buttons name the pane, which is focused first so the action acts on it.
        inline for (.{
            .{ "pane-split-right", splitRight },
            .{ "pane-split-down", splitDown },
            .{ "pane-zoom", zoomPane },
            .{ "pane-close", closePane },
            .{ "pane-float", floatPane },
        }) |e| {
            const action = gio.SimpleAction.new(e[0], glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    const block = std.mem.span(param.?.getString(null));
                    if (app.workspace) |ws| ws.focus(block);
                    e[1](app);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        {
            const action = gio.SimpleAction.new("restore-layer", glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    const layer = std.mem.span(param.?.getString(null));
                    const s = app.server orelse return;
                    const sid = app.session_id orelse return;
                    s.setLayerMinimized(sid, layer, false);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        {
            const action = gio.SimpleAction.newStateful("tight", null, glib.Variant.newBoolean(@intFromBool(config.tight())));
            const Thunk = struct {
                fn run(act: *gio.SimpleAction, _: ?*glib.Variant, app: *App) callconv(.c) void {
                    const on = !Workspace.isTight();
                    act.setState(glib.Variant.newBoolean(@intFromBool(on)));
                    app.setTight(on);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
        inline for (.{ .{ "close-window", closeWindowAction }, .{ "rename-window", renameWindowAction }, .{ "show-block", showBlockAction } }) |e| {
            const action = gio.SimpleAction.new(e[0], glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    const text = std.mem.span(param.?.getString(null));
                    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return;
                    e[1](app, text[0..space], text[space + 1 ..]);
                }
            };
            _ = gio.SimpleAction.signals.activate.connect(action, *App, &Thunk.run, a, .{});
            a.app.as(gio.ActionMap).addAction(action.as(gio.Action));
        }
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

    /// Floats a tiled pane in the middle of the window, or minimizes a floating one to the tray.
    fn floatPane(a: *App) void {
        const t = a.target() orelse return;
        const ws = a.workspace orelse return;
        const p = ws.paneOf(t[2]) orelse return;
        if (p.floating) {
            t[0].setLayerMinimized(t[1], p.layer_id, true);
        } else {
            t[0].floatBlock(t[1], t[2], .{ .x = 0.2, .y = 0.15, .w = 0.6, .h = 0.65 });
        }
    }

    pub fn setTight(a: *App, on: bool) void {
        @import("workspace.zig").setTight(on);
        config.saveTight(on);
        if (on) a.window.as(gtk.Widget).addCssClass("tight") else a.window.as(gtk.Widget).removeCssClass("tight");
        if (a.workspace) |ws| ws.root.queueAllocate();
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

    fn closeWindowAction(a: *App, session_id: []const u8, window_id: []const u8) void {
        if (a.server) |s| s.closeWindow(session_id, window_id);
    }

    fn renameWindowAction(a: *App, session_id: []const u8, window_id: []const u8) void {
        const s = a.server orelse return;
        const v = s.sessionView(session_id) orelse return;
        const w = v.window(window_id) orelse return;
        var buf: [256]u8 = undefined;
        const current = windowTitle(&buf, w, v);
        const dialog = adw.AlertDialog.new("Rename window", null);
        const entry = gtk.Entry.new();
        entry.as(gtk.Editable).setText(current.ptr);
        entry.setActivatesDefault(1);
        dialog.setExtraChild(entry.as(gtk.Widget));
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("rename", "Rename");
        dialog.setResponseAppearance("rename", .suggested);
        dialog.setDefaultResponse("rename");
        const ctx = gpa.create(RenameCtx) catch return;
        ctx.* = .{
            .app = a,
            .entry = entry,
            .session_id = gpa.dupe(u8, session_id) catch return,
            .window_id = gpa.dupe(u8, window_id) catch return,
        };
        _ = adw.AlertDialog.signals.response.connect(dialog, *RenameCtx, &renamed, ctx, .{});
        dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
    }

    const RenameCtx = struct { app: *App, entry: *gtk.Entry, session_id: []u8, window_id: []u8 };

    fn renamed(_: *adw.AlertDialog, response: [*:0]const u8, ctx: *RenameCtx) callconv(.c) void {
        defer {
            gpa.free(ctx.session_id);
            gpa.free(ctx.window_id);
            gpa.destroy(ctx);
        }
        if (!std.mem.eql(u8, std.mem.span(response), "rename")) return;
        const label = std.mem.trim(u8, std.mem.span(ctx.entry.as(gtk.Editable).getText()), " ");
        if (ctx.app.server) |s| s.renameWindow(ctx.session_id, ctx.window_id, label);
    }

    // Find.

    fn findTerm(a: *App) ?*@import("term.zig").Term {
        const ws = a.workspace orelse return null;
        const tv = ws.focusedView() orelse return null;
        return tv.term();
    }

    fn redrawFocused(a: *App) void {
        const ws = a.workspace orelse return;
        if (ws.focusedView()) |tv| tv.widget().queueDraw();
    }

    fn openFind(a: *App) void {
        a.find_bar.setRevealChild(1);
        _ = a.find_entry.as(gtk.Widget).grabFocus();
    }

    fn closeFind(a: *App) void {
        a.find_bar.setRevealChild(0);
        if (a.findTerm()) |t| t.endFind();
        a.find_count.setText("");
        a.redrawFocused();
        if (a.workspace) |ws| ws.grabFocus();
    }

    pub fn findText(a: *App, text: []const u8) void {
        const t = a.findTerm() orelse return;
        if (text.len == 0) {
            t.endFind();
            a.find_total = 0;
            a.find_count.setText("");
        } else {
            a.find_total = t.find(text);
            a.showFindCount(if (a.find_total > 0) t.findStep(true) else null);
        }
        a.redrawFocused();
    }

    fn showFindCount(a: *App, index: ?usize) void {
        var buf: [32]u8 = undefined;
        const text = if (a.find_total == 0)
            std.fmt.bufPrintSentinel(&buf, "None", .{}, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "{d} of {d}", .{ (index orelse 0) + 1, a.find_total }, 0) catch "";
        a.find_count.setText(text.ptr);
    }

    fn step(a: *App, older: bool) void {
        const t = a.findTerm() orelse return;
        if (!t.finding() or a.find_total == 0) return;
        a.showFindCount(t.findStep(older));
        a.redrawFocused();
    }

    fn findNext(a: *App) void {
        a.step(true);
    }

    fn findPrev(a: *App) void {
        a.step(false);
    }

    fn findChanged(entry: *gtk.SearchEntry, a: *App) callconv(.c) void {
        a.findText(std.mem.span(entry.as(gtk.Editable).getText()));
    }

    fn findNextSignal(_: *gtk.SearchEntry, a: *App) callconv(.c) void {
        a.findNext();
    }

    fn findPrevSignal(_: *gtk.SearchEntry, a: *App) callconv(.c) void {
        a.findPrev();
    }

    fn findStopSignal(_: *gtk.SearchEntry, a: *App) callconv(.c) void {
        a.closeFind();
    }

    fn toggleSidebar(a: *App) void {
        a.split.setShowSidebar(@intFromBool(a.split.getShowSidebar() == 0));
    }

    fn changeServer(a: *App) void {
        a.stack.setVisibleChildName("connect");
    }
};

fn appMenu() *gio.MenuModel {
    const menu = gio.Menu.new();
    const panes = gio.Menu.new();
    panes.append("Split right", "app.split-right");
    panes.append("Split down", "app.split-down");
    panes.append("Zoom pane", "app.zoom-pane");
    panes.append("Close pane", "app.close-pane");
    menu.appendSection(null, panes.as(gio.MenuModel));
    const other = gio.Menu.new();
    other.append("Find…", "app.find");
    other.append("Tight layout", "app.tight");
    other.append("New window", "app.new-window");
    other.append("New session", "app.new-session");
    other.append("Change server…", "app.change-server");
    menu.appendSection(null, other.as(gio.MenuModel));
    return menu.as(gio.MenuModel);
}

/// The "•••" menu on a window's row. Its actions carry "session window" as their target.
fn windowMenu(session_id: []const u8, window_id: []const u8) *gio.MenuModel {
    var buf: [512]u8 = undefined;
    const target = std.fmt.bufPrintSentinel(&buf, "{s} {s}", .{ session_id, window_id }, 0) catch "";
    const menu = gio.Menu.new();
    inline for (.{ .{ "Rename…", "app.rename-window" }, .{ "Close window", "app.close-window" } }) |e| {
        const item = gio.MenuItem.new(e[0], null);
        item.setActionAndTargetValue(e[1], glib.Variant.newString(target.ptr));
        menu.appendItem(item);
    }
    return menu.as(gio.MenuModel);
}

fn menuButton(model: *gio.MenuModel, tooltip: [:0]const u8) *gtk.MenuButton {
    const button = gtk.MenuButton.new();
    button.setChild(icons.image(.more, 16));
    button.setMenuModel(model);
    button.as(gtk.Widget).setTooltipText(tooltip.ptr);
    button.as(gtk.Widget).addCssClass("icon-button");
    button.as(gtk.Widget).addCssClass("flat");
    button.as(gtk.Widget).setValign(.center);
    return button;
}

/// The tile for a window's row: its focused pane's program.
fn rowTile(s: *Server, w: *const view.Window) *gtk.Widget {
    const block = w.focused_block_id orelse (if (w.layers.len > 0 and w.layers[0].blocks.len > 0) w.layers[0].blocks[0].id else "");
    var ids: [64][]const u8 = undefined;
    var n: usize = 0;
    for (w.layers) |l| for (l.blocks) |b| if (n < ids.len) {
        ids[n] = b.id;
        n += 1;
    };
    return @import("blockicon.zig").createFor(s, block, ids[0..n], 16);
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
    shot_app = a;
    if (std.c.getenv("COMPY_SHOT") != null) _ = @import("glibunix").signalAdd(@intFromEnum(std.posix.SIG.USR1), &takeShot, null);
    if (std.c.getenv("COMPY_SCRIPT") != null) _ = @import("glibunix").signalAdd(@intFromEnum(std.posix.SIG.USR2), &runScript, null);
}

/// Development: SIGUSR2 runs the commands in $COMPY_SCRIPT against the focused pane, so
/// selection and find can be checked without a mouse. One command per line:
/// `find TEXT`, `select X1 Y1 X2 Y2`, `word X Y`, `copy`, `type TEXT`, `close-find`.
fn runScript(_: ?*anyopaque) callconv(.c) c_int {
    const a = shot_app orelse return 1;
    const path = std.c.getenv("COMPY_SCRIPT") orelse return 1;
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(path, &contents, &len, null) == 0) return 1;
    defer glib.free(contents);
    const ws = a.workspace orelse return 1;
    var lines = std.mem.splitScalar(u8, contents[0..len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;
        const rest = std.mem.trim(u8, line[cmd.len..], " ");
        const tv = ws.focusedView() orelse {
            std.log.info("script: no pane for {s}", .{cmd});
            continue;
        };
        const t = tv.term() orelse {
            std.log.info("script: no terminal for {s}", .{cmd});
            continue;
        };
        std.log.info("script: {s}", .{cmd});
        if (std.mem.eql(u8, cmd, "action")) {
            const name = it.next() orelse continue;
            const z = gpa.dupeSentinel(u8, name, 0) catch continue;
            defer gpa.free(z);
            const param: ?*glib.Variant = if (it.next()) |arg| blk: {
                const za = gpa.dupeSentinel(u8, arg, 0) catch continue;
                defer gpa.free(za);
                break :blk glib.Variant.newString(za.ptr);
            } else if (std.mem.startsWith(u8, name, "pane-")) glib.Variant.newString(@ptrCast((gpa.dupeSentinel(u8, tv.block_id, 0) catch continue).ptr)) else null;
            a.app.as(gio.ActionGroup).activateAction(z.ptr, param);
        } else if (std.mem.eql(u8, cmd, "carry")) {
            const x = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const y = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            ws.simulateCarry(tv.block_id, x, y);
        } else if (std.mem.eql(u8, cmd, "drop")) {
            ws.simulateDrop();
        } else if (std.mem.eql(u8, cmd, "divider")) {
            const dx = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            ws.simulateDivider(dx);
        } else if (std.mem.eql(u8, cmd, "find")) {
            a.openFind();
            const z = gpa.dupeSentinel(u8, rest, 0) catch continue;
            defer gpa.free(z);
            a.find_entry.as(gtk.Editable).setText(z.ptr);
        } else if (std.mem.eql(u8, cmd, "close-find")) {
            a.closeFind();
        } else if (std.mem.eql(u8, cmd, "select")) {
            var n: [4]u16 = .{ 0, 0, 0, 0 };
            for (&n) |*v| v.* = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            t.selectRange(n[0], n[1], n[2], n[3]);
        } else if (std.mem.eql(u8, cmd, "word")) {
            const x = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            t.selectWord(x, y);
        } else if (std.mem.eql(u8, cmd, "copy")) {
            tv.copySelection(false);
        } else if (std.mem.eql(u8, cmd, "type")) {
            const view_ = std.unicode.Utf8View.init(rest) catch continue;
            var cps = view_.iterator();
            while (cps.nextCodepoint()) |cp| a.server.?.sendKey(tv.session_id, tv.block_id, @import("keys.zig").forChar(cp, 0));
            a.server.?.sendKey(tv.session_id, tv.block_id, @import("keys.zig").fromGdk(0xff0d, 0, 0).?);
        }
        tv.widget().queueDraw();
    }
    return 1;
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
