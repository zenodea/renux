//! Settings > Server, laid out as the Rex app lays it out: the server, the address other devices
//! reach it at with a code to pair a phone, and the server's own Tailscale device. This
//! computer's server is read and changed through the rex command; another computer's server
//! only through Renux's connection to it.
const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const App = @import("app.zig").App;
const settings = @import("../settings/settings.zig");
const icons = @import("../icons/icons.zig");
const proc = @import("../util/proc.zig");
const json = @import("../util/json.zig");
const ws = @import("../rex/ws.zig");
const updates = @import("../rex/updates.zig");
const control = @import("../rex/control.zig");
const server_mod = @import("../rex/server.zig");
const Server = server_mod.Server;

const gpa = std.heap.c_allocator;
const eql = std.mem.eql;
const data_key = "renux-server-panel";

/// The page's rows and what was last read from the server, kept on the page and freed with it.
/// Every command keeps the page until it answers, so this is there when the answer comes.
const Panel = struct {
    app: *App,
    /// The server's address, for `rex -S`.
    url: [:0]u8,
    /// This computer's own server, reached by its socket: it can be started, stopped and put
    /// on the tailnet from here.
    local: bool,
    server_row: *adw.ActionRow,
    start_stop: *gtk.Button,
    reconnect: *gtk.Button,
    update_row: *adw.ActionRow,
    update_button: *gtk.Button,
    address_row: *adw.ActionRow,
    copy: *gtk.Button,
    pair: *gtk.Button,
    tailnet: ?Tailnet = null,
    /// What Copy and Pair give: the address other devices reach the server at.
    address: ?[:0]u8 = null,
    /// The link that signs the server's Tailscale device in, while it waits for that.
    auth_url: ?[:0]u8 = null,
    /// From the last reading. A server that isn't running doesn't answer one.
    read_once: bool = false,
    running: bool = false,
    started: i64 = 0,
    version: ?[:0]u8 = null,
    api_revision: i64 = 0,
    serving: bool = false,
    hostname_shown: bool = false,
    /// What the Tailscale account row's button does now.
    account_action: enum { sign_in, sign_out } = .sign_in,
    /// True while switches are set to match the server, which isn't the person's change.
    syncing: bool = false,
    /// A reading waiting to happen, while a change is under way.
    timer: c_uint = 0,
    /// The connection's state when last shown, to read the server again when it changes.
    last_state: ?server_mod.State = null,

    fn free(data: ?*anyopaque) callconv(.c) void {
        const panel: *Panel = @ptrCast(@alignCast(data.?));
        gpa.free(panel.url);
        inline for (.{ panel.address, panel.auth_url, panel.version }) |s| if (s) |x| gpa.free(x);
        gpa.destroy(panel);
    }

    fn of(p: *adw.PreferencesPage) ?*Panel {
        return @ptrCast(@alignCast(p.as(gobject.Object).getData(data_key) orelse return null));
    }

    /// Renux's connection to this server, if it still has one.
    fn server(panel: *Panel) ?*Server {
        for (panel.app.hosts.items) |h| if (eql(u8, h.server.url, panel.url)) return h.server;
        return null;
    }
};

const Tailnet = struct {
    account: *adw.ActionRow,
    account_button: *gtk.Button,
    serve: *adw.SwitchRow,
    limit: *adw.SwitchRow,
    tags: *gtk.Label,
    control_server: *gtk.Label,
    hostname: *adw.EntryRow,
};

fn setStr(slot: *?[:0]u8, value: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (value) |v| gpa.dupeSentinel(u8, v, 0) catch null else null;
}

fn button(label: [:0]const u8) *gtk.Button {
    const b = gtk.Button.newWithLabel(label.ptr);
    b.as(gtk.Widget).setValign(.center);
    return b;
}

fn valueLabel(row: *adw.ActionRow, tip: [:0]const u8) *gtk.Label {
    const l = gtk.Label.new("");
    l.as(gtk.Widget).addCssClass("dim-label");
    row.addSuffix(l.as(gtk.Widget));
    row.as(gtk.Widget).setTooltipText(tip.ptr);
    return l;
}

fn group(p: *adw.PreferencesPage, title: ?[:0]const u8) *adw.PreferencesGroup {
    const g = adw.PreferencesGroup.new();
    if (title) |t| g.setTitle(t.ptr);
    p.add(g);
    return g;
}

