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

pub const Change = enum { state, sessions, view, message, block, alert, keymap };

/// An action from the person's Rex config that Compy can run, with the keys bound to it.
pub const Action = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    category: []const u8,
    keywords: []const u8,
    keys: []const u8,
    args: ?[]const u8,
    needs_args: bool,
};

pub const StatusKind = enum { working, blocked, done, failed, other };

/// What a program in a terminal last reported with OSC 7501, and what it runs and where.
pub const BlockInfo = struct {
    status: StatusKind = .other,
    has_status: bool = false,
    status_app: ?[]u8 = null,
    status_kind: ?[]u8 = null,
    message: ?[]u8 = null,
    program: ?[]u8 = null,
    folder: ?[]u8 = null,
    title: ?[]u8 = null,
    /// Percent done, -1 for work without a known end, or null.
    progress: ?i32 = null,
    /// Finished, failed, needs you, or rang the bell, and not looked at since.
    attention: bool = false,

    fn deinit(b: *BlockInfo) void {
        inline for (.{ "status_app", "status_kind", "message", "program", "folder", "title" }) |f| {
            if (@field(b, f)) |v| gpa.free(v);
            @field(b, f) = null;
        }
    }
};

fn setStr(slot: *?[]u8, value: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (value) |v| gpa.dupe(u8, v) catch null else null;
}

pub const Observer = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque, what: Change, session_id: ?[]const u8) void,
};

