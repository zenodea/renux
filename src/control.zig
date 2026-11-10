//! One control connection: JSON requests, responses and events over /api/control. The owner
//! decides what to do when it closes; this only reports it.
const std = @import("std");
const glib = @import("glib");
const ws = @import("ws.zig");
const json = @import("json.zig");

const gpa = std.heap.c_allocator;

pub const protocol = "rex.control.v1";
pub const api_revision = 10;
const call_timeout_ms = 15_000;

pub const Welcome = struct {
    client_id: []const u8,
    reconnect_token: ?[]const u8,
    resumed: bool,
    api_revision: i64,
};

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
};

/// A response: the payload on success. Both live only for the length of the callback.
pub const Result = union(enum) {
    ok: ?json.Value,
    err: Failure,
};

pub const Callback = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, result: Result) void,

    pub const none: Callback = .{ .ctx = null, .func = ignore };
    fn ignore(_: ?*anyopaque, _: Result) void {}

    /// Wraps a typed callback, so callers don't cast.
    pub fn of(comptime T: type, ctx: *T, comptime f: fn (*T, Result) void) Callback {
        return .{ .ctx = ctx, .func = struct {
            fn call(c: ?*anyopaque, r: Result) void {
                f(@ptrCast(@alignCast(c.?)), r);
            }
        }.call };
    }
};

pub const Listener = struct {
    ctx: *anyopaque,
    on_welcome: *const fn (ctx: *anyopaque, c: *Control, w: Welcome) void,
    on_event: *const fn (ctx: *anyopaque, c: *Control, kind: []const u8, payload: ?json.Value) void,
    on_closed: *const fn (ctx: *anyopaque, c: *Control, reason: []const u8, code: u16) void,
};

const Pending = struct {
    control: *Control,
    id: u64,
    cb: Callback,
    timer: c_uint = 0,
};

pub const Control = struct {
    socket: *ws.Socket,
    listener: Listener,
    pending: std.AutoHashMapUnmanaged(u64, *Pending) = .empty,
    next_id: u64 = 1,
    label: []u8,
    version: []u8,
    token: ?[]u8,
    welcomed: bool = false,
    /// The socket closed by itself and is already gone.
    socket_done: bool = false,
    /// The owner closed or abandoned this control. Its memory is freed from the main loop, never
    /// inside the call that dropped it, so a callback may drop the control it was called by.
    dead: bool = false,

    pub fn open(url: []const u8, label: []const u8, version: []const u8, reconnect_token: ?[]const u8, listener: Listener) !*Control {
        const c = try gpa.create(Control);
        errdefer gpa.destroy(c);
        const own_label = try gpa.dupe(u8, label[0..@min(label.len, 48)]);
        errdefer gpa.free(own_label);
        const own_version = try gpa.dupe(u8, version);
        errdefer gpa.free(own_version);
        const own_token = if (reconnect_token) |t| try gpa.dupe(u8, t) else null;
        errdefer if (own_token) |t| gpa.free(t);
        c.* = .{ .socket = undefined, .listener = listener, .label = own_label, .version = own_version, .token = own_token };
        c.socket = try ws.Socket.open(.{ .url = url, .path = "/api/control", .protocol = protocol }, .{
            .ctx = c,
            .on_open = onOpen,
            .on_message = onMessage,
            .on_close = onClose,
        });
        return c;
    }

    /// Sends a request; `cb` hears the response, a refusal, or a timeout.
    pub fn call(c: *Control, method: []const u8, payload: anytype, cb: Callback) void {
        c.callTimeout(method, payload, call_timeout_ms, cb);
    }

    pub fn callTimeout(c: *Control, method: []const u8, payload: anytype, timeout_ms: c_uint, cb: Callback) void {
        const id = c.next_id;
        c.next_id += 1;
        // Every call ends in exactly one answer to `cb`, so make room for it before sending.
        const not_sent: Result = .{ .err = .{ .code = "disconnected", .message = "Not connected to the server" } };
        const p = gpa.create(Pending) catch return cb.func(cb.ctx, not_sent);
        c.pending.ensureUnusedCapacity(gpa, 1) catch {
            gpa.destroy(p);
            return cb.func(cb.ctx, not_sent);
        };
        if (!c.send(id, method, payload)) {
            gpa.destroy(p);
            return cb.func(cb.ctx, not_sent);
        }
        p.* = .{ .control = c, .id = id, .cb = cb };
        p.timer = glib.timeoutAdd(timeout_ms, &timedOut, p);
        c.pending.putAssumeCapacity(id, p);
    }

    /// Sends a request without waiting. Requests go out in order, which keeps typing in order.
    pub fn fire(c: *Control, method: []const u8, payload: anytype) void {
        const id = c.next_id;
        c.next_id += 1;
        _ = c.send(id, method, payload);
    }

    fn send(c: *Control, id: u64, method: []const u8, payload: anytype) bool {
        var id_buf: [24]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
        const text = std.json.Stringify.valueAlloc(gpa, .{
            .type = "request",
            .id = id_str,
            .method = method,
            .payload = payload,
        }, .{}) catch |err| {
            std.log.warn("couldn't encode {s}: {s}", .{ method, @errorName(err) });
            return false;
        };
        defer gpa.free(text);
        if (c.socket_done or c.dead) return false;
        return c.socket.sendText(text);
    }

    /// Ends the client on the server at once.
    pub fn close(c: *Control) void {
        if (c.dead) return;
        c.dead = true;
        if (!c.socket_done) c.socket.close();
        c.destroy();
    }

    /// Drops the connection without a close frame, so the server keeps the client for a resume.
    pub fn abandon(c: *Control) void {
        if (c.dead) return;
        c.dead = true;
        if (!c.socket_done) c.socket.abandon();
        c.destroy();
    }

    /// Fails what's still waiting now; the socket is closed, so nothing else can arrive.
    fn destroy(c: *Control) void {
        c.failAll("disconnected", "Not connected to the server");
        _ = glib.idleAdd(&free, c);
    }

    fn free(data: ?*anyopaque) callconv(.c) c_int {
        const c: *Control = @ptrCast(@alignCast(data.?));
        // A callback failed above may have tried another call; `send` refused it, so this is empty.
        c.failAll("disconnected", "Not connected to the server");
        c.pending.deinit(gpa);
        gpa.free(c.label);
        gpa.free(c.version);
        if (c.token) |t| gpa.free(t);
        gpa.destroy(c);
        return 0;
    }

    fn failAll(c: *Control, code: []const u8, message: []const u8) void {
        // Callbacks may make new calls, so take the whole table first.
        var table = c.pending;
        c.pending = .empty;
        defer table.deinit(gpa);
        var it = table.valueIterator();
        while (it.next()) |p| {
            _ = glib.Source.remove(p.*.timer);
            const cb = p.*.cb;
            gpa.destroy(p.*);
            cb.func(cb.ctx, .{ .err = .{ .code = code, .message = message } });
        }
    }
};

fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
    const p: *Pending = @ptrCast(@alignCast(data.?));
    const c = p.control;
    _ = c.pending.remove(p.id);
    const cb = p.cb;
    gpa.destroy(p);
    cb.func(cb.ctx, .{ .err = .{ .code = "timeout", .message = "The server took too long to answer" } });
    return 0;
}

fn onOpen(ctx: *anyopaque) void {
    const c: *Control = @ptrCast(@alignCast(ctx));
    const hello = std.json.Stringify.valueAlloc(gpa, .{
        .type = "hello",
        .api_revision = api_revision,
        .reconnect_token = c.token,
        .client = .{
            .kind = "app",
            .platform = "other",
            .name = "Compy",
            .version = c.version,
            .label = c.label,
        },
    }, .{ .emit_null_optional_fields = false }) catch return;
    defer gpa.free(hello);
    _ = c.socket.sendText(hello);
}

fn onMessage(ctx: *anyopaque, binary: bool, data: []const u8) void {
    const c: *Control = @ptrCast(@alignCast(ctx));
    if (binary) return;
    var parsed = std.json.parseFromSlice(json.Value, gpa, data, .{}) catch return;
    defer parsed.deinit();
    const msg = parsed.value;
    const kind = json.str(msg, "type") orelse return;
    if (std.mem.eql(u8, kind, "welcome")) {
        if (!std.mem.eql(u8, json.str(msg, "protocol") orelse "", protocol)) {
            c.listener.on_closed(c.listener.ctx, c, "Unexpected protocol", 0);
            return;
        }
        const client = json.get(msg, "client");
        c.welcomed = true;
        c.listener.on_welcome(c.listener.ctx, c, .{
            .client_id = json.str(client, "id") orelse "",
            .reconnect_token = json.str(client, "reconnect_token"),
            .resumed = json.boolean(client, "resumed") orelse false,
            .api_revision = json.int(msg, "api_revision") orelse 0,
        });
    } else if (std.mem.eql(u8, kind, "response")) {
        const id = std.fmt.parseInt(u64, json.str(msg, "id") orelse return, 10) catch return;
        const entry = c.pending.fetchRemove(id) orelse return;
        const p = entry.value;
        _ = glib.Source.remove(p.timer);
        const cb = p.cb;
        gpa.destroy(p);
        if (json.get(msg, "error")) |e| if (e == .object) {
            cb.func(cb.ctx, .{ .err = .{
                .code = json.str(e, "code") orelse "internal",
                .message = json.str(e, "message") orelse "The server refused the request",
            } });
            return;
        };
        cb.func(cb.ctx, .{ .ok = json.get(msg, "payload") });
    } else if (std.mem.eql(u8, kind, "event")) {
        const event = json.get(msg, "payload");
        c.listener.on_event(c.listener.ctx, c, json.str(event, "type") orelse "", json.get(event, "payload"));
    }
}

fn onClose(ctx: *anyopaque, code: u16, reason: []const u8) void {
    const c: *Control = @ptrCast(@alignCast(ctx));
    // The socket is finished; the owner decides whether to drop this control.
    c.socket_done = true;
    c.failAll("disconnected", reason);
    // A failed call may already have made the owner drop this control; it has heard enough then.
    if (c.dead) return;
    c.listener.on_closed(c.listener.ctx, c, reason, code);
}