/// Adds the Rex Server, address and Tailscale groups to Settings > Server.
pub fn build(p: *adw.PreferencesPage, a: *App) void {
    const s = a.server orelse {
        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle("Not connected");
        row.setSubtitle("Connect to a Rex server to see it here");
        group(p, null).add(row.as(gtk.Widget));
        return;
    };
    const url = gpa.dupeSentinel(u8, s.url, 0) catch return;
    const panel = gpa.create(Panel) catch {
        gpa.free(url);
        return;
    };
    const local = ws.unixPath(s.url) != null;

    // The server.
    const g = group(p, null);
    const server_row = adw.ActionRow.new();
    server_row.as(adw.PreferencesRow).setTitle("Rex Server");
    server_row.setSubtitleLines(3);
    server_row.addPrefix(icons.image(.server, 28));
    const reconnect = button("Reconnect");
    reconnect.as(gtk.Actionable).setActionName("app.retry");
    reconnect.as(gtk.Widget).setVisible(0);
    server_row.addSuffix(reconnect.as(gtk.Widget));
    const start_stop = button("Stop Server…");
    start_stop.as(gtk.Widget).setVisible(0);
    server_row.addSuffix(start_stop.as(gtk.Widget));
    g.add(server_row.as(gtk.Widget));
    const update_row = adw.ActionRow.new();
    update_row.as(gtk.Widget).setVisible(0);
    const update_button = button("Update Server…");
    update_button.as(gtk.Widget).setVisible(@intFromBool(local));
    update_row.addSuffix(update_button.as(gtk.Widget));
    g.add(update_row.as(gtk.Widget));
    const look = adw.SwitchRow.new();
    look.as(adw.PreferencesRow).setTitle("Look for Rex updates");
    look.as(adw.ActionRow).setSubtitle("Reads Rex's public list of releases and says when this server could be updated");
    look.setActive(@intFromBool(settings.current.rex_updates));
    g.add(look.as(gtk.Widget));

    // The address other devices reach it at.
    const address_row = adw.ActionRow.new();
    address_row.as(adw.PreferencesRow).setTitle("Remote Address");
    address_row.setSubtitleSelectable(1);
    const copy = button("Copy");
    const pair = button("Pair");
    pair.as(gtk.Widget).addCssClass("suggested-action");
    address_row.addSuffix(copy.as(gtk.Widget));
    address_row.addSuffix(pair.as(gtk.Widget));
    group(p, null).add(address_row.as(gtk.Widget));

    panel.* = .{
        .app = a,
        .url = url,
        .local = local,
        .server_row = server_row,
        .start_stop = start_stop,
        .reconnect = reconnect,
        .update_row = update_row,
        .update_button = update_button,
        .address_row = address_row,
        .copy = copy,
        .pair = pair,
    };

    // The server's own Tailscale device, which only this computer's server can be asked about.
    if (local) {
        const tg = group(p, "Tailscale");
        const account = adw.ActionRow.new();
        account.as(adw.PreferencesRow).setTitle("Tailscale");
        account.setSubtitleLines(2);
        const account_button = button("Sign In");
        account_button.as(gtk.Widget).setVisible(0);
        account.addSuffix(account_button.as(gtk.Widget));
        tg.add(account.as(gtk.Widget));
        const serve = adw.SwitchRow.new();
        serve.as(adw.PreferencesRow).setTitle("Serve over Tailscale");
        serve.as(adw.ActionRow).setSubtitle("Connect to this computer's Rex server over your tailnet");
        tg.add(serve.as(gtk.Widget));
        const limit = adw.SwitchRow.new();
        limit.as(adw.PreferencesRow).setTitle("Limit access to your Tailscale account");
        limit.setActive(@intFromBool(!settings.current.tailscale_open));
        tg.add(limit.as(gtk.Widget));
        const tags_row = adw.ActionRow.new();
        tags_row.as(adw.PreferencesRow).setTitle("Tags");
        const tags = valueLabel(tags_row, "The Tailscale tags the server's device signed in with. They are set when it first signs in.");
        tg.add(tags_row.as(gtk.Widget));
        const control_row = adw.ActionRow.new();
        control_row.as(adw.PreferencesRow).setTitle("Control Server");
        const control_server = valueLabel(control_row, "The server the device signs in with: Tailscale's own, or one such as Headscale.");
        tg.add(control_row.as(gtk.Widget));
        const hostname = adw.EntryRow.new();
        hostname.as(adw.PreferencesRow).setTitle("Preferred Hostname");
        hostname.setShowApplyButton(1);
        hostname.as(gtk.Widget).setTooltipText("Used to make the server's Tailscale address");
        tg.add(hostname.as(gtk.Widget));
        panel.tailnet = .{ .account = account, .account_button = account_button, .serve = serve, .limit = limit, .tags = tags, .control_server = control_server, .hostname = hostname };
        _ = gtk.Button.signals.clicked.connect(account_button, *adw.PreferencesPage, &accountClicked, p, .{});
        _ = gobject.Object.signals.notify.connect(serve, *adw.PreferencesPage, &serveToggled, p, .{ .detail = "active" });
        _ = gobject.Object.signals.notify.connect(limit, *adw.PreferencesPage, &limitToggled, p, .{ .detail = "active" });
        _ = adw.EntryRow.signals.apply.connect(hostname, *adw.PreferencesPage, &hostnameApplied, p, .{});
    }

    p.as(gobject.Object).setDataFull(data_key, panel, &Panel.free);
    _ = gtk.Button.signals.clicked.connect(start_stop, *adw.PreferencesPage, &startStopClicked, p, .{});
    _ = gtk.Button.signals.clicked.connect(update_button, *adw.PreferencesPage, &updateClicked, p, .{});
    _ = gtk.Button.signals.clicked.connect(copy, *adw.PreferencesPage, &copyClicked, p, .{});
    _ = gtk.Button.signals.clicked.connect(pair, *adw.PreferencesPage, &pairClicked, p, .{});
    _ = gobject.Object.signals.notify.connect(look, *App, &lookToggled, a, .{ .detail = "active" });
    show(p);
    read(p);
}