pub const Performer = struct {
    ctx: *anyopaque,
    perform: *const fn (ctx: *anyopaque, action: []const u8, args: ?json.Value, session_id: ?[]const u8) bool,
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
    blocks: std.StringHashMapUnmanaged(BlockInfo) = .empty,
    /// The last alert, for the window to show as a notification.
    alert_text: std.ArrayList(u8) = .empty,
    alert_session: std.ArrayList(u8) = .empty,
    alert_block: std.ArrayList(u8) = .empty,
    host_colors: ?stream_mod.Colors = null,
    observer: ?Observer = null,
    keymap_arena: std.heap.ArenaAllocator = .init(gpa),
    actions: []Action = &.{},
    /// Runs the client.* actions a key binding or script asks this client for. True if done.
    performer: ?Performer = null,

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
        var bit = s.blocks.iterator();
        while (bit.next()) |e| {
            e.value_ptr.deinit();
            gpa.free(e.key_ptr.*);
        }
        s.blocks.deinit(gpa);
        s.alert_text.deinit(gpa);
        s.alert_session.deinit(gpa);
        s.alert_block.deinit(gpa);
        freeKeys(&s.fetching);
        freeKeys(&s.attached);
        s.clearSessions();
        s.sessions.deinit(gpa);
        s.reason.deinit(gpa);
        s.message.deinit(gpa);
        s.keymap_arena.deinit();
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

    pub fn notifyMessage(s: *Server, text: []const u8) void {
        s.showMessage(text);
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
                s.fetchKeymap();
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
        if (std.c.getenv("COMPY_DEBUG") != null) {
            const text = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch "";
            defer gpa.free(text);
            log.info("event {s}: {s}", .{ kind, text[0..@min(text.len, 300)] });
        }
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
            if (s.blocks.fetchRemove(id)) |e| {
                var info = e.value;
                info.deinit();
                gpa.free(e.key);
            }
            s.releaseTerminal(id);
        } else if (eql(kind, "block_event")) {
            s.handleBlockEvent(session_id, payload orelse return);
        }
    }

    // Block details: status, program, folder and title.

    pub fn blockInfo(s: *Server, block_id: []const u8) ?*BlockInfo {
        return s.blocks.getPtr(block_id);
    }

    fn infoFor(s: *Server, block_id: []const u8) ?*BlockInfo {
        if (s.blocks.getPtr(block_id)) |b| return b;
        const key = gpa.dupe(u8, block_id) catch return null;
        s.blocks.put(gpa, key, .{}) catch {
            gpa.free(key);
            return null;
        };
        return s.blocks.getPtr(block_id);
    }

    /// Marks a block looked at, such as when its pane is shown and focused.
    pub fn clearAttention(s: *Server, block_id: []const u8) void {
        const b = s.blocks.getPtr(block_id) orelse return;
        if (!b.attention) return;
        b.attention = false;
        s.notify(.block, block_id);
    }

    fn handleBlockEvent(s: *Server, session_id: []const u8, payload: json.Value) void {
        const block = json.str(payload, "block_id") orelse return;
        const name = json.str(payload, "name") orelse return;
        const fields = json.get(payload, "payload");
        const b = s.infoFor(block) orelse return;
        if (eql(name, "program_status_changed")) {
            const was_blocked = b.has_status and b.status == .blocked;
            s.setStatus(b, json.get(fields, "record"));
            if (b.status == .done or b.status == .blocked or b.status == .failed) b.attention = true;
            if (b.status == .blocked and !was_blocked) {
                var buf: [256]u8 = undefined;
                const who = b.status_app orelse "A program";
                const k = b.status_kind orelse "";
                const what = if (eql(k, "permission")) "needs your permission" else if (eql(k, "question")) "has a question" else if (eql(k, "auth")) "needs a password" else "needs you";
                s.raiseAlert(session_id, block, std.fmt.bufPrint(&buf, "{s} {s}", .{ who, what }) catch "A program needs you");
            } else if (b.status == .done or b.status == .failed) {
                var buf: [256]u8 = undefined;
                const who = b.status_app orelse "A program";
                s.raiseAlert(session_id, block, std.fmt.bufPrint(&buf, "{s} {s}", .{ who, if (b.status == .done) "finished" else "failed" }) catch "A program finished");
            }
        } else if (eql(name, "program_status_removed")) {
            b.has_status = false;
            b.status = .other;
            setStr(&b.message, null);
        } else if (eql(name, "process_changed")) {
            s.setProgram(b, json.get(fields, "foreground"));
        } else if (eql(name, "pwd_changed")) {
            setStr(&b.folder, json.str(fields, "pwd"));
        } else if (eql(name, "title_changed")) {
            setStr(&b.title, json.str(fields, "title"));
        } else if (eql(name, "bell")) {
            b.attention = true;
        } else if (eql(name, "progress_report")) {
            const state = json.str(fields, "state") orelse "";
            const percent = json.int(fields, "progress");
            if (eql(state, "set")) {
                if (percent) |p| b.progress = @intCast(std.math.clamp(p, 0, 100));
            } else if (eql(state, "indeterminate")) {
                b.progress = -1;
            } else if (eql(state, "pause") or eql(state, "error")) {
                if (percent) |p| b.progress = @intCast(std.math.clamp(p, 0, 100));
            } else b.progress = null;
        } else if (eql(name, "desktop_notification")) {
            const title = json.str(fields, "title") orelse "";
            const body = json.str(fields, "body") orelse "";
            var buf: [512]u8 = undefined;
            const text = if (title.len > 0 and body.len > 0) std.fmt.bufPrint(&buf, "{s}: {s}", .{ title, body }) catch title else if (title.len > 0) title else body;
            if (text.len > 0) s.raiseAlert(session_id, block, text);
        } else return;
        s.notify(.block, block);
    }

    fn raiseAlert(s: *Server, session_id: []const u8, block_id: []const u8, text: []const u8) void {
        inline for (.{ .{ &s.alert_text, text }, .{ &s.alert_session, session_id }, .{ &s.alert_block, block_id } }) |e| {
            e[0].clearRetainingCapacity();
            e[0].appendSlice(gpa, e[1]) catch {};
        }
        s.notify(.alert, block_id);
    }

    fn setStatus(_: *Server, b: *BlockInfo, record: ?json.Value) void {
        const r = record orelse return;
        const state = json.str(r, "state") orelse return;
        b.has_status = true;
        b.status = if (eql(state, "working")) .working else if (eql(state, "blocked")) .blocked else if (eql(state, "done")) .done else if (eql(state, "error")) .failed else .other;
        setStr(&b.status_app, json.str(r, "effective_app") orelse json.str(r, "app"));
        setStr(&b.status_kind, json.str(r, "kind"));
        setStr(&b.message, json.str(r, "msg"));
        if (json.int(r, "progress")) |p| b.progress = @intCast(std.math.clamp(p, 0, 100));
    }

    /// An interpreter's script says more than its name, so node running claude counts as claude.
    fn setProgram(_: *Server, b: *BlockInfo, foreground: ?json.Value) void {
        const name = json.str(foreground, "name") orelse return;
        var buf: [256]u8 = undefined;
        const text = if (json.str(foreground, "script")) |script| blk: {
            const base = if (std.mem.lastIndexOfScalar(u8, script, '/')) |i| script[i + 1 ..] else script;
            break :blk std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, base }) catch name;
        } else name;
        setStr(&b.program, text);
    }

    const DetailFor = struct {
        session_id: []u8,
        block_id: []u8,
        which: enum { status, title, process, pwd },
        fn deinit(d: *DetailFor) void {
            gpa.free(d.session_id);
            gpa.free(d.block_id);
        }
    };

    /// Reads what a block runs, where, and its status, once; events keep them current after.
    fn readDetails(s: *Server, session_id: []const u8, block_id: []const u8) void {
        if (s.blocks.contains(block_id)) return;
        _ = s.infoFor(block_id);
        inline for (.{
            .{ "com.superlogical.terminal.program_status", .status },
            .{ "com.superlogical.terminal.title", .title },
            .{ "com.superlogical.terminal.process", .process },
            .{ "com.superlogical.terminal.pwd", .pwd },
        }) |e| {
            const d: DetailFor = .{
                .session_id = gpa.dupe(u8, session_id) catch return,
                .block_id = gpa.dupe(u8, block_id) catch return,
                .which = e[1],
            };
            s.call(e[0], .{ .session_id = session_id, .block_id = block_id }, DetailFor, d, gotDetail);
        }
    }

    fn gotDetail(s: *Server, d: *DetailFor, r: Result) void {
        const payload = switch (r) {
            .ok => |p| p,
            .err => return,
        };
        const b = s.blocks.getPtr(d.block_id) orelse return;
        switch (d.which) {
            .status => {
                // The most urgent record counts.
                var best: ?json.Value = null;
                var best_rank: u8 = 0;
                for (json.array(payload, "records")) |rec| {
                    const st = json.str(rec, "state") orelse continue;
                    const rank: u8 = if (eql(st, "blocked")) 4 else if (eql(st, "error")) 3 else if (eql(st, "working")) 2 else if (eql(st, "done")) 1 else 0;
                    if (best == null or rank > best_rank) {
                        best = rec;
                        best_rank = rank;
                    }
                }
                if (best) |rec| s.setStatus(b, rec);
            },
            .title => setStr(&b.title, json.str(payload, "title")),
            .process => s.setProgram(b, json.get(payload, "foreground")),
            .pwd => setStr(&b.folder, json.str(payload, "pwd")),
        }
        s.notify(.block, d.block_id);
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
        const action = json.str(payload, "action") orelse "";
        const args = json.get(payload, "args");
        const session_id = json.str(args, "session_id") orelse json.str(payload, "session_id");
        if (eql(action, "session.select")) {
            if (json.str(args, "window_id")) |w| if (session_id) |sid| s.focusWindow(sid, w);
            if (s.performer) |p| _ = p.perform(p.ctx, action, args, session_id);
            return s.reply(call_id, null, null);
        }
        if (s.performer) |p| if (p.perform(p.ctx, action, args, session_id)) return s.reply(call_id, null, null);
        s.reply(call_id, "not_supported", "Compy can't do that yet");
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
        for (v.windows) |w| for (w.layers) |l| for (l.blocks) |blk| if (blk.isTerminal()) s.readDetails(v.session_id, blk.id);
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
        const c = s.control orelse {
            log.warn("key dropped: not connected", .{});
            return;
        };
        if (std.c.getenv("COMPY_DEBUG") != null) log.info("key to {s}", .{block_id});
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

    /// A floating layer's bounds as sent: the server refuses any that don't fit the window, and
    /// float rounding can push an edge just past 1, so they stay a hair inside it.
    fn layerBounds(r: view.Rect) [4]f64 {
        const steps = 10_000.0;
        const down = struct {
            fn f(v: f64) f64 {
                return @floor(v * steps) / steps;
            }
        }.f;
        const x = std.math.clamp(down(r.x), 0, 0.9);
        const y = std.math.clamp(down(r.y), 0, 0.9);
        const margin = 1.0 / steps;
        return .{ x, y, @min(down(r.w), 1.0 - x - margin), @min(down(r.h), 1.0 - y - margin) };
    }

    pub fn floatBlock(s: *Server, session_id: []const u8, block_id: []const u8, bounds: view.Rect) void {
        s.act(session_id, "session.float_block", .{ .session_id = session_id, .block_id = block_id, .bounds = layerBounds(bounds) });
    }

    pub fn setLayerMinimized(s: *Server, session_id: []const u8, layer_id: []const u8, minimized: bool) void {
        if (minimized) {
            s.act(session_id, "session.set_layer_state", .{ .session_id = session_id, .layer_id = layer_id, .state = "minimized" });
        } else {
            s.act(session_id, "session.set_layer_state", .{ .session_id = session_id, .layer_id = layer_id, .state = "normal", .focus = true });
        }
    }

    pub fn resizeLayer(s: *Server, session_id: []const u8, layer_id: []const u8, bounds: view.Rect) void {
        s.act(session_id, "session.resize_layer", .{ .session_id = session_id, .layer_id = layer_id, .bounds = layerBounds(bounds) });
    }

    pub fn raiseLayer(s: *Server, session_id: []const u8, layer_id: []const u8) void {
        s.act(session_id, "session.raise_layer", .{ .session_id = session_id, .layer_id = layer_id });
    }

    pub fn moveBlock(s: *Server, session_id: []const u8, block_id: []const u8, anchor_id: []const u8, horizontal: bool, before: bool) void {
        s.act(session_id, "session.move_block", .{
            .session_id = session_id,
            .block_id = block_id,
            .anchor_block_id = anchor_id,
            .direction = if (horizontal) "horizontal" else "vertical",
            .side = if (before) "before" else "after",
        });
    }

    pub fn swapBlocks(s: *Server, session_id: []const u8, a: []const u8, b: []const u8) void {
        s.act(session_id, "session.swap_blocks", .{ .session_id = session_id, .block_id = a, .other_block_id = b });
    }

    pub fn newWindow(s: *Server, session_id: []const u8) void {
        s.act(session_id, "session.new_window", .{ .session_id = session_id, .layout = shell_layout });
    }

    pub fn renameWindow(s: *Server, session_id: []const u8, window_id: []const u8, label: []const u8) void {
        s.act(session_id, "session.set_window_label", .{ .session_id = session_id, .window_id = window_id, .label = label });
    }

    pub fn closeWindow(s: *Server, session_id: []const u8, window_id: []const u8) void {
        s.act(session_id, "session.close_window", .{ .session_id = session_id, .window_id = window_id });
    }

    pub fn createSession(s: *Server, label: []const u8) void {
        log.warn("creating a session", .{});
        if (std.c.getenv("COMPY_DEBUG") != null) std.debug.dumpCurrentStackTrace(.{});
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
    /// Reads the person's actions and bindings for the command palette.
    pub fn fetchKeymap(s: *Server) void {
        s.call("client.keymap", .{}, void, {}, gotKeymap);
    }

    fn gotKeymap(s: *Server, _: *void, r: Result) void {
        const payload = switch (r) {
            .ok => |p| p,
            .err => return,
        };
        _ = s.keymap_arena.reset(.free_all);
        const a = s.keymap_arena.allocator();
        var list: std.ArrayList(Action) = .empty;
        for (json.array(payload, "actions")) |item| {
            const kind = json.str(item, "kind") orelse "";
            // Client actions belong to one specific app, such as Rex on a Mac.
            if (!eql(kind, "lua") and !eql(kind, "block")) continue;
            const name = json.str(item, "name") orelse continue;
            var keys: std.ArrayList(u8) = .empty;
            var args: ?[]const u8 = null;
            for (json.array(payload, "bindings")) |b| {
                if (json.str(b, "mode") != null) continue;
                if (!eql(json.str(b, "action") orelse "", name)) continue;
                if (keys.items.len > 0) break;
                for (json.array(b, "keys"), 0..) |k, i| {
                    if (i > 0) keys.append(a, ' ') catch {};
                    switch (k) {
                        .string => |t| keys.appendSlice(a, t) catch {},
                        else => {},
                    }
                }
                if (json.get(b, "args")) |v| if (v != .null) {
                    args = std.json.Stringify.valueAlloc(a, v, .{}) catch null;
                };
            }
            list.append(a, .{
                .name = a.dupe(u8, name) catch continue,
                .title = a.dupe(u8, json.str(item, "title") orelse name) catch continue,
                .description = a.dupe(u8, json.str(item, "description") orelse "") catch continue,
                .category = a.dupe(u8, json.str(item, "category") orelse "") catch continue,
                .keywords = a.dupe(u8, json.str(item, "keywords") orelse "") catch continue,
                .keys = keys.items,
                .args = args,
                .needs_args = json.array(json.get(item, "args"), "required").len > 0,
            }) catch {};
        }
        s.actions = list.items;
        s.notify(.keymap, null);
    }

    /// Runs one of the person's Rex actions, as the palette does.
    pub fn runAction(s: *Server, session_id: []const u8, block_id: ?[]const u8, action: []const u8, args: ?[]const u8) void {
        // Fields go out only when set, as the Android app sends them.
        if (block_id) |b| {
            if (args) |t| {
                s.act(session_id, "client.action", .{ .action = action, .session_id = session_id, .block_id = b, .args = json.Raw{ .text = t }, .origin = "palette" });
            } else {
                s.act(session_id, "client.action", .{ .action = action, .session_id = session_id, .block_id = b, .origin = "palette" });
            }
        } else if (args) |t| {
            s.act(session_id, "client.action", .{ .action = action, .session_id = session_id, .args = json.Raw{ .text = t }, .origin = "palette" });
        } else {
            s.act(session_id, "client.action", .{ .action = action, .session_id = session_id, .origin = "palette" });
        }
    }

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
