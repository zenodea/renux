//! One Rex server: the control connection with its reconnects, the sessions and their views, and
//! the terminal streams of the blocks on screen. Main thread only.
const std = @import("std");
const glib = @import("glib");
const control = @import("control.zig");
const json = @import("json.zig");
const view = @import("view.zig");
const stream_mod = @import("stream.zig");
const Control = control.Control;
const Result = control.Result;
const Stream = stream_mod.Stream;

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.server);

pub const version = "0.1.0";

pub const State = enum { connecting, online, offline };

pub const Session = struct {
    id: []u8,
    label: []u8,
};

pub const Change = enum { state, sessions, view, message };

pub const Observer = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque, what: Change, session_id: ?[]const u8) void,
};

pub const Server = struct {
    url: []u8,
    client_label: []u8,
    control: ?*Control = null,
    /// The connection being opened or in use. Only its close counts.
    attempt: ?*Control = null,
    wanted: bool = true,
    state: State = .connecting,
    reason: std.ArrayList(u8) = .empty,
    /// The last error from an action, for showing to the person.
    message: std.ArrayList(u8) = .empty,
    reconnect_token: ?[]u8 = null,
    retries: u5 = 0,
    retry_timer: c_uint = 0,
    rex_version: ?[]u8 = null,
    sessions: std.ArrayList(Session) = .empty,
    views: std.StringHashMapUnmanaged(*view.SessionView) = .empty,
    /// Sessions whose view is being fetched, and whether to fetch once more afterwards.
    fetching: std.StringHashMapUnmanaged(bool) = .empty,
    attached: std.StringHashMapUnmanaged(void) = .empty,
    streams: std.StringHashMapUnmanaged(*Stream) = .empty,
    host_colors: ?stream_mod.Colors = null,
    observer: ?Observer = null,

    pub fn create(url: []const u8) !*Server {
        const s = try gpa.create(Server);
        const host = std.mem.span(glib.getHostName());
        s.* = .{
            .url = try gpa.dupe(u8, std.mem.trimEnd(u8, url, "/")),
            .client_label = try gpa.dupe(u8, host),
        };
        s.startConnecting();
        return s;
    }

    pub fn destroy(s: *Server) void {
        s.wanted = false;
        if (s.retry_timer != 0) _ = glib.Source.remove(s.retry_timer);
        var it = s.streams.valueIterator();
        while (it.next()) |st| st.*.destroy();
        s.streams.deinit(gpa);
        s.attempt = null;
        if (s.control) |c| c.close();
        s.control = null;
        var vit = s.views.valueIterator();
        while (vit.next()) |v| v.*.destroy();
        s.views.deinit(gpa);
        freeKeys(&s.fetching);
        freeKeys(&s.attached);
        s.clearSessions();
        s.sessions.deinit(gpa);
        s.reason.deinit(gpa);
        s.message.deinit(gpa);
        if (s.reconnect_token) |t| gpa.free(t);
        if (s.rex_version) |v| gpa.free(v);
        gpa.free(s.url);
        gpa.free(s.client_label);
        gpa.destroy(s);
    }

    fn notify(s: *Server, what: Change, session_id: ?[]const u8) void {
        if (s.observer) |o| o.changed(o.ctx, what, session_id);
    }

    fn setState(s: *Server, state: State, reason: []const u8) void {
        s.state = state;
        s.reason.clearRetainingCapacity();
        s.reason.appendSlice(gpa, reason) catch {};
        s.notify(.state, null);
    }

    fn showMessage(s: *Server, text: []const u8) void {
        s.message.clearRetainingCapacity();
        s.message.appendSlice(gpa, text) catch {};
        s.notify(.message, null);
    }

    // Connecting.

    fn startConnecting(s: *Server) void {
        s.setState(.connecting, "");
        const c = Control.open(s.url, s.client_label, version, s.reconnect_token, .{
            .ctx = s,
            .on_welcome = onWelcome,
            .on_event = onEvent,
            .on_closed = onClosed,
        }) catch {
            s.scheduleReconnect("Couldn't start a connection");
            return;
        };
        s.attempt = c;
    }

    fn scheduleReconnect(s: *Server, reason: []const u8) void {
        if (!s.wanted) return;
        s.setState(.offline, reason);
        const wait: c_uint = @min(30_000, @as(c_uint, 1000) << @min(s.retries, 5));
        if (s.retries < 31) s.retries += 1;
        if (s.retry_timer != 0) _ = glib.Source.remove(s.retry_timer);
        s.retry_timer = glib.timeoutAdd(wait, &retryNow, s);
    }

    fn retryNow(data: ?*anyopaque) callconv(.c) c_int {
        const s: *Server = @ptrCast(@alignCast(data.?));
        s.retry_timer = 0;
        if (s.wanted and s.control == null and s.attempt == null) s.startConnecting();
        return 0;
    }

    /// Connects again right away, such as when the person asks to.
    pub fn retry(s: *Server) void {
        if (s.attempt != null) return;
        if (s.retry_timer != 0) _ = glib.Source.remove(s.retry_timer);
        s.retry_timer = 0;
        s.retries = 0;
        s.startConnecting();
    }

    /// Only the first report from the current connection counts; older ones closing later, or a
    /// failure reported twice, must not start extra retry loops.
    fn failed(s: *Server, from: *Control, reason: []const u8) void {
        if (from != s.attempt) return;
        s.attempt = null;
        s.control = null;
        from.abandon();
        s.scheduleReconnect(reason);
    }

    fn onWelcome(ctx: *anyopaque, c: *Control, w: control.Welcome) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        if (c != s.attempt) return;
        if (s.reconnect_token) |t| gpa.free(t);
        s.reconnect_token = if (w.reconnect_token) |t| gpa.dupe(u8, t) catch null else null;
        if (w.api_revision != control.api_revision) {
            log.warn("server uses API revision {d}; Compy was written for {d}", .{ w.api_revision, control.api_revision });
        }
        if (!w.resumed) freeKeys(&s.attached);

        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(gpa);
        var it = s.attached.keyIterator();
        while (it.next()) |k| ids.append(gpa, k.*) catch {};
        c.callTimeout("session.bootstrap", .{ .event_scope = "all", .attach_session_ids = ids.items }, 30_000, control.Callback.of(Server, s, bootstrapped));
    }

    fn bootstrapped(s: *Server, r: Result) void {
        const c = s.attempt orelse return;
        switch (r) {
            .err => |e| return s.failed(c, e.message),
            .ok => |payload| {
                s.control = c;
                if (s.rex_version) |v| gpa.free(v);
                s.rex_version = if (json.str(json.get(payload, "server_status"), "rex_version")) |v| gpa.dupe(u8, v) catch null else null;
                s.clearSessions();
                for (json.array(json.get(payload, "attach_all"), "sessions")) |item| {
                    const id = json.str(item, "session_id") orelse continue;
                    s.sessions.append(gpa, .{
                        .id = gpa.dupe(u8, id) catch continue,
                        .label = gpa.dupe(u8, json.str(item, "label") orelse "") catch continue,
                    }) catch {};
                }
                s.dropViewsOfGoneSessions();
                for (s.sessions.items) |session| s.refreshView(session.id, -1);
                s.retries = 0;
                s.setState(.online, "");
                s.notify(.sessions, null);

                // Streams carry on; any whose session ended while away are dropped.
                var gone: std.ArrayList([]const u8) = .empty;
                defer gone.deinit(gpa);
                var it = s.streams.iterator();
                while (it.next()) |e| {
                    if (s.hasSession(e.value_ptr.*.session_id)) {
                        e.value_ptr.*.reconnect();
                    } else {
                        gone.append(gpa, e.key_ptr.*) catch {};
                    }
                }
                for (gone.items) |k| s.releaseTerminal(k);
            },
        }
    }

    fn onClosed(ctx: *anyopaque, c: *Control, reason: []const u8, _: u16) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        if (c != s.attempt) {
            c.abandon();
            return;
        }
        s.failed(c, reason);
    }

    // Events.

    fn onEvent(ctx: *anyopaque, c: *Control, kind: []const u8, payload: ?json.Value) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        if (c != s.control and c != s.attempt) return;
        if (eql(kind, "session_created")) {
            const session = json.get(payload, "session");
            const id = json.str(session, "session_id") orelse return;
            if (!s.hasSession(id)) {
                s.sessions.append(gpa, .{
                    .id = gpa.dupe(u8, id) catch return,
                    .label = gpa.dupe(u8, json.str(session, "label") orelse "") catch return,
                }) catch return;
                s.notify(.sessions, null);
            }
            s.refreshView(id, -1);
        } else if (eql(kind, "session_destroyed")) {
            const id = json.str(payload, "session_id") orelse return;
            s.removeSession(id);
        } else if (eql(kind, "session_moved")) {
            s.call("session.list", .{}, void, {}, listed);
        } else if (eql(kind, "client_perform_requested")) {
            s.handlePerform(payload orelse return);
        } else if (eql(kind, "client_call_requested")) {
            // Compy never lists other servers with an action, but the action would wait for an answer.
            s.reply(json.str(payload, "call_id") orelse return, "not_supported", "Compy can't call other servers");
        } else if (eql(kind, "session_event")) {
            const session_id = json.str(payload, "session_id") orelse return;
            const event = json.get(payload, "event");
            s.handleSessionEvent(session_id, json.str(event, "type") orelse "", json.get(event, "payload"));
        }
    }

    fn handleSessionEvent(s: *Server, session_id: []const u8, kind: []const u8, payload: ?json.Value) void {
        if (eql(kind, "session_view_changed")) {
            s.refreshView(session_id, json.int(payload, "revision") orelse -1);
        } else if (eql(kind, "session_label_changed")) {
            const label = json.str(payload, "label") orelse return;
            for (s.sessions.items) |*session| if (eql(session.id, session_id)) {
                const copy = gpa.dupe(u8, label) catch return;
                gpa.free(session.label);
                session.label = copy;
            };
            s.notify(.sessions, null);
        } else if (eql(kind, "block_closed")) {
            const id = json.str(payload, "block_id") orelse return;
            s.releaseTerminal(id);
        }
    }

    fn listed(s: *Server, _: *void, r: Result) void {
        const payload = switch (r) {
            .ok => |p| p,
            .err => return,
        };
        const items = json.array(payload, "sessions");
        if (items.len == 0) return;
        s.clearSessions();
        for (items) |item| {
            const id = json.str(item, "session_id") orelse continue;
            s.sessions.append(gpa, .{
                .id = gpa.dupe(u8, id) catch continue,
                .label = gpa.dupe(u8, json.str(item, "label") orelse "") catch continue,
            }) catch {};
        }
        s.notify(.sessions, null);
    }

    /// Rex actions can ask the client that started them to do something and wait for the answer,
    /// so every request gets one, even if it's only that Compy can't do it.
    fn handlePerform(s: *Server, payload: json.Value) void {
        const call_id = json.str(payload, "call_id") orelse return;
        if (eql(json.str(payload, "action") orelse "", "session.select")) {
            const args = json.get(payload, "args");
            if (json.str(args, "window_id")) |w| if (json.str(args, "session_id") orelse json.str(payload, "session_id")) |sid| {
                s.focusWindow(sid, w);
            };
            s.reply(call_id, null, null);
        } else {
            s.reply(call_id, "not_supported", "Compy can't do that yet");
        }
    }

    fn reply(s: *Server, call_id: []const u8, code: ?[]const u8, message: ?[]const u8) void {
        const c = s.control orelse return;
        if (code) |k| {
            c.fire("client.reply", .{ .call_id = call_id, .@"error" = .{ .code = k, .message = message orelse "" } });
        } else {
            c.fire("client.reply", .{ .call_id = call_id, .result = null });
        }
    }

    // Sessions and views.

    fn hasSession(s: *Server, id: []const u8) bool {
        for (s.sessions.items) |session| if (eql(session.id, id)) return true;
        return false;
    }

    pub fn sessionView(s: *Server, id: []const u8) ?*view.SessionView {
        return s.views.get(id);
    }

    fn clearSessions(s: *Server) void {
        for (s.sessions.items) |session| {
            gpa.free(session.id);
            gpa.free(session.label);
        }
        s.sessions.clearRetainingCapacity();
    }

    fn removeSession(s: *Server, id: []const u8) void {
        var i: usize = 0;
        while (i < s.sessions.items.len) {
            const session = s.sessions.items[i];
            if (eql(session.id, id)) {
                _ = s.sessions.orderedRemove(i);
                s.dropView(id);
                if (s.attached.fetchRemove(id)) |e| gpa.free(e.key);
                gpa.free(session.id);
                gpa.free(session.label);
            } else i += 1;
        }
        s.notify(.sessions, null);
    }

    fn dropView(s: *Server, id: []const u8) void {
        if (s.views.fetchRemove(id)) |e| e.value.destroy();
    }

    fn dropViewsOfGoneSessions(s: *Server) void {
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(gpa);
        var it = s.views.keyIterator();
        while (it.next()) |k| if (!s.hasSession(k.*)) gone.append(gpa, k.*) catch {};
        for (gone.items) |k| s.dropView(k);
    }

    pub fn refreshView(s: *Server, session_id: []const u8, if_newer_than: i64) void {
        if (s.views.get(session_id)) |known| if (if_newer_than >= 0 and if_newer_than <= known.revision) return;
        if (s.fetching.getPtr(session_id)) |again| {
            // A fetch is in flight, but it may predate this change, so fetch again afterwards.
            again.* = true;
            return;
        }
        const key = gpa.dupe(u8, session_id) catch return;
        s.fetching.put(gpa, key, false) catch return;
        s.call("session.view", .{ .session_id = session_id }, Owned, .{ .text = gpa.dupe(u8, session_id) catch return }, fetchedView);
    }

    fn fetchedView(s: *Server, id: *Owned, r: Result) void {
        const session_id = id.text;
        const again = if (s.fetching.fetchRemove(session_id)) |e| blk: {
            gpa.free(e.key);
            break :blk e.value;
        } else false;
        switch (r) {
            .ok => |payload| s.applyView(payload),
            .err => {},
        }
        if (again) s.refreshView(session_id, -1);
    }

    fn applyView(s: *Server, payload: ?json.Value) void {
        if (std.c.getenv("COMPY_DEBUG") != null) {
            const text = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch "";
            defer gpa.free(text);
            log.info("view: {s}", .{text[0..@min(text.len, 600)]});
        }
        const v = (view.parse(payload) catch return) orelse return;
        if (!s.hasSession(v.session_id)) {
            v.destroy();
            return;
        }
        if (s.views.get(v.session_id)) |old| if (old.revision > v.revision) {
            v.destroy();
            return;
        };
        const entry = s.views.getOrPut(gpa, v.session_id) catch return v.destroy();
        if (entry.found_existing) entry.value_ptr.*.destroy();
        // The key points into the view, so replace it with the new one's.
        entry.key_ptr.* = v.session_id;
        entry.value_ptr.* = v;
        for (s.sessions.items) |*session| if (eql(session.id, v.session_id) and v.label.len > 0 and !eql(session.label, v.label)) {
            const copy = gpa.dupe(u8, v.label) catch break;
            gpa.free(session.label);
            session.label = copy;
            s.notify(.sessions, null);
        };
        s.notify(.view, v.session_id);
    }

    // Terminals.

    /// The live terminal for a block, connecting its stream on first use.
    pub fn terminal(s: *Server, session_id: []const u8, block_id: []const u8) ?*Stream {
        if (s.streams.get(block_id)) |st| return st;
        const st = Stream.create(s, session_id, block_id) catch return null;
        s.streams.put(gpa, st.block_id, st) catch {
            st.destroy();
            return null;
        };
        return st;
    }

    /// Stops streaming a block that's no longer on screen.
    pub fn releaseTerminal(s: *Server, block_id: []const u8) void {
        if (s.streams.fetchRemove(block_id)) |e| e.value.destroy();
    }

    const TicketFor = struct {
        session_id: []u8,
        block_id: []u8,
        gen: u32,
        fn deinit(t: *TicketFor) void {
            gpa.free(t.session_id);
            gpa.free(t.block_id);
        }
    };

    /// Issues a data ticket for a stream, attaching to its session first.
    pub fn requestTicket(s: *Server, st: *Stream, gen: u32) void {
        const t: TicketFor = .{
            .session_id = gpa.dupe(u8, st.session_id) catch return,
            .block_id = gpa.dupe(u8, st.block_id) catch return,
            .gen = gen,
        };
        if (s.control == null) {
            // It asks again when the connection comes back.
            var copy = t;
            copy.deinit();
            return;
        }
        if (s.attached.contains(st.session_id)) {
            s.call("data.connect", .{ .session_id = st.session_id, .block_id = st.block_id, .data_ref_id = "terminal", .subprotocol = stream_mod.protocol }, TicketFor, t, ticketIssued);
        } else {
            s.call("session.attach", .{ .session_id = st.session_id }, TicketFor, t, attachedForTicket);
        }
    }

    fn attachedForTicket(s: *Server, t: *TicketFor, r: Result) void {
        switch (r) {
            .ok => |payload| {
                s.markAttached(t.session_id);
                if (json.get(payload, "view")) |v| s.applyView(v);
                const copy: TicketFor = .{
                    .session_id = gpa.dupe(u8, t.session_id) catch return,
                    .block_id = gpa.dupe(u8, t.block_id) catch return,
                    .gen = t.gen,
                };
                s.call("data.connect", .{ .session_id = t.session_id, .block_id = t.block_id, .data_ref_id = "terminal", .subprotocol = stream_mod.protocol }, TicketFor, copy, ticketIssued);
            },
            .err => if (s.streams.get(t.block_id)) |st| st.ticketFailed(t.gen),
        }
    }

    fn ticketIssued(s: *Server, t: *TicketFor, r: Result) void {
        const st = s.streams.get(t.block_id) orelse return;
        switch (r) {
            .ok => |payload| if (json.str(payload, "ticket")) |ticket| st.gotTicket(t.gen, ticket) else st.ticketFailed(t.gen),
            .err => st.ticketFailed(t.gen),
        }
    }

    fn markAttached(s: *Server, session_id: []const u8) void {
        if (s.attached.contains(session_id)) return;
        const key = gpa.dupe(u8, session_id) catch return;
        s.attached.put(gpa, key, {}) catch gpa.free(key);
    }

    /// Reads the screen as escape sequences, for when a snapshot can't be decoded.
    pub fn readScreen(s: *Server, st: *Stream) void {
        s.call("com.superlogical.terminal.format", .{ .session_id = st.session_id, .block_id = st.block_id, .args = .{ .format = "vt" } }, Owned, .{ .text = gpa.dupe(u8, st.block_id) catch return }, gotScreen);
    }

    fn gotScreen(s: *Server, block: *Owned, r: Result) void {
        const st = s.streams.get(block.text) orelse return;
        switch (r) {
            .ok => |payload| if (json.str(payload, "content")) |content| st.gotScreen(content),
            .err => {},
        }
    }

    /// A terminal reported the host's colors; every other terminal without its own follows them.
    pub fn gotHostColors(s: *Server, colors: stream_mod.Colors) void {
        s.host_colors = colors;
        var it = s.streams.valueIterator();
        while (it.next()) |st| st.*.hostColorsChanged();
        s.notify(.state, null);
    }

    // Input. These go out in order without waiting, so typing stays in order.

    pub fn sendKey(s: *Server, session_id: []const u8, block_id: []const u8, key: anytype) void {
        const c = s.control orelse return;
        c.fire("client.key", .{ .session_id = session_id, .block_id = block_id, .key = key });
    }

    pub fn paste(s: *Server, session_id: []const u8, block_id: []const u8, text: []const u8) void {
        const c = s.control orelse return;
        c.fire("block.event", .{ .session_id = session_id, .block_id = block_id, .event = .{ .type = "paste", .payload = .{ .text = text } } });
    }

    pub fn sendFocus(s: *Server, session_id: []const u8, block_id: []const u8, focused: bool) void {
        const c = s.control orelse return;
        c.fire("block.event", .{ .session_id = session_id, .block_id = block_id, .event = .{ .type = "focus", .payload = .{ .action = if (focused) "in" else "out" } } });
    }

    pub fn sendWheel(s: *Server, session_id: []const u8, block_id: []const u8, lines: f64, col: u16, row: u16) void {
        const c = s.control orelse return;
        c.fire("block.event", .{ .session_id = session_id, .block_id = block_id, .event = .{ .type = "wheel", .payload = .{
            .delta_mode = "line",
            .delta_x = 0,
            .delta_y = lines,
            .x = col,
            .y = row,
            .pixel = null,
            .mods = "",
        } } });
    }

    pub fn sendMouse(s: *Server, session_id: []const u8, block_id: []const u8, action: []const u8, button: []const u8, col: u16, row: u16) void {
        const c = s.control orelse return;
        c.fire("block.event", .{ .session_id = session_id, .block_id = block_id, .event = .{ .type = "mouse", .payload = .{
            .action = action,
            .button = button,
            .buttons = Buttons{ .name = button, .pressed = eql(action, "press") },
            .x = col,
            .y = row,
            .pixel = null,
            .mods = "",
        } } });
    }

    /// Rex wants the held buttons as {"left": true} on a press and null otherwise.
    const Buttons = struct {
        name: []const u8,
        pressed: bool,
        pub fn jsonStringify(b: Buttons, jw: anytype) !void {
            if (!b.pressed) return jw.write(null);
            try jw.beginObject();
            try jw.objectField(b.name);
            try jw.write(true);
            try jw.endObject();
        }
    };

    // Changes. Failures are shown to the person.

    /// Fits a block to this window: asks for the size, then takes ownership so it applies now.
    pub fn fitBlock(s: *Server, session_id: []const u8, block_id: []const u8, cols: u16, rows: u16, cell_w: u32, cell_h: u32) void {
        s.act(session_id, "com.superlogical.terminal.resize", .{ .session_id = session_id, .block_id = block_id, .args = .{
            .columns = cols,
            .rows = rows,
            .cell_width_px = std.math.clamp(cell_w, 1, 65535),
            .cell_height_px = std.math.clamp(cell_h, 1, 65535),
        } });
        s.act(session_id, "session.own_block", .{ .session_id = session_id, .block_ids = &[_][]const u8{block_id}, .mode = "take" });
    }

    pub fn focusBlock(s: *Server, session_id: []const u8, block_id: []const u8) void {
        s.act(session_id, "session.focus_block", .{ .session_id = session_id, .block_id = block_id });
    }

    pub fn focusWindow(s: *Server, session_id: []const u8, window_id: []const u8) void {
        s.act(session_id, "session.focus_window", .{ .session_id = session_id, .window_id = window_id });
    }

    pub fn closeBlock(s: *Server, session_id: []const u8, block_id: []const u8) void {
        s.act(session_id, "block.close", .{ .session_id = session_id, .block_id = block_id });
    }

    pub fn zoomBlock(s: *Server, session_id: []const u8, block_id: []const u8, zoom: bool) void {
        s.act(session_id, "session.zoom_block", .{ .session_id = session_id, .block_id = block_id, .zoom = zoom });
    }

    const shell_layout = .{ .block = .{ .flavor = "com.superlogical.terminal.shell" } };

    /// Splits the pane showing `anchor_id`, putting a new shell beside it or below it.
    pub fn newSplit(s: *Server, session_id: []const u8, anchor_id: []const u8, horizontal: bool, before: bool) void {
        s.act(session_id, "session.new_split", .{
            .session_id = session_id,
            .anchor_id = anchor_id,
            .direction = if (horizontal) "horizontal" else "vertical",
            .side = if (before) "before" else "after",
            .layout = shell_layout,
            .focus = true,
        });
    }

    pub fn resizePane(s: *Server, session_id: []const u8, horizontal: bool, before_id: []const u8, after_id: []const u8, ratio: f64) void {
        s.act(session_id, "session.resize_pane", .{
            .session_id = session_id,
            .direction = if (horizontal) "horizontal" else "vertical",
            .before_block_id = before_id,
            .after_block_id = after_id,
            .ratio = std.math.clamp(ratio, 0.05, 0.95),
        });
    }

    pub fn newWindow(s: *Server, session_id: []const u8) void {
        s.act(session_id, "session.new_window", .{ .session_id = session_id, .layout = shell_layout });
    }

    pub fn closeWindow(s: *Server, session_id: []const u8, window_id: []const u8) void {
        s.act(session_id, "session.close_window", .{ .session_id = session_id, .window_id = window_id });
    }

    pub fn createSession(s: *Server, label: []const u8) void {
        if (s.control == null) return s.showMessage("Not connected to the server");
        s.call("session.create", .{
            .label = label,
            .initial_windows = &[_]@TypeOf(.{ .layout = shell_layout }){.{ .layout = shell_layout }},
        }, void, {}, acted);
    }

    pub fn destroySession(s: *Server, session_id: []const u8) void {
        s.act(session_id, "session.destroy", .{ .session_id = session_id });
    }

    const Pending = struct {
        session_id: []u8,
        method: []u8,
        payload: []u8,
        fn deinit(p: *Pending) void {
            gpa.free(p.session_id);
            gpa.free(p.method);
            gpa.free(p.payload);
        }
    };

    /// Runs a change in a session, attaching to it first if needed. Failures are shown.
    fn act(s: *Server, session_id: []const u8, method: []const u8, payload: anytype) void {
        if (s.control == null) return s.showMessage("Not connected to the server");
        if (s.attached.contains(session_id)) {
            s.call(method, payload, void, {}, acted);
            return;
        }
        const encoded = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch return;
        const p: Pending = .{
            .session_id = gpa.dupe(u8, session_id) catch return gpa.free(encoded),
            .method = gpa.dupe(u8, method) catch return gpa.free(encoded),
            .payload = encoded,
        };
        s.call("session.attach", .{ .session_id = session_id }, Pending, p, attachedForAct);
    }

    fn attachedForAct(s: *Server, p: *Pending, r: Result) void {
        switch (r) {
            .ok => |payload| {
                s.markAttached(p.session_id);
                if (json.get(payload, "view")) |v| s.applyView(v);
                s.call(p.method, json.Raw{ .text = p.payload }, void, {}, acted);
            },
            .err => |e| s.showMessage(e.message),
        }
    }

    fn acted(s: *Server, _: *void, r: Result) void {
        switch (r) {
            .ok => {},
            .err => |e| s.showMessage(e.message),
        }
    }

    /// Calls `method` and hands the result to `handler` along with `extra`, which the call owns.
    fn call(s: *Server, method: []const u8, payload: anytype, comptime Extra: type, extra: Extra, comptime handler: fn (*Server, *Extra, Result) void) void {
        const Ctx = struct {
            server: *Server,
            extra: Extra,
            fn done(ctx: *@This(), r: Result) void {
                handler(ctx.server, &ctx.extra, r);
                if (comptime hasDeinit(Extra)) ctx.extra.deinit();
                gpa.destroy(ctx);
            }
        };
        const ctx = gpa.create(Ctx) catch return;
        ctx.* = .{ .server = s, .extra = extra };
        const c = s.control orelse s.attempt orelse {
            Ctx.done(ctx, .{ .err = .{ .code = "disconnected", .message = "Not connected to the server" } });
            return;
        };
        c.call(method, payload, control.Callback.of(Ctx, ctx, Ctx.done));
    }
};

/// A string a call owns until it finishes.
const Owned = struct {
    text: []u8,
    fn deinit(o: *Owned) void {
        gpa.free(o.text);
    }
};

fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "deinit"),
        else => false,
    };
}

fn freeKeys(map: anytype) void {
    var it = map.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    map.clearAndFree(gpa);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