/// Called often while Settings is open: keeps the uptime current, and reads the server again
/// when Renux's connection to it changes, such as when it was started or stopped elsewhere.
pub fn tick(p: *adw.PreferencesPage) void {
    const panel = Panel.of(p) orelse return;
    const state = if (panel.server()) |s| s.state else null;
    if (panel.last_state != null and state != panel.last_state) read(p);
    panel.last_state = state;
    show(p);
}

// Reading.

const Then = enum { parse, read, started };

/// Runs a rex command for the page, then reads the server, or takes what it printed as the
/// server's status.
fn run(p: *adw.PreferencesPage, argv: []const [:0]const u8, comptime then: Then) void {
    const H = struct {
        fn answered(data: ?*anyopaque, output: ?[]const u8) void {
            const page: *adw.PreferencesPage = @ptrCast(@alignCast(data.?));
            defer page.as(gobject.Object).unref();
            switch (then) {
                .parse => parse(page, output orelse ""),
                .read => read(page),
                .started => {
                    // Renux connects to it now rather than at its next retry.
                    if (Panel.of(page)) |panel| for (panel.app.hosts.items) |h| {
                        if (ws.unixPath(h.server.url) != null) h.server.retry();
                    };
                    read(page);
                },
            }
        }
    };
    _ = p.as(gobject.Object).ref();
    if (!proc.run(argv, p, &H.answered)) H.answered(p, null);
}

fn read(p: *adw.PreferencesPage) void {
    const panel = Panel.of(p) orelse return;
    if (!panel.local) return show(p);
    run(p, &.{ "rex", "--autostart=false", "-S", panel.url, "server", "status", "--json" }, .parse);
}

/// Takes in `rex server status --json`, which prints nothing when no server is running.
fn parse(p: *adw.PreferencesPage, output: []const u8) void {
    const panel = Panel.of(p) orelse return;
    panel.read_once = true;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, output, .{}) catch {
        panel.running = false;
        panel.serving = false;
        setStr(&panel.address, null);
        show(p);
        if (panel.tailnet) |t| showTailnet(p, panel, t, null);
        return;
    };
    defer parsed.deinit();
    const v = parsed.value;
    panel.running = true;
    panel.started = if (json.str(v, "started_at")) |t| unixOf(t) else 0;
    setStr(&panel.version, json.str(v, "rex_version"));
    panel.api_revision = json.int(v, "api_revision") orelse 0;
    const ts = json.get(v, "tailscale");
    const https = json.get(ts, "https");
    panel.serving = !eql(u8, json.str(ts, "state") orelse "disabled", "disabled");
    const ready = eql(u8, json.str(https, "state") orelse "", "available");
    setStr(&panel.address, if (ready) json.str(https, "url") else null);
    show(p);
    if (panel.tailnet) |t| showTailnet(p, panel, t, ts);
}

