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
const settings = @import("settings.zig");
const themes = @import("themes.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const Palette = @import("palette.zig").Palette;

const gpa = std.heap.c_allocator;

const css =
    \\window.compy, window.compy .sidebar-pane { background-color: @compy_shell; }
    \\*, *:focus-visible, *:focus-within { outline: none; outline-width: 0; }
    \\.carry-ghost { background-color: mix(@view_bg_color, @window_fg_color, 0.1); border: 1.5px solid alpha(@accent_bg_color, 0.9); border-radius: 10px; box-shadow: 0 5px 18px alpha(black, 0.35); }
    \\.copied-chip { opacity: 0; transform: translateY(-6px) scale(0.92); transition: opacity 180ms ease-out, transform 240ms cubic-bezier(0.2, 0.9, 0.3, 1.2); background-color: @accent_bg_color; color: @accent_fg_color; border-radius: 99px; padding: 3px 11px; font-size: 0.85em; font-weight: 600; box-shadow: 0 3px 12px alpha(black, 0.3); }
    \\.copied-chip.shown { opacity: 1; transform: none; }
    \\.font-preview { padding: 12px 14px; }
    \\.drop-target { background-color: alpha(@accent_bg_color, 0.16); border: 1.5px solid alpha(@accent_bg_color, 0.8); border-radius: 9px; color: @accent_color; }
    \\.compy-sidebar headerbar { background: none; box-shadow: none; min-height: 52px; padding: 0 6px; }
    \\.compy-sidebar list { background: none; padding: 2px 8px 8px 8px; }
    \\.compy-sidebar list > row { border-radius: 9px; min-height: 34px; padding: 3px 4px 3px 10px; margin: 1px 0; }
    \\.compy-sidebar list > row:selected { background-color: alpha(@window_fg_color, 0.09); }
    \\.compy-sidebar list > row:hover:not(:selected):not(.session-row):not(.host-row) { background-color: alpha(@window_fg_color, 0.04); }
    \\.compy-sidebar .row-title { font-size: 0.95em; }
    \\.row-more { opacity: 0; }
    \\row:hover .row-more, row:selected .row-more { opacity: 0.6; }
    \\.session-heading { font-size: 0.82em; color: @compy_secondary; }
    \\.compy-sidebar list > row.session-row { min-height: 28px; margin-top: 12px; padding: 0 2px 0 10px; background: none; }
    \\.compy-sidebar list > row.host-row { min-height: 26px; margin-top: 18px; padding: 0 10px; background: none; }
    \\.compy-sidebar list > row.host-row:first-child { margin-top: 4px; }
    \\.host-heading { font-weight: 700; font-size: 0.88em; }
    \\.session-tool { opacity: 0; min-width: 24px; min-height: 24px; }
    \\row.session-row:hover .session-tool, .session-tool.folded { opacity: 0.6; }
    \\row.session-row .session-tool:hover { opacity: 1; }
    \\.sidebar-footer { padding: 8px 12px 12px 12px; }
    \\.sidebar-footer > * { margin-left: 2px; }
    \\.filter-pill { border-radius: 99px; min-height: 30px; padding: 0 8px; }
    \\.filter-pill.filtered { padding: 0 14px 0 9px; background-color: alpha(@window_fg_color, 0.08); }
    \\.window-card.alone { margin-left: 8px; }
    \\.content .workspace { margin: 6px 8px 8px 0; }
    \\.content.alone .workspace { margin: 6px 8px 8px 8px; }
    \\window.no-headers .content.alone .workspace { margin-top: 52px; }
    \\window.tight .content.alone .workspace { margin: 7px 0 0 0; }
    \\.window-corner { min-height: 52px; padding: 0 6px 0 12px; }
    \\.pane-card { background-color: @view_bg_color; border-radius: 11px; border: 1px solid @compy_stroke_subtle; }
    \\.pane-card.focused { border-color: alpha(@accent_bg_color, 0.85); box-shadow: 0 0 0 1px alpha(@accent_bg_color, 0.35); }
    \\.pane-card.floating { box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.pane-card.floating.focused { box-shadow: 0 0 0 1px alpha(@accent_bg_color, 0.35), 0 8px 28px alpha(black, 0.45); }
    \\.layer-card { background-color: @compy_stroke_subtle; border: 1px solid @compy_stroke_subtle; border-radius: 11px; box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.layer-card.focused { border-color: alpha(@accent_bg_color, 0.85); }
    \\.pane-card.joined, .pane-card.joined.floating, .pane-card.joined.focused, .pane-card.joined.floating.focused { border: none; border-radius: 0; box-shadow: none; }
    \\.pane-card.joined.c-tl { border-top-left-radius: 10px; }
    \\.pane-card.joined.c-tr { border-top-right-radius: 10px; }
    \\.pane-card.joined.c-bl { border-bottom-left-radius: 10px; }
    \\.pane-card.joined.c-br { border-bottom-right-radius: 10px; }
    \\.pane-card.joined.focused .pane-title .title { color: @accent_color; }
    \\.pane-title { min-height: 38px; padding: 0 6px 0 12px; }
    \\.pane-tools > * { margin-left: 2px; }
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
    \\.tray-chip { transition: background-color 140ms ease-out, box-shadow 140ms ease-out; }
    \\.tray-chip:hover { background-color: mix(@popover_bg_color, @window_fg_color, 0.1); box-shadow: 0 4px 16px alpha(black, 0.38); }
    \\.tray-chip:active { background-color: mix(@popover_bg_color, @window_fg_color, 0.16); }
    \\window.tight .content .workspace { margin: 7px 0 0 0; }
    \\window.tight .pane-card { border-radius: 0; border: none; box-shadow: none; }
    \\window.tight .workspace { background-color: @compy_stroke_subtle; }
    \\window.tight .pane-card.focused .pane-title .title { color: @accent_color; }
    \\window.tight .pane-card.floating { border: 1px solid @compy_stroke; border-radius: 8px; box-shadow: 0 8px 28px alpha(black, 0.45); }
    \\.palette { padding: 12px; }
    \\.palette-category { color: @compy_secondary; font-size: 0.85em; }
    \\.palette-keys { font-family: monospace; font-size: 0.85em; color: @compy_secondary; background-color: alpha(@window_fg_color, 0.07); border-radius: 5px; padding: 1px 6px; }
    \\.mode-chip { background-color: @accent_bg_color; color: @accent_fg_color; font-weight: 700; font-size: 0.85em; border-radius: 99px; padding: 6px 16px; box-shadow: 0 4px 16px alpha(black, 0.35); }
    \\.connect-box { margin: 0 24px; }
;

const Row = struct { host: *Host, session_id: []u8, window_id: []u8, label: ?*gtk.Label = null, line: ?*gtk.Box = null, tile: ?*gtk.Widget = null };

/// One Rex server Compy is connected to, with its own workspace page.
pub const Host = struct {
    app: *App,
    label: []u8,
    server: *Server,
    workspace: *Workspace,
    page: [:0]u8,
    /// Set for a host from $COMPY_SERVER, which isn't saved.
    temporary: bool = false,
};

pub const App = struct {
    app: *adw.Application,
    window: *adw.ApplicationWindow = undefined,
    toasts: *adw.ToastOverlay = undefined,
    sidebar: *gtk.ListBox = undefined,
    split: *adw.OverlaySplitView = undefined,
    card: *gtk.Widget = undefined,
    corner: *gtk.Widget = undefined,
    corner_tick: c_uint = 0,
    corner_until: i64 = 0,
    stack: *gtk.Stack = undefined,
    status: *adw.StatusPage = undefined,
    retry_button: *gtk.Button = undefined,
    find_bar: *gtk.Revealer = undefined,
    find_entry: *gtk.SearchEntry = undefined,
    find_count: *gtk.Label = undefined,
    find_total: usize = 0,
    entry: *gtk.Entry = undefined,
    /// The host whose session is shown; `server` and `workspace` are its.
    server: ?*Server = null,
    workspace: ?*Workspace = null,
    current: ?*Host = null,
    hosts: std.ArrayList(*Host) = .empty,
    /// The host the sidebar is narrowed to, or null for all of them.
    filter: ?*Host = null,
    next_page: usize = 0,
    filter_button: *gtk.MenuButton = undefined,
    filter_label: *gtk.Label = undefined,
    filter_menu: *gio.Menu = undefined,
    mode_chip: *gtk.Label = undefined,
    /// A pane being floated so it can be minimized.
    minimize_next: ?[]u8 = null,
    rows: std.ArrayList(?Row) = .empty,
    /// Sessions whose windows are folded away in the sidebar.
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    /// The window the person is looking at, which may differ from the session's active one.
    session_id: ?[]u8 = null,
    window_id: ?[]u8 = null,
    rebuilding: bool = false,
    was_online: bool = false,
    /// The shown session was chosen by the app, not the person.
    auto_picked: bool = false,
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
        settings.load();
        termview.font = termview.Font.init(gpa.dupeSentinel(u8, if (std.c.getenv("COMPY_FONT")) |f| std.mem.span(f) else settings.current.font, 0) catch "Monospace 11");
        const provider = gtk.CssProvider.new();
        provider.loadFromString(css);
        gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        a.applyTheme();
        useAppIcon();
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
        // The window controls and the sidebar toggle sit in a fixed corner above everything, so the
        // toggle never moves; the sidebar header leaves room for it, and so does the top-left pane
        // while the sidebar is hidden.
        const corner_size = gtk.SizeGroup.new(.horizontal);
        const corner = gtk.Box.new(.horizontal, 4);
        corner.as(gtk.Widget).addCssClass("window-corner");
        // The window's buttons sit in the corner with the sidebar toggle, like Rex's: the desktop's
        // own buttons, in its order, all moved to the left.
        const controls = gtk.WindowControls.new(.start);
        controls.setDecorationLayout(cornerLayout().ptr);
        controls.as(gtk.Widget).addCssClass("corner-controls");
        corner.append(controls.as(gtk.Widget));
        corner.append(icons.button(.sidebar, "Toggle sidebar", "app.toggle-sidebar").as(gtk.Widget));
        corner.as(gtk.Widget).setHalign(.start);
        corner.as(gtk.Widget).setValign(.start);
        corner_size.addWidget(corner.as(gtk.Widget));
        const side_header = adw.HeaderBar.new();
        side_header.setShowTitle(0);
        side_header.setShowStartTitleButtons(0);
        const header_room = gtk.Box.new(.horizontal, 0);
        corner_size.addWidget(header_room.as(gtk.Widget));
        side_header.packStart(header_room.as(gtk.Widget));
        side_header.packEnd(menuButton(appMenu(), "More").as(gtk.Widget));
        side_header.packEnd(icons.button(.search, "Commands", "app.palette").as(gtk.Widget));
        // The footer, like Rex's: narrow the sidebar to one host, a new session, and another host.
        const footer = gtk.Box.new(.horizontal, 2);
        footer.as(gtk.Widget).addCssClass("sidebar-footer");
        a.filter_button = gtk.MenuButton.new();
        const pill = gtk.Box.new(.horizontal, 6);
        pill.append(icons.image(.filter, 16));
        a.filter_label = gtk.Label.new("Filter");
        pill.append(a.filter_label.as(gtk.Widget));
        a.filter_button.setChild(pill.as(gtk.Widget));
        a.filter_button.as(gtk.Widget).addCssClass("filter-pill");
        a.filter_button.as(gtk.Widget).setTooltipText("Show one host or all of them");
        a.filter_menu = gio.Menu.new();
        a.filter_button.setMenuModel(a.filter_menu.as(gio.MenuModel));
        footer.append(a.filter_button.as(gtk.Widget));
        const spacer = gtk.Box.new(.horizontal, 0);
        spacer.as(gtk.Widget).setHexpand(1);
        footer.append(spacer.as(gtk.Widget));
        footer.append(icons.button(.new_session, "New session", "app.new-session").as(gtk.Widget));
        footer.append(icons.button(.add_host, "Add remote host", "app.add-host").as(gtk.Widget));
        const side = adw.ToolbarView.new();
        side.as(gtk.Widget).addCssClass("compy-sidebar");
        side.addTopBar(side_header.as(gtk.Widget));
        side.addBottomBar(footer.as(gtk.Widget));
        side.setContent(scroller.as(gtk.Widget));

        // Content: the panes, each its own card, on the window's background. While the sidebar is
        // hidden, the top-left pane's title makes room for the corner.
        a.corner = corner.as(gtk.Widget);
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
        const layered = gtk.Overlay.new();
        layered.setChild(split.as(gtk.Widget));
        layered.addOverlay(corner.as(gtk.Widget));
        // Which Rex key mode is on, such as resize, while one is.
        a.mode_chip = gtk.Label.new("");
        a.mode_chip.as(gtk.Widget).addCssClass("mode-chip");
        a.mode_chip.as(gtk.Widget).setHalign(.center);
        a.mode_chip.as(gtk.Widget).setValign(.end);
        a.mode_chip.as(gtk.Widget).setMarginBottom(18);
        a.mode_chip.as(gtk.Widget).setVisible(0);
        a.mode_chip.as(gtk.Widget).setCanTarget(0);
        layered.addOverlay(a.mode_chip.as(gtk.Widget));
        mode_app = a;
        termview.on_mode_changed = modeChanged;
        termview.on_chord_changed = chordChanged;
        termview.TermView.enablePerfLog();
        a.toasts.setChild(layered.as(gtk.Widget));
        a.window.setContent(a.toasts.as(gtk.Widget));

        a.addActions();
        a.setTight(settings.current.tight);
        themes.active = themes.resolve(settings.current.theme);
        @import("workspace.zig").show_headers = settings.current.show_headers;
        a.markHeaders();
        _ = glib.timeoutAdd(530, &blinkTick, a);
        installShotHook(a);

        // $COMPY_SERVER, for testing, names hosts to use without saving them, separated by commas.
        if (std.c.getenv("COMPY_SERVER")) |env| {
            var it = std.mem.tokenizeScalar(u8, std.mem.span(env), ',');
            while (it.next()) |url| if (a.addHost(settings.labelFor(url), url)) |h| {
                h.temporary = true;
            };
        } else for (settings.current.hosts.items) |h| _ = a.addHost(h.label, h.url);
        if (a.hosts.items.len == 0) a.stack.setVisibleChildName("connect");
        // When driven by tests, show the window without taking the keyboard from what the person
        // is using; otherwise their typing lands in Compy.
        if (std.c.getenv("COMPY_SHOT") != null) win.as(gtk.Widget).setVisible(1) else win.present();
    }

    /// The desktop's button layout with every button on the left, such as "close" from GNOME's
    /// "appmenu:close".
    fn cornerLayout() [:0]const u8 {
        const S = struct {
            var buf: [128]u8 = undefined;
        };
        var value: ?[*:0]u8 = null;
        if (gtk.Settings.getDefault()) |gs| gobject.Object.get(gs.as(gobject.Object), "gtk-decoration-layout", &value, @as(?*anyopaque, null));
        const raw = if (value) |v| std.mem.span(v) else "close,minimize,maximize";
        defer if (value) |v| glib.free(v);
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, raw, ",:");
        while (it.next()) |b| {
            // The app menu and icon have no place in the corner.
            if (std.mem.eql(u8, b, "appmenu") or std.mem.eql(u8, b, "icon")) continue;
            if (n + b.len + 2 >= S.buf.len) break;
            if (n > 0) {
                S.buf[n] = ',';
                n += 1;
            }
            @memcpy(S.buf[n .. n + b.len], b);
            n += b.len;
        }
        S.buf[n] = ':';
        S.buf[n + 1] = 0;
        return S.buf[0 .. n + 1 :0];
    }

    fn sidebarShown(split: *adw.OverlaySplitView, _: *gobject.ParamSpec, a: *App) callconv(.c) void {
        const shown = split.getShowSidebar() != 0;
        if (shown) a.card.removeCssClass("alone") else a.card.addCssClass("alone");
        a.cornerChanged();
    }

    /// Tells the panes how much of their top-left the corner covers.
    fn cornerChanged(a: *App) void {
        @import("workspace.zig").corner_right = @floatFromInt(a.corner.getWidth());
        if (a.workspace) |ws| ws.cornerChanged();
        // The sidebar slides in or out over a few frames; the title follows it on each one.
        a.corner_until = glib.getMonotonicTime() + 600_000;
        if (a.corner_tick == 0) a.corner_tick = a.window.as(gtk.Widget).addTickCallback(&cornerTick, a, null);
    }

    fn cornerTick(_: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.?));
        if (a.workspace) |ws| ws.cornerChanged();
        if (glib.getMonotonicTime() < a.corner_until) return 1;
        a.corner_tick = 0;
        return 0;
    }

    fn connectPage(a: *App) *gtk.Widget {
        const page = adw.StatusPage.new();
        
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
        settings.addHost(settings.labelFor(url), url);
        if (a.addHost(settings.labelFor(url), url)) |h| a.selectHost(h);
    }

    /// Connects to another Rex server. Its sessions join the sidebar under its name.
    pub fn addHost(a: *App, label: []const u8, url: []const u8) ?*Host {
        if (a.hasHostUrl(url)) {
            for (a.hosts.items) |x| if (std.mem.eql(u8, x.server.url, std.mem.trimEnd(u8, url, "/"))) return x;
        }
        const s = Server.create(url, clientLabel()) catch return null;
        const ws = Workspace.create(s) catch return null;
        const h = gpa.create(Host) catch return null;
        h.* = .{
            .app = a,
            .label = gpa.dupe(u8, label) catch return null,
            .server = s,
            .workspace = ws,
            .page = std.fmt.allocPrintSentinel(gpa, "host-{d}", .{a.next_page}, 0) catch return null,
        };
        a.next_page += 1;
        s.observer = .{ .ctx = h, .changed = serverChanged };
        s.performer = .{ .ctx = h, .perform = perform };
        _ = a.stack.addNamed(ws.root, h.page.ptr);
        a.hosts.append(gpa, h) catch return null;
        if (a.current == null) a.selectHost(h);
        a.rebuildSidebar();
        return h;
    }

    pub fn removeHost(a: *App, h: *Host) void {
        for (a.hosts.items, 0..) |x, i| if (x == h) {
            _ = a.hosts.orderedRemove(i);
            break;
        };
        if (a.filter == h) a.filter = null;
        h.workspace.clear();
        a.stack.remove(h.workspace.root);
        h.server.destroy();
        if (a.current == h) {
            a.current = null;
            a.server = null;
            a.workspace = null;
            setSlot(&a.session_id, null);
            setSlot(&a.window_id, null);
            if (a.hosts.items.len > 0) a.selectHost(a.hosts.items[0]) else a.stack.setVisibleChildName("connect");
        }
        gpa.free(h.label);
        gpa.free(h.page);
        gpa.destroy(h);
        a.rebuildSidebar();
    }

    /// Shows a host's sessions in the content area.
    fn selectHost(a: *App, h: *Host) void {
        if (a.current == h) return;
        a.current = h;
        a.server = h.server;
        a.workspace = h.workspace;
        a.was_online = false;
        a.theme_for = null;
        setSlot(&a.session_id, null);
        setSlot(&a.window_id, null);
        a.applyTheme();
        a.showState();
        a.ensureSelection();
    }

    fn hostOf(a: *App, s: *Server) ?*Host {
        for (a.hosts.items) |h| if (h.server == s) return h;
        return null;
    }

    // Following the server.

    fn serverChanged(ctx: *anyopaque, what: server_mod.Change, session_id: ?[]const u8) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const a = h.app;
        const here = a.current == h;
        switch (what) {
            .state => {
                if (here) {
                    a.applyTheme();
                    a.showState();
                }
                a.rebuildSidebar();
            },
            .sessions => {
                if (here) a.ensureSelection();
                a.rebuildSidebar();
            },
            .view => {
                if (here) a.ensureSelection();
                a.rebuildSidebar();
                if (here) if (a.session_id) |sel| if (session_id) |sid| if (std.mem.eql(u8, sel, sid)) {
                    a.showSelected();
                    a.finishMinimize();
                };
            },
            .block => {
                const block = session_id orelse return;
                h.workspace.blockChanged(block);
                a.refreshRows();
            },
            .alert => a.showAlert(h),
            .keymap => {},
            .hosts => a.importListedHosts(h),
            .bell => if (here) if (session_id) |b| if (h.workspace.paneOf(b)) |p| p.term.flash(),
            .clipboard => {
                const z = gpa.dupeSentinel(u8, h.server.clipboard_text.items, 0) catch return;
                defer gpa.free(z);
                a.window.as(gtk.Widget).getClipboard().setText(z.ptr);
            },
            .message => {
                const s = h.server;
                const text = gpa.dupeSentinel(u8, s.message.items, 0) catch return;
                defer gpa.free(text);
                a.toasts.addToast(adw.Toast.new(text.ptr));
            },
        }
    }

    /// Colors the whole window from the host's terminal theme, once it is known.
    pub fn applyTheme(a: *App) void {
        const host = if (a.server) |s| s.host_colors else null;
        const colors = themes.active orelse host;
        if (a.theme_css != null) {
            if (colors == null) return;
            if (a.theme_for) |old| if (std.meta.eql(old, colors.?)) return;
        }
        a.theme_for = colors;
        // A forced scheme that the theme doesn't match uses a plain palette of that brightness.
        var source = colors orelse @import("stream.zig").Colors{};
        const theme_dark = theme.Palette.from(source).dark;
        switch (settings.current.color_scheme) {
            .auto => {},
            .dark => if (!theme_dark) {
                source = .{};
            },
            .light => if (theme_dark) {
                source = .{ .bg = 0xFFF7F7F5, .fg = 0xFF2C2C2E, .cursor = 0xFF3366CC };
            },
        }
        const palette = theme.Palette.from(source);
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
                if (a.current) |h| a.stack.setVisibleChildName(h.page.ptr);
                if (!a.was_online) if (a.workspace) |w| w.resendSizes();
                a.was_online = true;
            },
            .connecting => if (!a.was_online) {
                a.status.setIconName(null);
                a.status.setTitle("Connecting…");
                a.status.setDescription(null);
                a.retry_button.as(gtk.Widget).setVisible(0);
                a.stack.setVisibleChildName("status");
            },
            .offline => {
                a.was_online = false;
                const reason = gpa.dupeSentinel(u8, s.reason.items, 0) catch return;
                defer gpa.free(reason);
                a.status.setIconName(null);
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
            // A session the app chose itself gives way once another turns out to have windows.
            const empty = if (s.sessionView(sel)) |v| v.windows.len == 0 else true;
            if (found and !(a.auto_picked and empty and a.firstWithWindows(s) != null)) {
                if (s.sessionView(sel)) |v| {
                    if (a.window_id) |wid| if (v.window(wid) == null) setSlot(&a.window_id, null);
                }
                return;
            }
            setSlot(&a.session_id, null);
            setSlot(&a.window_id, null);
        }
        if (s.sessions.items.len == 0) return;
        setSlot(&a.session_id, a.firstWithWindows(s) orelse s.sessions.items[0].id);
        a.auto_picked = true;
        a.showSelected();
    }

    fn firstWithWindows(_: *App, s: *Server) ?[]const u8 {
        for (s.sessions.items) |session| if (s.sessionView(session.id)) |v| {
            if (v.windows.len > 0) return session.id;
        };
        return null;
    }

    fn clientLabel() []const u8 {
        if (settings.current.client_label.len > 0) return settings.current.client_label;
        return std.mem.span(glib.getHostName());
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
        a.rebuilding = true;
        defer a.rebuilding = false;
        a.sidebar.removeAll();
        for (a.rows.items) |r| if (r) |row| {
            gpa.free(row.session_id);
            gpa.free(row.window_id);
        };
        a.rows.clearRetainingCapacity();
        a.rebuildFilterMenu();
        const several = a.hosts.items.len > 1 and a.filter == null;
        for (a.hosts.items) |h| {
            if (a.filter) |f| if (f != h) continue;
            if (several) a.addHostHeading(h);
            a.addSessions(h);
        }
        a.selectSidebarRow();
    }

    fn rebuildFilterMenu(a: *App) void {
        a.filter_menu.removeAll();
        const all = gio.MenuItem.new(if (a.filter == null) "All hosts  ✓" else "All hosts", null);
        all.setActionAndTargetValue("app.filter", glib.Variant.newString(""));
        a.filter_menu.appendItem(all);
        for (a.hosts.items) |h| {
            var buf: [160]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ h.label, if (a.filter == h) "  ✓" else "" }, 0) catch continue;
            const item = gio.MenuItem.new(text.ptr, null);
            item.setActionAndTargetValue("app.filter", glib.Variant.newString(h.page.ptr));
            a.filter_menu.appendItem(item);
        }
        // Just the icon until a host is picked; then its name, so the narrowing is plain to see.
        if (a.filter) |f| {
            const z = gpa.dupeSentinel(u8, f.label, 0) catch return;
            defer gpa.free(z);
            a.filter_label.setText(z.ptr);
            a.filter_label.as(gtk.Widget).setVisible(1);
            a.filter_button.as(gtk.Widget).addCssClass("filtered");
        } else {
            a.filter_label.as(gtk.Widget).setVisible(0);
            a.filter_button.as(gtk.Widget).removeCssClass("filtered");
        }
    }

    fn filterAction(a: *App, page_name: []const u8) void {
        a.filter = null;
        for (a.hosts.items) |h| if (std.mem.eql(u8, h.page, page_name)) {
            a.filter = h;
            a.selectHost(h);
        };
        a.rebuildSidebar();
    }

    /// Adds the hosts a server listed that Compy doesn't have yet.
    pub fn importListedHosts(a: *App, h: *Host) void {
        var added: usize = 0;
        for (h.server.listed_hosts) |lh| {
            if (a.hasHostUrl(lh.url)) continue;
            settings.addHost(lh.label, lh.url);
            _ = a.addHost(lh.label, lh.url);
            added += 1;
        }
        var buf: [96]u8 = undefined;
        const text = if (added == 0)
            std.fmt.bufPrintSentinel(&buf, "No new hosts on {s}", .{h.label}, 0) catch return
        else
            std.fmt.bufPrintSentinel(&buf, "Added {d} host{s} from {s}", .{ added, if (added == 1) "" else "s", h.label }, 0) catch return;
        a.toasts.addToast(adw.Toast.new(text.ptr));
    }

    pub fn hasHostUrl(a: *App, url: []const u8) bool {
        const want = std.mem.trimEnd(u8, url, "/");
        for (a.hosts.items) |x| if (std.mem.eql(u8, x.server.url, want)) return true;
        return false;
    }

    /// Asks for a Rex server's address, saves it, and connects. Rex devices on this computer's
    /// tailnet are offered with one click, and an address on the clipboard is filled in.
    fn addHostDialog(a: *App) void {
        const dialog = adw.AlertDialog.new("Add Remote Host", "A Rex HTTP or HTTPS address, such as the one Rex's Pair button shows");
        const box = gtk.Box.new(.vertical, 8);
        const url = gtk.Entry.new();
        url.setPlaceholderText("https://my-mac-rex.tailnet.ts.net");
        url.setActivatesDefault(1);
        const name = gtk.Entry.new();
        name.setPlaceholderText("Name (optional)");
        name.setActivatesDefault(1);
        box.append(url.as(gtk.Widget));
        box.append(name.as(gtk.Widget));
        var ts = @import("tailscale.zig").read();
        defer ts.deinit();
        var offered: usize = 0;
        for (ts.rex_hosts.items) |peer| {
            if (a.hasHostUrl(peer.url)) continue;
            if (offered == 0) {
                const heading = gtk.Label.new("On your tailnet");
                heading.setXalign(0);
                heading.as(gtk.Widget).addCssClass("dim-label");
                heading.as(gtk.Widget).setMarginTop(8);
                box.append(heading.as(gtk.Widget));
            }
            offered += 1;
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ peer.name, if (peer.online) "" else " (offline)" }, 0) catch continue;
            const b = gtk.Button.newWithLabel(text.ptr);
            b.as(gtk.Widget).addCssClass("flat");
            const pick = gpa.create(TailnetPick) catch continue;
            pick.* = .{ .entry = url, .name = name, .url = gpa.dupeSentinel(u8, peer.url, 0) catch continue, .label = gpa.dupeSentinel(u8, peer.name, 0) catch continue };
            _ = gtk.Button.signals.clicked.connect(b, *TailnetPick, &tailnetPicked, pick, .{});
            box.append(b.as(gtk.Widget));
        }
        // An address copied from Rex's Pair screen is likely what's wanted.
        a.window.as(gtk.Widget).getClipboard().readTextAsync(null, &clipboardForUrl, url);
        dialog.setExtraChild(box.as(gtk.Widget));
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("add", "Add");
        dialog.setResponseAppearance("add", .suggested);
        dialog.setDefaultResponse("add");
        const ctx = gpa.create(AddHostCtx) catch return;
        ctx.* = .{ .app = a, .url = url, .name = name };
        _ = adw.AlertDialog.signals.response.connect(dialog, *AddHostCtx, &hostAdded, ctx, .{});
        dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
    }

    const AddHostCtx = struct { app: *App, url: *gtk.Entry, name: *gtk.Entry };

    const TailnetPick = struct { entry: *gtk.Entry, name: *gtk.Entry, url: [:0]u8, label: [:0]u8 };

    fn tailnetPicked(_: *gtk.Button, p: *TailnetPick) callconv(.c) void {
        p.entry.as(gtk.Editable).setText(p.url.ptr);
        p.name.as(gtk.Editable).setText(p.label.ptr);
    }

    fn clipboardForUrl(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const entry: *gtk.Entry = @ptrCast(@alignCast(data.?));
        const clipboard: *gdk.Clipboard = @ptrCast(source orelse return);
        const text = clipboard.readTextFinish(result, null) orelse return;
        defer glib.free(text);
        const t = std.mem.span(text);
        if (!@import("tailscale.zig").looksLikeAddress(t)) return;
        if (std.mem.span(entry.as(gtk.Editable).getText()).len > 0) return;
        const trimmed = gpa.dupeSentinel(u8, std.mem.trim(u8, t, " \n\r\t"), 0) catch return;
        defer gpa.free(trimmed);
        entry.as(gtk.Editable).setText(trimmed.ptr);
    }

    fn hostAdded(_: *adw.AlertDialog, response: [*:0]const u8, ctx: *AddHostCtx) callconv(.c) void {
        defer gpa.destroy(ctx);
        if (!std.mem.eql(u8, std.mem.span(response), "add")) return;
        const raw = std.mem.trim(u8, std.mem.span(ctx.url.as(gtk.Editable).getText()), " ");
        if (raw.len == 0) return;
        const url = if (std.mem.indexOf(u8, raw, "://") == null)
            std.fmt.allocPrint(gpa, "http://{s}", .{raw}) catch return
        else
            gpa.dupe(u8, raw) catch return;
        defer gpa.free(url);
        const typed = std.mem.trim(u8, std.mem.span(ctx.name.as(gtk.Editable).getText()), " ");
        const label = if (typed.len > 0) typed else settings.labelFor(url);
        settings.addHost(label, url);
        if (ctx.app.addHost(label, url)) |h| ctx.app.selectHost(h);
    }

    /// A host's name, with how its connection is doing when it isn't connected.
    fn addHostHeading(a: *App, h: *Host) void {
        var buf: [160]u8 = undefined;
        const text = switch (h.server.state) {
            .online => std.fmt.bufPrintSentinel(&buf, "{s}", .{h.label}, 0),
            .connecting => std.fmt.bufPrintSentinel(&buf, "{s} · connecting", .{h.label}, 0),
            .offline => std.fmt.bufPrintSentinel(&buf, "{s} · offline", .{h.label}, 0),
        } catch return;
        const label = gtk.Label.new(text.ptr);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).addCssClass("host-heading");
        const row = gtk.ListBoxRow.new();
        row.setChild(label.as(gtk.Widget));
        row.setActivatable(0);
        row.setSelectable(0);
        row.as(gtk.Widget).addCssClass("host-row");
        a.sidebar.append(row.as(gtk.Widget));
        a.rows.append(gpa, null) catch {};
    }

    fn addSessions(a: *App, h: *Host) void {
        const s = h.server;
        for (s.sessions.items) |session| {
            var buf: [256]u8 = undefined;
            const heading = std.fmt.bufPrintSentinel(&buf, "{s}", .{if (session.label.len > 0) session.label else "Session"}, 0) catch continue;
            const label = gtk.Label.new(heading.ptr);
            label.setXalign(0);
            label.setEllipsize(.end);
            label.as(gtk.Widget).setHexpand(1);
            label.as(gtk.Widget).addCssClass("session-heading");
            const head = gtk.Box.new(.horizontal, 0);
            head.append(label.as(gtk.Widget));
            const collapsed = a.collapsed.contains(session.id);
            // On hover, like Rex: a new window in this session, and folding its windows away.
            const sid_z = gpa.dupeSentinel(u8, session.id, 0) catch continue;
            defer gpa.free(sid_z);
            const add = icons.button(.plus, "New window here", "app.new-window-in");
            add.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(sid_z.ptr));
            add.as(gtk.Widget).addCssClass("session-tool");
            head.append(add.as(gtk.Widget));
            const fold = icons.button(if (collapsed) .right else .down, if (collapsed) "Show windows" else "Hide windows", "app.toggle-session");
            fold.as(gtk.Actionable).setActionTargetValue(glib.Variant.newString(sid_z.ptr));
            fold.as(gtk.Widget).addCssClass("session-tool");
            if (collapsed) fold.as(gtk.Widget).addCssClass("folded");
            head.append(fold.as(gtk.Widget));
            const head_row = gtk.ListBoxRow.new();
            head_row.setChild(head.as(gtk.Widget));
            head_row.setActivatable(0);
            head_row.setSelectable(0);
            head_row.as(gtk.Widget).addCssClass("session-row");
            a.sidebar.append(head_row.as(gtk.Widget));
            a.rows.append(gpa, null) catch {};
            if (collapsed) continue;
            const v = s.sessionView(session.id) orelse continue;
            for (v.windows) |*w| {
                var tbuf: [256]u8 = undefined;
                const title = rowTitle(h, &tbuf, w, v);
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
                    .host = h,
                    .session_id = gpa.dupe(u8, session.id) catch continue,
                    .window_id = gpa.dupe(u8, w.id) catch continue,
                    .label = item,
                    .line = line,
                    .tile = tile,
                }) catch {};
            }
        }
    }

    /// A window's row shows its focused pane: that pane's program and title, like Rex.
    fn rowTitle(h: *Host, buf: []u8, w: *const view.Window, v: *const view.SessionView) [:0]const u8 {
        if (w.focused_block_id) |fb| for (h.workspace.panes.items) |p| if (std.mem.eql(u8, p.block_id, fb)) {
            var tb: [256]u8 = undefined;
            const t = p.term.title(&tb);
            return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
        };
        if (w.title()) |t| return std.fmt.bufPrintSentinel(buf, "{s}", .{t}, 0) catch "Window";
        const s = h.server;
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
        for (a.rows.items) |r| if (r) |row| {
            const v = row.host.server.sessionView(row.session_id) orelse continue;
            const w = v.window(row.window_id) orelse continue;
            var buf: [256]u8 = undefined;
            if (row.label) |l| l.setText(rowTitle(row.host, &buf, w, v).ptr);
            if (row.tile) |t| t.queueDraw();
        };
    }

    fn showAlert(a: *App, h: *Host) void {
        const st = &settings.current;
        if (!st.alerts) return;
        const s = h.server;
        switch (s.alert_kind) {
            .blocked => if (!st.alert_blocked) return,
            .failed => if (!st.alert_error) return,
            .done => if (!st.alert_done) return,
            .notification => if (!st.terminal_notifications) return,
        }
        const active = a.window.as(gtk.Window).isActive() != 0;
        const shown = a.current == h and h.workspace.isShown(s.alert_block.items);
        // Someone looking at the pane already sees it.
        if (active and shown) return;
        const text = gpa.dupeSentinel(u8, s.alert_text.items, 0) catch return;
        defer gpa.free(text);
        const n = gio.Notification.new("Compy");
        n.setBody(text.ptr);
        var tbuf: [512]u8 = undefined;
        const where = std.fmt.bufPrintSentinel(&tbuf, "{s} {s} {s}", .{ h.page, s.alert_session.items, s.alert_block.items }, 0) catch return;
        n.setDefaultActionAndTargetValue("app.show-block", glib.Variant.newString(where.ptr));
        var ibuf: [128]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&ibuf, "block-{s}", .{s.alert_block.items}, 0) catch return;
        a.app.as(gio.Application).sendNotification(id.ptr, n);
        n.as(gobject.Object).unref();
        if (st.sound) gdk.Display.getDefault().?.beep();
    }

    fn showBlockAction(a: *App, where: []const u8, block_id: []const u8) void {
        // `where` is "page session"; the action splits off the last part as the block.
        const space = std.mem.indexOfScalar(u8, where, ' ') orelse return;
        for (a.hosts.items) |h| if (std.mem.eql(u8, h.page, where[0..space])) a.selectHost(h);
        const session_id = where[space + 1 ..];
        const s = a.server orelse return;
        a.auto_picked = false;
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
        // Nothing stays highlighted when the shown window has no row, such as an empty session.
        a.sidebar.unselectAll();
        const s = a.server orelse return;
        const here = a.current orelse return;
        const sid = a.session_id orelse return;
        const v = s.sessionView(sid) orelse return;
        const shown = (if (a.window_id) |wid| v.window(wid) else null) orelse v.activeWindow() orelse return;
        for (a.rows.items, 0..) |r, i| if (r) |row| {
            if (row.host == here and std.mem.eql(u8, row.session_id, sid) and std.mem.eql(u8, row.window_id, shown.id)) {
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
        a.selectHost(r.host);
        a.auto_picked = false;
        setSlot(&a.session_id, r.session_id);
        setSlot(&a.window_id, r.window_id);
        if (a.server) |s| s.focusWindow(r.session_id, r.window_id);
        a.showSelected();
        if (a.workspace) |w| w.grabFocus();
    }

    // client.* actions. Key bindings live in the person's Lua config on the server; the server
    // runs its own actions and asks the client for these.

    fn perform(ctx: *anyopaque, action: []const u8, args: ?@import("json.zig").Value, session_id: ?[]const u8) bool {
        const done = performInner(ctx, action, args, session_id);
        if (!done) std.log.warn("not performed: {s}", .{action});
        return done;
    }

    fn performInner(ctx: *anyopaque, action: []const u8, args: ?@import("json.zig").Value, session_id: ?[]const u8) bool {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const a = h.app;
        // A key bound on one host acts on that host's sessions.
        a.selectHost(h);
        const J = @import("json.zig");
        if (session_id) |sid| if (!eqlOpt(a.session_id, sid)) {
            a.auto_picked = false;
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
        if (std.mem.startsWith(u8, action, "pane.")) return a.paneAction(action[5..], args);
        if (std.mem.eql(u8, action, "client.find.open")) return a.did(openFind);
        if (std.mem.eql(u8, action, "client.mode.enter")) {
            termview.setKeyMode(J.str(args, "name") orelse return false);
            return true;
        }
        if (std.mem.eql(u8, action, "client.mode.exit")) {
            termview.setKeyMode("");
            return true;
        }
        if (std.mem.indexOf(u8, action, "palette") != null) return a.did(openPalette);
        if (std.mem.eql(u8, action, "client.sidebar.toggle")) {
            a.split.setShowSidebar(@intFromBool(a.split.getShowSidebar() == 0));
            return true;
        }
        if (std.mem.eql(u8, action, "client.tab.rename")) {
            const s = a.server orelse return false;
            const sid = a.session_id orelse return false;
            const v = s.sessionView(sid) orelse return false;
            const w = (if (a.window_id) |wid| v.window(wid) else null) orelse v.activeWindow() orelse return false;
            a.renameWindowAction(sid, w.id);
            return true;
        }
        if (std.mem.eql(u8, action, "client.config.reload")) {
            const s = a.server orelse return false;
            s.reloadConfig();
            a.toast("Config reloaded");
            return true;
        }
        if (std.mem.eql(u8, action, "client.sidebar.activity.toggle")) {
            a.toast("Compy has no activity sidebar yet");
            return true;
        }
        if (std.mem.eql(u8, action, "session.new")) return a.did(newSession);
        if (std.mem.eql(u8, action, "session.next")) return a.stepSession(1);
        if (std.mem.eql(u8, action, "session.previous")) return a.stepSession(-1);
        if (std.mem.eql(u8, action, "session.rename")) {
            const sid = a.session_id orelse return false;
            a.renameSessionAction(sid);
            return true;
        }
        if (std.mem.eql(u8, action, "session.switch")) return a.did(switchSession);
        return false;
    }

    fn toast(a: *App, text: [:0]const u8) void {
        a.toasts.addToast(adw.Toast.new(text.ptr));
    }

    /// The next or previous session on this host, in the sidebar's order.
    fn stepSession(a: *App, delta: i64) bool {
        const s = a.server orelse return false;
        const n: i64 = @intCast(s.sessions.items.len);
        if (n == 0) return false;
        var i: i64 = 0;
        for (s.sessions.items, 0..) |session, k| if (eqlOpt(a.session_id, session.id)) {
            i = @intCast(k);
        };
        a.showSession(s.sessions.items[@intCast(@mod(i + delta, n))].id);
        return true;
    }

    fn showSession(a: *App, session_id: []const u8) void {
        a.auto_picked = false;
        setSlot(&a.session_id, session_id);
        setSlot(&a.window_id, null);
        a.showSelected();
        a.rebuildSidebar();
        if (a.workspace) |w| w.grabFocus();
    }

    /// A list of this host's sessions to jump to, filtered by typing.
    fn switchSession(a: *App) void {
        const s = a.server orelse return;
        const dialog = adw.Dialog.new();
        dialog.setTitle("Switch Session");
        dialog.setContentWidth(420);
        dialog.setContentHeight(360);
        const list = gtk.ListBox.new();
        list.as(gtk.Widget).addCssClass("navigation-sidebar");
        list.setActivateOnSingleClick(1);
        for (s.sessions.items) |session| {
            const z = gpa.dupeSentinel(u8, if (session.label.len > 0) session.label else session.id, 0) catch continue;
            defer gpa.free(z);
            const label = gtk.Label.new(z.ptr);
            label.setXalign(0);
            const row = gtk.ListBoxRow.new();
            row.setChild(label.as(gtk.Widget));
            const id = gpa.dupeSentinel(u8, session.id, 0) catch continue;
            gobject.Object.setDataFull(row.as(gobject.Object), "session", id.ptr, &freeData);
            list.append(row.as(gtk.Widget));
            if (eqlOpt(a.session_id, session.id)) list.selectRow(row);
        }
        const Picked = struct {
            fn run(_: *gtk.ListBox, row: *gtk.ListBoxRow, d: *adw.Dialog) callconv(.c) void {
                const app = mode_app orelse return;
                const id = gobject.Object.getData(row.as(gobject.Object), "session") orelse return;
                const sid: [*:0]const u8 = @ptrCast(id);
                app.showSession(std.mem.span(sid));
                _ = d.close();
            }
        };
        _ = gtk.ListBox.signals.row_activated.connect(list, *adw.Dialog, &Picked.run, dialog, .{});
        const scroller = gtk.ScrolledWindow.new();
        scroller.setChild(list.as(gtk.Widget));
        scroller.as(gtk.Widget).addCssClass("palette");
        dialog.setChild(scroller.as(gtk.Widget));
        dialog.present(a.window.as(gtk.Widget));
        if (list.getSelectedRow()) |row| _ = row.as(gtk.Widget).grabFocus();
    }

    fn renameSessionAction(a: *App, session_id: []const u8) void {
        const s = a.server orelse return;
        var current: []const u8 = "";
        for (s.sessions.items) |session| if (std.mem.eql(u8, session.id, session_id)) {
            current = session.label;
        };
        const dialog = adw.AlertDialog.new("Rename session", null);
        const entry = gtk.Entry.new();
        const z = gpa.dupeSentinel(u8, current, 0) catch return;
        defer gpa.free(z);
        entry.as(gtk.Editable).setText(z.ptr);
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
            .window_id = gpa.dupe(u8, "") catch return,
        };
        _ = adw.AlertDialog.signals.response.connect(dialog, *RenameCtx, &renamed, ctx, .{});
        dialog.as(adw.Dialog).present(a.window.as(gtk.Widget));
    }

    /// Rex's pane actions, which each app performs itself.
    fn paneAction(a: *App, name: []const u8, args: ?@import("json.zig").Value) bool {
        const J = @import("json.zig");
        const eql = std.mem.eql;
        if (eql(u8, name, "zoom")) return a.did(zoomPane);
        if (eql(u8, name, "close")) return a.did(closePane);
        if (eql(u8, name, "float")) return a.did(floatPane);
        if (eql(u8, name, "focus_next")) return a.focusStep(1);
        if (eql(u8, name, "focus_previous")) return a.focusStep(-1);
        if (eql(u8, name, "split")) {
            const dir = J.str(args, "direction") orelse "right";
            if (eql(u8, dir, "down") or eql(u8, dir, "vertical")) a.splitDown() else a.splitRight();
            return true;
        }
        if (eql(u8, name, "resize")) {
            const dir = J.str(args, "direction") orelse return false;
            const amount: f64 = @floatFromInt(J.int(args, "amount") orelse 3);
            return a.resizeFocused(dir, amount);
        }
        if (eql(u8, name, "balance")) return a.balance();
        if (eql(u8, name, "focus")) {
            const ws = a.workspace orelse return false;
            const next_pane = ws.neighbor(J.str(args, "direction") orelse return false) orelse return true;
            ws.focus(next_pane);
            ws.grabFocus();
            return true;
        }
        if (eql(u8, name, "send_key")) {
            // A key the config passes through, such as the prefix itself pressed twice.
            const ws = a.workspace orelse return false;
            const s = a.server orelse return false;
            const sid = a.session_id orelse return false;
            const block = ws.focusedBlock() orelse return false;
            const key = @import("keys.zig").fromName(J.str(args, "key") orelse return false) orelse return false;
            // Alone, the key has no binding of its own, so the server hands it to the block.
            s.sendKey(sid, block, key);
            return true;
        }
        return false;
    }

    fn focusStep(a: *App, delta: i64) bool {
        const ws = a.workspace orelse return false;
        const n: i64 = @intCast(ws.panes.items.len);
        if (n == 0) return false;
        const cur = ws.focusedBlock() orelse ws.panes.items[0].block_id;
        var i: i64 = 0;
        for (ws.panes.items, 0..) |p, k| if (std.mem.eql(u8, p.block_id, cur)) {
            i = @intCast(k);
        };
        const next = ws.panes.items[@intCast(@mod(i + delta, n))];
        ws.focus(next.block_id);
        _ = next.term.widget().grabFocus();
        return true;
    }

    /// Moves the border of the focused pane's nearest split in that direction, by `amount` cells.
    fn resizeFocused(a: *App, dir: []const u8, amount: f64) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const ws = a.workspace orelse return false;
        const block = ws.focusedBlock() orelse return false;
        const v = s.sessionView(sid) orelse return false;
        const w = v.windowOf(block) orelse return false;
        const root = (w.tiled() orelse return false).layout orelse return false;
        const horizontal = std.mem.eql(u8, dir, "left") or std.mem.eql(u8, dir, "right");
        const grow = std.mem.eql(u8, dir, "right") or std.mem.eql(u8, dir, "down");
        const split = nearestSplit(root, block, horizontal) orelse return false;
        const tv = ws.focusedView() orelse return false;
        // One cell, as a share of the split's size on screen.
        const across: f64 = @floatFromInt(if (horizontal) ws.root.getWidth() else ws.root.getHeight());
        const cell = if (horizontal) tv.cell_w else tv.cell_h;
        const size = (if (horizontal) split.rect.w else split.rect.h) * across;
        const delta = amount * cell / @max(1, size);
        const now = glib.getMonotonicTime();
        const recent = now - last_ratio_at < 1_500_000 and std.mem.eql(u8, last_split[0..last_split_len], split.id);
        const from = if (recent) last_ratio else split.ratio;
        const ratio = std.math.clamp(from + (if (grow) delta else -delta), 0.05, 0.95);
        const n = @min(split.id.len, last_split.len);
        @memcpy(last_split[0..n], split.id[0..n]);
        last_split_len = n;
        last_ratio = ratio;
        last_ratio_at = now;
        s.resizePane(sid, horizontal, firstLeafOf(split.before), firstLeafOf(split.after), ratio);
        return true;
    }

    /// Gives every split the share its panes would have if all were the same size.
    fn balance(a: *App) bool {
        const s = a.server orelse return false;
        const sid = a.session_id orelse return false;
        const v = s.sessionView(sid) orelse return false;
        const w = (if (a.window_id) |wid| v.window(wid) else null) orelse v.activeWindow() orelse return false;
        const root = (w.tiled() orelse return false).layout orelse return false;
        balanceNode(s, sid, root);
        return true;
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
            .{ "palette", openPalette, "" },
            .{ "settings", openSettings, "" },
            .{ "add-host", addHostDialog, "" },
            .{ "pane-float-focused", floatPane, "" },
            .{ "find", openFind, "" },
            .{ "prompt-prev", promptPrev, "" },
            .{ "prompt-next", promptNext, "" },
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
            .{ "pane-minimize", minimizePane },
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
            const action = gio.SimpleAction.newStateful("tight", null, glib.Variant.newBoolean(@intFromBool(settings.current.tight)));
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
        inline for (.{ .{ "new-window-in", newWindowIn }, .{ "toggle-session", toggleSession }, .{ "filter", filterAction } }) |e| {
            const action = gio.SimpleAction.new(e[0], glib.VariantType.new("s"));
            const Thunk = struct {
                fn run(_: *gio.SimpleAction, param: ?*glib.Variant, app: *App) callconv(.c) void {
                    e[1](app, std.mem.span(param.?.getString(null)));
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
                    const space = std.mem.lastIndexOfScalar(u8, text, ' ') orelse return;
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

    /// Floats a tiled pane in the middle of the window, or puts a floating one back in the tiles.
    fn floatPane(a: *App) void {
        const t = a.target() orelse return;
        const ws = a.workspace orelse return;
        const p = ws.paneOf(t[2]) orelse return;
        if (!p.floating) return t[0].floatBlock(t[1], t[2], .{ .x = 0.2, .y = 0.15, .w = 0.6, .h = 0.65 });
        // Back beside a tiled pane, at the right of the layout.
        for (ws.panes.items) |other| if (!other.floating) {
            return t[0].moveBlock(t[1], t[2], other.block_id, true, false);
        };
        t[0].notifyMessage("There's no tiled pane to put it next to");
    }

    /// Minimizes a pane to the tray. A tiled pane floats first, then goes once the server says so.
    fn minimizePane(a: *App) void {
        const t = a.target() orelse return;
        const ws = a.workspace orelse return;
        const p = ws.paneOf(t[2]) orelse return;
        if (p.floating) return t[0].setLayerMinimized(t[1], p.layer_id, true);
        setSlot(&a.minimize_next, t[2]);
        t[0].floatBlock(t[1], t[2], .{ .x = 0.2, .y = 0.15, .w = 0.6, .h = 0.65 });
    }

    /// Finishes a minimize that had to float the pane first.
    fn finishMinimize(a: *App) void {
        const block = a.minimize_next orelse return;
        const ws = a.workspace orelse return;
        const p = ws.paneOf(block) orelse return;
        if (!p.floating) return;
        if (a.server) |s| if (a.session_id) |sid| s.setLayerMinimized(sid, p.layer_id, true);
        setSlot(&a.minimize_next, null);
    }

    pub fn setTight(a: *App, on: bool) void {
        @import("workspace.zig").setTight(on);
        if (settings.current.tight != on) {
            settings.current.tight = on;
            settings.save();
        }
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
        const s = ctx.app.server orelse return;
        // No window means the session itself is renamed.
        if (ctx.window_id.len == 0) s.renameSession(ctx.session_id, label) else s.renameWindow(ctx.session_id, ctx.window_id, label);
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

    fn openPalette(a: *App) void {
        const s = a.server orelse return;
        const sid = a.session_id orelse return;
        const block = if (a.workspace) |ws| ws.focusedBlock() else null;
        Palette.open(s, a.app.as(gtk.Application), a.window.as(gtk.Widget), sid, block);
    }

    // Settings.

    fn openSettings(a: *App) void {
        @import("settings_window.zig").open(a);
    }

    /// Applies the terminal font from the settings to every pane.
    pub fn fontChanged(a: *App) void {
        termview.font = termview.Font.init(gpa.dupeSentinel(u8, settings.current.font, 0) catch return);
        for (a.hosts.items) |h| h.workspace.fontChanged();
    }

    /// Applies the theme setting: every terminal recolors, and so does the window.
    pub fn themeChanged(a: *App) void {
        themes.active = themes.resolve(settings.current.theme);
        for (a.hosts.items) |h| {
            var it = h.server.streams.valueIterator();
            while (it.next()) |st| st.*.hostColorsChanged();
        }
        a.theme_for = null;
        a.applyTheme();
    }

    pub fn headersChanged(a: *App) void {
        @import("workspace.zig").show_headers = settings.current.show_headers;
        for (a.hosts.items) |h| h.workspace.headersChanged();
        a.markHeaders();
    }

    /// Without title rows, nothing makes room for the corner, so the panes start below it.
    fn markHeaders(a: *App) void {
        const w = a.window.as(gtk.Widget);
        if (settings.current.show_headers) w.removeCssClass("no-headers") else w.addCssClass("no-headers");
    }

    pub fn redrawAll(a: *App) void {
        for (a.hosts.items) |h| h.workspace.redraw();
        a.refreshRows();
    }

    fn newWindowIn(a: *App, session_id: []const u8) void {
        const s = a.server orelse return;
        a.auto_picked = false;
        setSlot(&a.session_id, session_id);
        setSlot(&a.window_id, null); // follow the new active window
        s.newWindow(session_id);
    }

    fn toggleSession(a: *App, session_id: []const u8) void {
        if (a.collapsed.fetchRemove(session_id)) |e| {
            gpa.free(e.key);
        } else {
            const key = gpa.dupe(u8, session_id) catch return;
            a.collapsed.put(gpa, key, {}) catch gpa.free(key);
        }
        a.rebuildSidebar();
    }

    fn promptPrev(a: *App) void {
        if (a.workspace) |ws| if (ws.focusedView()) |tv| tv.jumpPrompt(-1);
    }

    fn promptNext(a: *App) void {
        if (a.workspace) |ws| if (ws.focusedView()) |tv| tv.jumpPrompt(1);
    }

    fn toggleSidebar(a: *App) void {
        a.split.setShowSidebar(@intFromBool(a.split.getShowSidebar() == 0));
    }

    fn changeServer(a: *App) void {
        a.stack.setVisibleChildName("connect");
    }
};

/// Shows Compy's icon for its windows: from the installed icons, or from the build's when run
/// from zig-out. On a Mac, where it's only built for development, it sets the Dock icon too.
fn useAppIcon() void {
    // Installed apps live in PREFIX/bin with their icons in PREFIX/share, zig-out included.
    var exe_buf: [4096]u8 = undefined;
    const n = std.process.executableDirPath(@import("main.zig").io, &exe_buf) catch return;
    var dir_buf: [4200]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&dir_buf, "{s}/../share", .{exe_buf[0..n]}) catch return;
    const icons_dir = std.fmt.allocPrintSentinel(gpa, "{s}/icons", .{data_dir}, 0) catch return;
    defer gpa.free(icons_dir);
    gtk.IconTheme.getForDisplay(gdk.Display.getDefault().?).addSearchPath(icons_dir.ptr);
    gtk.Window.setDefaultIconName("dev.compy.linux");
    if (builtin.os.tag == .macos) {
        const png = std.fmt.allocPrintSentinel(gpa, "{s}/icons/hicolor/512x512/apps/dev.compy.linux.png", .{data_dir}, 0) catch return;
        defer gpa.free(png);
        @import("macos.zig").setDockIcon(png);
    }
}

/// Blinks the cursor of the pane with the keyboard, when the setting and the program allow it.
fn blinkTick(data: ?*anyopaque) callconv(.c) c_int {
    const a: *App = @ptrCast(@alignCast(data.?));
    termview.blink_on = !termview.blink_on;
    if (a.workspace) |ws| if (ws.focusedView()) |tv| if (tv.widget().hasFocus() != 0) tv.widget().queueDraw();
    return 1;
}

var mode_app: ?*App = null;

/// Shows the start of a key sequence, such as "ctrl+a …", until it's finished.
fn chordChanged(pending: []const u8) void {
    const a = mode_app orelse return;
    if (pending.len == 0) {
        modeChanged();
        return;
    }
    var buf: [200]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s} …", .{pending}, 0) catch return;
    a.mode_chip.setText(text.ptr);
    a.mode_chip.as(gtk.Widget).setVisible(1);
}

fn freeData(data: ?*anyopaque) callconv(.c) void {
    const p: [*:0]u8 = @ptrCast(data orelse return);
    gpa.free(std.mem.span(p));
}

fn modeChanged() void {
    const a = mode_app orelse return;
    const mode = termview.keyMode();
    if (mode.len == 0) {
        a.mode_chip.as(gtk.Widget).setVisible(0);
        return;
    }
    var buf: [96]u8 = undefined;
    var upper: [32]u8 = undefined;
    const n = @min(mode.len, upper.len);
    for (mode[0..n], 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
    const text = std.fmt.bufPrintSentinel(&buf, "{s} · Esc to leave", .{upper[0..n]}, 0) catch return;
    a.mode_chip.setText(text.ptr);
    a.mode_chip.as(gtk.Widget).setVisible(1);
}

const SplitOf = struct { id: []const u8, rect: view.Rect, ratio: f64, before: *const view.Node, after: *const view.Node };

/// The ratio last asked of a split, for key repeats that come faster than the server's update.
var last_split: [64]u8 = undefined;
var last_split_len: usize = 0;
var last_ratio: f64 = 0;
var last_ratio_at: i64 = 0;

fn contains(n: *const view.Node, block: []const u8) bool {
    return switch (n.*) {
        .leaf => |l| std.mem.eql(u8, l.block_id, block),
        .split => |sp| contains(sp.before, block) or contains(sp.after, block),
    };
}

/// The innermost split around `block` that divides the way asked.
fn nearestSplit(n: *const view.Node, block: []const u8, horizontal: bool) ?SplitOf {
    switch (n.*) {
        .leaf => return null,
        .split => |sp| {
            const inner = if (contains(sp.before, block)) nearestSplit(sp.before, block, horizontal) else if (contains(sp.after, block)) nearestSplit(sp.after, block, horizontal) else return null;
            if (inner) |x| return x;
            if (sp.horizontal == horizontal) return .{ .id = sp.id, .rect = sp.rect, .ratio = sp.ratio, .before = sp.before, .after = sp.after };
            return null;
        },
    }
}

fn firstLeafOf(n: *const view.Node) []const u8 {
    return switch (n.*) {
        .leaf => |l| l.block_id,
        .split => |sp| firstLeafOf(sp.before),
    };
}

fn leaves(n: *const view.Node) f64 {
    return switch (n.*) {
        .leaf => 1,
        .split => |sp| leaves(sp.before) + leaves(sp.after),
    };
}

fn balanceNode(s: *Server, sid: []const u8, n: *const view.Node) void {
    switch (n.*) {
        .leaf => {},
        .split => |sp| {
            const b = leaves(sp.before);
            s.resizePane(sid, sp.horizontal, firstLeafOf(sp.before), firstLeafOf(sp.after), b / (b + leaves(sp.after)));
            balanceNode(s, sid, sp.before);
            balanceNode(s, sid, sp.after);
        },
    }
}

fn appMenu() *gio.MenuModel {
    const menu = gio.Menu.new();
    const panes = gio.Menu.new();
    panes.append("Split right", "app.split-right");
    panes.append("Split down", "app.split-down");
    panes.append("Zoom pane", "app.zoom-pane");
    panes.append("Close pane", "app.close-pane");
    menu.appendSection(null, panes.as(gio.MenuModel));
    const other = gio.Menu.new();
    other.append("Commands…", "app.palette");
    other.append("Find…", "app.find");
    other.append("New window", "app.new-window");
    other.append("New session", "app.new-session");
    other.append("Settings…", "app.settings");
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
        // App actions don't need a pane.
        if (std.mem.eql(u8, cmd, "action")) {
            const name = it.next() orelse continue;
            const z = gpa.dupeSentinel(u8, name, 0) catch continue;
            defer gpa.free(z);
            const param: ?*glib.Variant = if (it.next()) |arg| blk: {
                const za = gpa.dupeSentinel(u8, arg, 0) catch continue;
                defer gpa.free(za);
                break :blk glib.Variant.newString(za.ptr);
            } else if (std.mem.startsWith(u8, name, "pane-")) blk: {
                const tvp = ws.focusedView() orelse continue;
                break :blk glib.Variant.newString(@ptrCast((gpa.dupeSentinel(u8, tvp.block_id, 0) catch continue).ptr));
            } else null;
            a.app.as(gio.ActionGroup).activateAction(z.ptr, param);
            continue;
        }
        const tv = ws.focusedView() orelse {
            std.log.info("script: no pane for {s}", .{cmd});
            continue;
        };
        const t = tv.term() orelse {
            std.log.info("script: no terminal for {s}", .{cmd});
            continue;
        };
        std.log.info("script: {s}", .{cmd});
        if (false) {        } else if (std.mem.eql(u8, cmd, "carry")) {
            const x = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const y = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            ws.simulateCarry(tv.block_id, x, y);
        } else if (std.mem.eql(u8, cmd, "key")) {
            // Presses like "ctrl+a", "shift+-" or "left", one after another.
            var keys_it = std.mem.tokenizeScalar(u8, rest, ' ');
            while (keys_it.next()) |press| {
                var mods: u4 = 0;
                var parts = std.mem.splitScalar(u8, press, '+');
                var last: []const u8 = "";
                while (parts.next()) |part| {
                    if (parts.peek() == null or part.len == 0) {
                        last = if (part.len == 0) "+" else part;
                        break;
                    }
                    const K = @import("keys.zig");
                    if (std.mem.eql(u8, part, "ctrl")) mods |= K.ctrl else if (std.mem.eql(u8, part, "shift")) mods |= K.shift else if (std.mem.eql(u8, part, "alt")) mods |= K.alt else if (std.mem.eql(u8, part, "super")) mods |= K.super;
                }
                const named = [_]struct { []const u8, c_uint }{ .{ "left", 0xff51 }, .{ "up", 0xff52 }, .{ "right", 0xff53 }, .{ "down", 0xff54 }, .{ "enter", 0xff0d }, .{ "escape", 0xff1b }, .{ "tab", 0xff09 } };
                var keyval: c_uint = if (last.len == 1) last[0] else 0;
                for (named) |n| if (std.mem.eql(u8, n[0], last)) {
                    keyval = n[1];
                };
                if (keyval == 0) continue;
                const target = (a.workspace orelse ws).focusedView() orelse tv;
                _ = target.handleKey(keyval, mods);
            }
        } else if (std.mem.eql(u8, cmd, "bench")) {
            tv.bench();
        } else if (std.mem.eql(u8, cmd, "drop")) {
            ws.simulateDrop();
        } else if (std.mem.eql(u8, cmd, "divider")) {
            const dx = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            ws.simulateDivider(dx);
        } else if (std.mem.eql(u8, cmd, "commit")) {
            const z = gpa.dupeSentinel(u8, rest, 0) catch continue;
            defer gpa.free(z);
            tv.commitText(z);
        } else if (std.mem.eql(u8, cmd, "menu")) {
            tv.showMenuAt(120, 120);
        } else if (std.mem.eql(u8, cmd, "zoom")) {
            tv.zoomBy(std.fmt.parseFloat(f64, it.next() orelse "0") catch 0);
        } else if (std.mem.eql(u8, cmd, "scroll")) {
            const dy = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            tv.scrollBy(dy);
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