fn unixOf(text: []const u8) i64 {
    const z = gpa.dupeSentinel(u8, text, 0) catch return 0;
    defer gpa.free(z);
    const dt = glib.DateTime.newFromIso8601(z.ptr, null) orelse return 0;
    defer dt.unref();
    return dt.toUnix();
}

fn uptime(buf: []u8, seconds: i64) []const u8 {
    const m = @divTrunc(@max(0, seconds), 60);
    const h = @divTrunc(m, 60);
    const d = @divTrunc(h, 24);
    return (if (d > 0)
        std.fmt.bufPrint(buf, "{d}d {d}h", .{ d, @mod(h, 24) })
    else if (h > 0)
        std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, @mod(m, 60) })
    else if (m > 0)
        std.fmt.bufPrint(buf, "{d}m", .{m})
    else
        std.fmt.bufPrint(buf, "less than a minute", .{})) catch "";
}

// Showing.

/// The server and address rows, from the last reading and Renux's connection.
fn show(p: *adw.PreferencesPage) void {
    const panel = Panel.of(p) orelse return;
    const s = panel.server();
    var buf: [384]u8 = undefined;
    var up: [32]u8 = undefined;
    const offline = if (s) |x| x.state == .offline else true;
    const reason: []const u8 = if (s) |x| x.reason.items else "";
    if (panel.local) {
        const now = @divTrunc(glib.getRealTime(), std.time.us_per_s);
        const sub = if (!panel.read_once)
            std.fmt.bufPrintSentinel(&buf, "Checking…", .{}, 0)
        else if (!panel.running)
            std.fmt.bufPrintSentinel(&buf, "Not running", .{}, 0)
        else if (offline)
            std.fmt.bufPrintSentinel(&buf, "Running for {s}. Renux isn't connected: {s}", .{ uptime(&up, now - panel.started), reason }, 0)
        else
            std.fmt.bufPrintSentinel(&buf, "Running for {s}", .{uptime(&up, now - panel.started)}, 0);
        const text: [:0]const u8 = sub catch "";
        panel.server_row.setSubtitle(text.ptr);
        if (panel.version) |v| {
            const tip = std.fmt.bufPrintSentinel(&buf, "Rex {s}, API revision {d}\n{s}", .{ v, panel.api_revision, panel.url }, 0) catch "";
            panel.server_row.as(gtk.Widget).setTooltipText(tip.ptr);
        }
        const b = panel.start_stop.as(gtk.Widget);
        b.setVisible(@intFromBool(panel.read_once));
        panel.start_stop.setLabel(if (panel.running) "Stop Server…" else "Start Server");
        if (panel.running) b.addCssClass("destructive-action") else b.removeCssClass("destructive-action");
        if (panel.running) b.removeCssClass("suggested-action") else b.addCssClass("suggested-action");
        panel.reconnect.as(gtk.Widget).setVisible(@intFromBool(panel.running and offline));
    } else if (s) |x| {
        const sub = switch (x.state) {
            .online => std.fmt.bufPrintSentinel(&buf, "Connected{s}{s}", .{ if (x.rex_version != null) " · Rex " else "", x.rex_version orelse "" }, 0),
            .connecting => std.fmt.bufPrintSentinel(&buf, "Connecting…", .{}, 0),
            .offline => std.fmt.bufPrintSentinel(&buf, "Offline: {s}", .{reason}, 0),
        } catch "";
        panel.server_row.setSubtitle(sub.ptr);
        panel.reconnect.as(gtk.Widget).setVisible(@intFromBool(offline));
        if (panel.address == null) setStr(&panel.address, panel.url);
    }

    // A newer Rex, or a server older than the API Renux speaks.
    const version: ?[]const u8 = if (panel.local) panel.version else if (s) |x| x.rex_version else null;
    const api = if (panel.local) panel.api_revision else if (s) |x| x.api_revision else 0;
    if (api > 0 and api < control.api_revision) {
        panel.update_row.as(adw.PreferencesRow).setTitle("New API features are available");
        panel.update_row.setSubtitle("Update the server to enable them");
        panel.update_row.as(gtk.Widget).setVisible(1);
    } else if (updates.available(version)) |newer| {
        const title = std.fmt.bufPrintSentinel(&buf, "Rex {s} is available", .{newer}, 0) catch "";
        panel.update_row.as(adw.PreferencesRow).setTitle(title.ptr);
        panel.update_row.setSubtitle(if (panel.local) "Update the server to run it" else "Update Rex on that computer to run it");
        panel.update_row.as(gtk.Widget).setVisible(1);
    } else panel.update_row.as(gtk.Widget).setVisible(0);

    if (panel.address) |addr| {
        panel.address_row.setSubtitle(addr.ptr);
    } else panel.address_row.setSubtitle(if (panel.serving)
        "Waiting for the server's Tailscale address…"
    else
        "Turn on Serve over Tailscale to reach this server from your phone or another computer");
    panel.copy.as(gtk.Widget).setSensitive(@intFromBool(panel.address != null));
    panel.pair.as(gtk.Widget).setSensitive(@intFromBool(panel.address != null));
}

/// The Tailscale rows, from the `tailscale` part of the server's status: its state is one of
/// disabled, starting, needs_login, needs_machine_approval and running.
fn showTailnet(p: *adw.PreferencesPage, panel: *Panel, t: Tailnet, ts: ?json.Value) void {
    panel.syncing = true;
    defer panel.syncing = false;
    var buf: [384]u8 = undefined;
    inline for (.{ t.serve.as(gtk.Widget), t.limit.as(gtk.Widget), t.hostname.as(gtk.Widget) }) |w| w.setSensitive(@intFromBool(panel.running));
    t.account_button.as(gtk.Widget).setVisible(0);
    if (!panel.running) {
        t.account.as(adw.PreferencesRow).setTitle("Tailscale");
        t.account.setSubtitle("Start the server first");
        t.serve.setActive(0);
        return;
    }
    const state = json.str(ts, "state") orelse "disabled";
    t.serve.setActive(@intFromBool(panel.serving));
    const open = json.boolean(ts, "allow_tailnet_members") orelse settings.current.tailscale_open;
    if (panel.serving) t.limit.setActive(@intFromBool(!open));
    const login = json.str(json.get(ts, "account"), "login_name");
    const limit_text = if (login) |l| std.fmt.bufPrintSentinel(&buf, "Rex will check the caller is signed in as {s}", .{l}, 0) catch "" else "Rex will check the caller is the Tailscale account that signed the server in";
    t.limit.as(adw.ActionRow).setSubtitle(limit_text.ptr);

    var tags: std.ArrayList(u8) = .empty;
    defer tags.deinit(gpa);
    for (json.array(ts, "tags")) |tag| switch (tag) {
        .string => |x| {
            if (tags.items.len > 0) tags.appendSlice(gpa, ", ") catch {};
            tags.appendSlice(gpa, x) catch {};
        },
        else => {},
    };
    tags.append(gpa, 0) catch {};
    t.tags.setText(if (tags.items.len > 1) @ptrCast(tags.items.ptr) else "None");
    const ctl = std.fmt.bufPrintSentinel(&buf, "{s}", .{json.str(ts, "control_url") orelse "Tailscale"}, 0) catch "Tailscale";
    t.control_server.setText(ctl.ptr);
    // The name shows once, so a reading never writes over one being typed.
    if (!panel.hostname_shown) {
        panel.hostname_shown = true;
        const dns = json.str(ts, "dns_name") orelse "";
        const name = if (settings.current.tailscale_hostname.len > 0) settings.current.tailscale_hostname else dns[0 .. std.mem.indexOfScalar(u8, dns, '.') orelse dns.len];
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch "";
        t.hostname.as(gtk.Editable).setText(z.ptr);
    }

    var settled = true;
    if (eql(u8, state, "disabled")) {
        t.account.as(adw.PreferencesRow).setTitle("Not serving over Tailscale");
        const sub = if (json.str(ts, "error")) |e| std.fmt.bufPrintSentinel(&buf, "Turned off: {s}", .{e}, 0) catch "" else "Turn on Serve over Tailscale to sign in and give this server an address on your tailnet";
        t.account.setSubtitle(sub.ptr);
    } else if (eql(u8, state, "needs_login")) {
        t.account.as(adw.PreferencesRow).setTitle("Not signed in to Tailscale");
        t.account.setSubtitle("Sign in to put this server on your tailnet");
        setStr(&panel.auth_url, json.str(ts, "auth_url"));
        panel.account_action = .sign_in;
        t.account_button.setLabel("Sign In");
        t.account_button.as(gtk.Widget).addCssClass("suggested-action");
        t.account_button.as(gtk.Widget).setVisible(1);
        settled = false;
    } else if (eql(u8, state, "needs_machine_approval")) {
        t.account.as(adw.PreferencesRow).setTitle("Waiting for approval");
        t.account.setSubtitle("Your tailnet's admin must approve this server's device");
        settled = false;
    } else if (eql(u8, state, "running")) {
        t.account.as(adw.PreferencesRow).setTitle("Signed in to Tailscale");
        const sub = if (login) |l| std.fmt.bufPrintSentinel(&buf, "Signed in as {s}", .{l}, 0) catch "" else "Signed in";
        t.account.setSubtitle(sub.ptr);
        panel.account_action = .sign_out;
        t.account_button.setLabel("Sign Out…");
        t.account_button.as(gtk.Widget).removeCssClass("suggested-action");
        t.account_button.as(gtk.Widget).setVisible(1);
        if (panel.address == null) settled = false;
    } else {
        t.account.as(adw.PreferencesRow).setTitle("Starting Tailscale…");
        t.account.setSubtitle("");
        settled = false;
    }
    // While a change is under way, look again shortly, as long as Settings is still open.
    if (!settled and panel.timer == 0) {
        _ = p.as(gobject.Object).ref();
        panel.timer = glib.timeoutAdd(1500, &poll, p);
    }
}

fn poll(data: ?*anyopaque) callconv(.c) c_int {
    const p: *adw.PreferencesPage = @ptrCast(@alignCast(data.?));
    defer p.as(gobject.Object).unref();
    if (Panel.of(p)) |panel| panel.timer = 0;
    if (p.as(gtk.Widget).getRoot() != null) read(p);
    return 0;
}

// What the person does.

fn startStopClicked(_: *gtk.Button, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    if (!panel.running) {
        panel.server_row.setSubtitle("Starting…");
        return run(p, &.{ "rex", "server", "start" }, .started);
    }
    const dialog = adw.AlertDialog.new("Stop the Rex server?", "Every program running in its sessions ends.");
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("stop", "Stop Server");
    dialog.setResponseAppearance("stop", .destructive);
    dialog.setDefaultResponse("cancel");
    dialog.setCloseResponse("cancel");
    _ = p.as(gobject.Object).ref();
    _ = adw.AlertDialog.signals.response.connect(dialog, *adw.PreferencesPage, &stopAnswered, p, .{});
    dialog.as(adw.Dialog).present(p.as(gtk.Widget));
}

fn stopAnswered(_: *adw.AlertDialog, response: [*:0]const u8, p: *adw.PreferencesPage) callconv(.c) void {
    defer p.as(gobject.Object).unref();
    if (!eql(u8, std.mem.span(response), "stop")) return;
    const panel = Panel.of(p) orelse return;
    panel.server_row.setSubtitle("Stopping…");
    run(p, &.{ "rex", "--autostart=false", "-S", panel.url, "server", "stop" }, .read);
}

/// Rex here comes from the system's packages, so updating it is the package manager's job,
/// done in a tab where it can ask for a password.
fn updateClicked(_: *gtk.Button, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    const restart = " && echo && echo 'Restart the Rex server to run the new version: Settings, Server, Stop Server, then Start Server.'";
    const command: []const u8 = if (have("pacman"))
        "sudo pacman -Syu rex" ++ restart
    else if (have("apt-get"))
        "sudo apt-get update && sudo apt-get install --only-upgrade rex" ++ restart
    else if (have("dnf"))
        "sudo dnf upgrade rex" ++ restart
    else
        return panel.app.toastText("Update the rex package with your package manager");
    panel.app.runInNewTab(command);
}

fn have(program: [:0]const u8) bool {
    const path = glib.findProgramInPath(program.ptr) orelse return false;
    glib.free(path);
    return true;
}

fn copyClicked(_: *gtk.Button, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    const addr = panel.address orelse return;
    p.as(gtk.Widget).getClipboard().setText(addr.ptr);
    panel.app.toastText("Address copied");
}

fn pairClicked(_: *gtk.Button, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    const addr = panel.address orelse return;
    @import("pairing.zig").open(p.as(gtk.Widget), addr);
}

fn lookToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, a: *App) callconv(.c) void {
    settings.current.rex_updates = row.getActive() != 0;
    settings.save();
    a.lookForUpdates();
}

fn serveToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    if (panel.syncing) return;
    const on = row.getActive() != 0;
    settings.current.local_tailscale = on;
    settings.save();
    if (panel.tailnet) |t| {
        t.account.as(adw.PreferencesRow).setTitle(if (on) "Starting Tailscale…" else "Turning off…");
        t.account.setSubtitle("");
    }
    if (!on) return run(p, &.{ "rex", "--autostart=false", "-S", panel.url, "server", "tailscale", "off" }, .read);
    var buf: [96]u8 = undefined;
    var argv: [9][:0]const u8 = undefined;
    run(p, Server.tailscaleOnArgv(panel.url, &buf, &argv), .read);
}

fn limitToggled(row: *adw.SwitchRow, _: *gobject.ParamSpec, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    if (panel.syncing) return;
    settings.current.tailscale_open = row.getActive() == 0;
    settings.save();
    // Who may connect is given with every `on`, and applies at once to a device that's on.
    if (!panel.serving) return;
    var buf: [96]u8 = undefined;
    var argv: [9][:0]const u8 = undefined;
    run(p, Server.tailscaleOnArgv(panel.url, &buf, &argv), .read);
}

fn accountClicked(_: *gtk.Button, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    if (panel.account_action == .sign_in) {
        const url = panel.auth_url orelse {
            // No link yet: ask Tailscale for one; the next reading shows it.
            return run(p, &.{ "rex", "--autostart=false", "-S", panel.url, "server", "tailscale", "login" }, .read);
        };
        const launcher = gtk.UriLauncher.new(url.ptr);
        defer launcher.unref();
        launcher.launch(null, null, null, null);
        return;
    }
    const dialog = adw.AlertDialog.new("Sign out of Tailscale?", "The server leaves your tailnet. Turning on Serve over Tailscale again asks you to sign in again.");
    dialog.addResponse("cancel", "Cancel");
    dialog.addResponse("out", "Sign Out");
    dialog.setResponseAppearance("out", .destructive);
    dialog.setDefaultResponse("cancel");
    dialog.setCloseResponse("cancel");
    _ = p.as(gobject.Object).ref();
    _ = adw.AlertDialog.signals.response.connect(dialog, *adw.PreferencesPage, &signOutAnswered, p, .{});
    dialog.as(adw.Dialog).present(p.as(gtk.Widget));
}

fn signOutAnswered(_: *adw.AlertDialog, response: [*:0]const u8, p: *adw.PreferencesPage) callconv(.c) void {
    defer p.as(gobject.Object).unref();
    if (!eql(u8, std.mem.span(response), "out")) return;
    const panel = Panel.of(p) orelse return;
    // Signed out, the device can't come back on its own, so Renux stops turning it on.
    settings.current.local_tailscale = false;
    settings.save();
    run(p, &.{ "rex", "--autostart=false", "-S", panel.url, "server", "tailscale", "logout" }, .read);
}

fn hostnameApplied(row: *adw.EntryRow, p: *adw.PreferencesPage) callconv(.c) void {
    const panel = Panel.of(p) orelse return;
    const name = std.mem.trim(u8, std.mem.span(row.as(gtk.Editable).getText()), " ");
    settings.setString(&settings.current.tailscale_hostname, name);
    // A device that's on takes the new name now; one that's off asks for it when it starts.
    if (!panel.serving or name.len == 0) return;
    const z = gpa.dupeSentinel(u8, name, 0) catch return;
    defer gpa.free(z);
    run(p, &.{ "rex", "--autostart=false", "-S", panel.url, "server", "tailscale", "rename", z }, .read);
}
