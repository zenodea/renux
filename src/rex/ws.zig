//! A small WebSocket client on GIO. Each socket reads on its own thread and writes on another,
//! both with blocking calls, and hands every event back to the GTK main loop, so owners only ever
//! see callbacks on the main thread and a send never waits on the network.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.ws);

/// How often the client pings, and how long the connection may stay silent before it counts as
/// lost. The server answers each ping, so silence this long means the other end is gone, as
/// after sleep or a change of network that never closed the connection.
const ping_interval_us = 20 * std.time.us_per_s;
const silence_limit_s = 45;
/// Frames waiting to be sent to a peer that has stopped reading; more than this are refused.
const max_out_bytes = 64 * 1024 * 1024;
/// Events waiting for the main loop; past this the reader waits, so memory stays bounded when a
/// terminal prints faster than it can be drawn.
const max_in_bytes = 4 * 1024 * 1024;
const max_message_bytes = 64 * 1024 * 1024;
/// Events are delivered just after the window draws, never ahead of it, a few at a time.
const deliver_priority = glib.PRIORITY_HIGH_IDLE + 25;
const deliver_budget_us = 5 * std.time.us_per_ms;
/// At most this much waiting data counts as "a little" and is delivered ahead of the frame.
const quick_bytes = 32 * 1024;

pub const Handler = struct {
    ctx: *anyopaque,
    on_open: *const fn (ctx: *anyopaque) void,
    on_message: *const fn (ctx: *anyopaque, binary: bool, data: []const u8) void,
    /// Called once when the connection ends, unless the owner closed it first.
    on_close: *const fn (ctx: *anyopaque, code: u16, reason: []const u8) void,
};

pub const Options = struct {
    /// Base address, such as http://host:port, https://host, or unix:///path/to/server.sock for
    /// a server on this computer.
    url: []const u8,
    path: []const u8,
    protocol: []const u8,
    /// A binary message sent as soon as the connection opens.
    first_message: ?[]const u8 = null,
};

/// The wait before retry number `retries`, doubling from `base` up to `cap`; counts the retry.
pub fn backoffMs(base: c_uint, cap: c_uint, retries: *u5) c_uint {
    const wait = @min(cap, base << @min(retries.*, 5));
    if (retries.* < 31) retries.* += 1;
    return wait;
}

pub const Socket = struct {
    refs: std.atomic.Value(u32) = .init(2), // the owner and the reader thread
    closed: std.atomic.Value(bool) = .init(false),
    handler: Handler,
    url: []u8,
    path: []u8,
    protocol: []u8,
    first_message: ?[]u8,
    cancellable: *gio.Cancellable,
    /// Guards everything below.
    lock: glib.Mutex = undefined,
    conn: ?*gio.SocketConnection = null,

    // Sending: whole frames wait here, in order, for the writer thread.
    out: std.ArrayList([]u8) = .empty,
    out_bytes: usize = 0,
    out_cond: glib.Cond = undefined,
    /// The writer thread is taking frames.
    writing: bool = false,
    /// The owner closed the socket: the writer sends what is queued, then ends the connection.
    finishing: bool = false,
    /// The reader ended, so the writer must too.
    stop: bool = false,

    // Receiving: events wait here for the main loop.
    in: std.ArrayList(Posted) = .empty,
    in_head: usize = 0,
    in_bytes: usize = 0,
    in_cond: glib.Cond = undefined,
    /// An idle is scheduled to deliver events; it holds a reference.
    draining: bool = false,

    /// Starts connecting. Events arrive through `handler` on the main thread.
    pub fn open(opts: Options, handler: Handler) !*Socket {
        const s = try gpa.create(Socket);
        errdefer gpa.destroy(s);
        const url = try gpa.dupe(u8, opts.url);
        errdefer gpa.free(url);
        const path = try gpa.dupe(u8, opts.path);
        errdefer gpa.free(path);
        const protocol = try gpa.dupe(u8, opts.protocol);
        errdefer gpa.free(protocol);
        const first = if (opts.first_message) |m| try gpa.dupe(u8, m) else null;
        errdefer if (first) |m| gpa.free(m);
        s.* = .{ .handler = handler, .url = url, .path = path, .protocol = protocol, .first_message = first, .cancellable = gio.Cancellable.new() };
        s.lock.init();
        s.out_cond.init();
        s.in_cond.init();
        errdefer {
            s.lock.clear();
            s.out_cond.clear();
            s.in_cond.clear();
            s.cancellable.as(gobject.Object).unref();
        }
        const thread = try std.Thread.spawn(.{}, readLoop, .{s});
        thread.detach();
        return s;
    }

    /// Ends the connection with a close frame. No more callbacks arrive after this.
    pub fn close(s: *Socket) void {
        if (s.closed.swap(true, .acq_rel)) return;
        const frame: ?[]u8 = encodeFrame(0x8, &.{ 0x03, 0xe8 }, randomMask()) catch null; // 1000, normal closure
        s.lock.lock();
        const queued = if (frame) |f| s.writing and s.queue(f) else false;
        if (queued) {
            // The writer ends the connection once the frame is out.
            s.finishing = true;
            s.out_cond.signal();
        } else {
            if (frame) |f| gpa.free(f);
            s.cancellable.cancel();
        }
        s.in_cond.broadcast();
        s.lock.unlock();
        s.unref();
    }

    /// Drops the connection without a close frame, so the server can keep state for a resume.
    pub fn abandon(s: *Socket) void {
        if (s.closed.swap(true, .acq_rel)) return;
        s.cancellable.cancel();
        s.lock.lock();
        s.out_cond.signal();
        s.in_cond.broadcast();
        s.lock.unlock();
        s.unref();
    }

    pub fn sendText(s: *Socket, data: []const u8) bool {
        return s.sendFrame(0x1, data);
    }

    pub fn sendBinary(s: *Socket, data: []const u8) bool {
        return s.sendFrame(0x2, data);
    }

    fn ref(s: *Socket) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    fn unref(s: *Socket) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        if (s.conn) |c| c.as(gobject.Object).unref();
        for (s.out.items) |f| gpa.free(f);
        s.out.deinit(gpa);
        for (s.in.items[s.in_head..]) |p| if (p.owned) |o| gpa.free(o);
        s.in.deinit(gpa);
        s.lock.clear();
        s.out_cond.clear();
        s.in_cond.clear();
        s.cancellable.as(gobject.Object).unref();
        gpa.free(s.url);
        gpa.free(s.path);
        gpa.free(s.protocol);
        if (s.first_message) |m| gpa.free(m);
        gpa.destroy(s);
    }

    /// Queues one frame for the writer, in the order of the calls. False when not connected, or
    /// when the peer has stopped reading for so long that the queue is full.
    fn sendFrame(s: *Socket, opcode: u8, payload: []const u8) bool {
        const frame = encodeFrame(opcode, payload, randomMask()) catch return false;
        s.lock.lock();
        defer s.lock.unlock();
        if (!s.writing or s.finishing or !s.queue(frame)) {
            gpa.free(frame);
            return false;
        }
        s.out_cond.signal();
        return true;
    }

    /// Takes `frame` if there is room. Call with the lock held.
    fn queue(s: *Socket, frame: []u8) bool {
        if (s.out_bytes + frame.len > max_out_bytes) return false;
        s.out.append(gpa, frame) catch return false;
        s.out_bytes += frame.len;
        return true;
    }
};

fn randomMask() [4]u8 {
    return @bitCast(glib.randomInt());
}

/// One whole masked frame, as a client must send them. The caller frees it.
fn encodeFrame(opcode: u8, payload: []const u8, mask: [4]u8) ![]u8 {
    var header: [14]u8 = undefined;
    header[0] = 0x80 | opcode;
    var n: usize = 2;
    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        n = 10;
    }
    @memcpy(header[n .. n + 4], &mask);
    n += 4;
    const frame = try gpa.alloc(u8, n + payload.len);
    @memcpy(frame[0..n], header[0..n]);
    for (payload, 0..) |b, i| frame[n + i] = b ^ mask[i % 4];
    return frame;
}

// Writing, on the socket's writer thread. The reader starts it and waits for it to end.

fn writeLoop(s: *Socket, out: *gio.OutputStream) void {
    var next_ping = glib.getMonotonicTime() + ping_interval_us;
    var failed = false;
    s.lock.lock();
    while (!s.stop and !failed) {
        if (glib.getMonotonicTime() >= next_ping) {
            next_ping = glib.getMonotonicTime() + ping_interval_us;
            if (encodeFrame(0x9, "", randomMask())) |f| {
                if (!s.queue(f)) gpa.free(f);
            } else |_| {}
        }
        if (s.out.items.len == 0) {
            if (s.finishing) break;
            _ = s.out_cond.waitUntil(&s.lock, next_ping);
            continue;
        }
        var batch = s.out;
        s.out = .empty;
        s.out_bytes = 0;
        s.lock.unlock();
        for (batch.items) |frame| {
            if (!failed) {
                var err: ?*glib.Error = null;
                if (out.writeAll(frame.ptr, frame.len, null, s.cancellable, &err) == 0) {
                    if (err) |e| e.free();
                    failed = true;
                }
            }
            gpa.free(frame);
        }
        batch.deinit(gpa);
        s.lock.lock();
    }
    s.writing = false;
    const reader_ended = s.stop;
    s.lock.unlock();
    // After a close or a failed write nothing more can be sent, so the reader ends too.
    if (!reader_ended) s.cancellable.cancel();
}

// Reading, on the socket's own thread.

const Reader = struct {
    s: *Socket,
    in: *gio.InputStream,
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(r: *Reader) !void {
        if (r.start == r.end) {
            r.start = 0;
            r.end = 0;
        }
        if (r.end == r.buf.len) {
            std.mem.copyForwards(u8, r.buf[0 .. r.end - r.start], r.buf[r.start..r.end]);
            r.end -= r.start;
            r.start = 0;
        }
        var err: ?*glib.Error = null;
        const got = r.in.read(r.buf[r.end..].ptr, r.buf.len - r.end, r.s.cancellable, &err);
        if (got <= 0) {
            if (err) |e| e.free();
            return error.Closed;
        }
        r.end += @intCast(got);
    }

    fn readInto(r: *Reader, out: []u8) !void {
        var done: usize = 0;
        while (done < out.len) {
            if (r.start == r.end) try r.fill();
            const take = @min(out.len - done, r.end - r.start);
            @memcpy(out[done .. done + take], r.buf[r.start .. r.start + take]);
            r.start += take;
            done += take;
        }
    }
};

/// How a connection ended, for the one close event its owner hears.
const Ending = struct {
    code: u16 = 1006,
    reason: []const u8 = "Can't reach this server",
    /// Room for a reason the server sent; a close frame holds at most 123 bytes of it.
    buf: [125]u8 = undefined,
};

fn readLoop(s: *Socket) void {
    defer s.unref();
    var ending: Ending = .{};
    run(s, &ending) catch {};
    post(s, .{ .close = .{ .code = ending.code, .reason = ending.reason } });
}

/// Runs the connection until it ends, for whatever reason; `ending` says which.
fn run(s: *Socket, ending: *Ending) !void {
    const client = gio.SocketClient.new();
    defer client.as(gobject.Object).unref();
    client.setTimeout(15);
    const tls = std.mem.startsWith(u8, s.url, "https://");
    if (tls) client.setTls(1);
    const unix_path = unixPath(s.url);

    const uri = try std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ s.url, s.path }, 0);
    defer gpa.free(uri);
    var err: ?*glib.Error = null;
    // GIO only takes the port from the address itself, so give it the scheme's usual one.
    const conn = (if (unix_path) |p|
        connectUnix(client, p, s.cancellable, &err)
    else
        client.connectToUri(uri.ptr, if (tls) 443 else 80, s.cancellable, &err)) orelse {
        const msg: []const u8 = if (err) |e| std.mem.span(e.f_message orelse "") else "";
        log.info("connect {s} failed: {s}", .{ uri, msg });
        if (err) |e| e.free();
        return error.Closed;
    };
    s.lock.lock();
    s.conn = conn;
    s.lock.unlock();

    const io = conn.as(gio.IOStream);
    var r: Reader = .{ .s = s, .in = io.getInputStream() };

    // The opening handshake.
    var key_bytes: [16]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(u32, key_bytes[i * 4 ..][0..4], glib.randomInt(), .little);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_bytes);
    // A socket has no host name; the rex command sends "rex" in its place.
    const host = if (unix_path != null) "rex" else hostOf(s.url);
    const request = try std.fmt.allocPrint(gpa, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: {s}\r\n\r\n", .{ s.path, host, key, s.protocol });
    defer gpa.free(request);
    if (io.getOutputStream().writeAll(request.ptr, request.len, null, s.cancellable, &err) == 0) {
        if (err) |e| e.free();
        return error.Closed;
    }

    // Read the response head; whatever follows it is already frame data.
    while (true) {
        if (std.mem.indexOf(u8, r.buf[r.start..r.end], "\r\n\r\n")) |at| {
            const head = r.buf[r.start .. r.start + at];
            r.start += at + 4;
            const status = statusOf(head);
            if (status != 101) {
                ending.code = if (status == 0) 1006 else status;
                ending.reason = if (status == 403) "This server doesn't allow your account" else "The server refused the connection";
                return error.Closed;
            }
            break;
        }
        try r.fill();
    }
    ending.reason = "Connection lost";

    // From here a quiet connection is a lost one: the pings below keep a live one talking.
    conn.getSocket().setTimeout(silence_limit_s);
    if (unix_path == null) conn.getSocket().setKeepalive(1);
    s.lock.lock();
    s.writing = true;
    s.lock.unlock();
    const writer = std.Thread.spawn(.{}, writeLoop, .{ s, io.getOutputStream() }) catch {
        s.lock.lock();
        s.writing = false;
        s.lock.unlock();
        return error.Closed;
    };
    defer {
        s.lock.lock();
        s.stop = true;
        s.out_cond.signal();
        s.lock.unlock();
        writer.join();
    }

    post(s, .open);
    if (s.first_message) |m| _ = s.sendBinary(m);

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);
    var message_binary = false;
    while (true) {
        var h: [2]u8 = undefined;
        try r.readInto(&h);
        const fin = h[0] & 0x80 != 0;
        const opcode = h[0] & 0x0f;
        const masked = h[1] & 0x80 != 0;
        var len: u64 = h[1] & 0x7f;
        if (len == 126) {
            var b: [2]u8 = undefined;
            try r.readInto(&b);
            len = std.mem.readInt(u16, &b, .big);
        } else if (len == 127) {
            var b: [8]u8 = undefined;
            try r.readInto(&b);
            len = std.mem.readInt(u64, &b, .big);
        }
        if (len > max_message_bytes) return error.Closed;
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) try r.readInto(&mask);
        const payload = try gpa.alloc(u8, @intCast(len));
        defer gpa.free(payload);
        try r.readInto(payload);
        if (masked) for (payload, 0..) |*b, i| {
            b.* ^= mask[i % 4];
        };

        switch (opcode) {
            0x0, 0x1, 0x2 => {
                if (opcode != 0) {
                    message.clearRetainingCapacity();
                    message_binary = opcode == 0x2;
                }
                if (message.items.len + payload.len > max_message_bytes) return error.Closed;
                try message.appendSlice(gpa, payload);
                if (fin) {
                    post(s, .{ .message = .{ .binary = message_binary, .data = message.items } });
                    message.clearRetainingCapacity();
                }
            },
            0x8 => {
                _ = s.sendFrame(0x8, payload[0..@min(payload.len, 2)]);
                ending.code = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else 1005;
                ending.reason = "Connection closed";
                if (payload.len > 2) {
                    const n = @min(payload.len - 2, ending.buf.len);
                    @memcpy(ending.buf[0..n], payload[2 .. 2 + n]);
                    ending.reason = ending.buf[0..n];
                }
                return error.Closed;
            },
            0x9 => _ = s.sendFrame(0xA, payload),
            else => {},
        }
    }
}

/// The socket file a unix:// address names, such as /run/user/1000/rex/server.sock from
/// unix:///run/user/1000/rex/server.sock; null for any other address.
pub fn unixPath(url: []const u8) ?[]const u8 {
    const scheme = "unix://";
    if (!std.mem.startsWith(u8, url, scheme) or url.len == scheme.len) return null;
    return url[scheme.len..];
}

fn connectUnix(client: *gio.SocketClient, path: []const u8, cancellable: ?*gio.Cancellable, err: *?*glib.Error) ?*gio.SocketConnection {
    const z = gpa.dupeSentinel(u8, path, 0) catch return null;
    defer gpa.free(z);
    const address = gio.UnixSocketAddress.new(z.ptr);
    defer address.as(gobject.Object).unref();
    return client.connect(address.as(gio.SocketConnectable), cancellable, err);
}

fn hostOf(url: []const u8) []const u8 {
    const after = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    return after[0 .. std.mem.indexOfScalar(u8, after, '/') orelse after.len];
}

fn statusOf(head: []const u8) u16 {
    // "HTTP/1.1 101 Switching Protocols"
    var parts = std.mem.tokenizeScalar(u8, head, ' ');
    _ = parts.next() orelse return 0;
    const code = parts.next() orelse return 0;
    return std.fmt.parseInt(u16, code[0..@min(code.len, 3)], 10) catch 0;
}

// Handing events to the main loop.

const Event = union(enum) {
    open,
    message: struct { binary: bool, data: []const u8 },
    close: struct { code: u16, reason: []const u8 },
};

const Posted = struct {
    event: Event,
    owned: ?[]u8,

    fn size(p: Posted) usize {
        return if (p.owned) |o| o.len else 0;
    }
};

/// Queues an event for the main loop. A reader far ahead of the main loop waits here for room.
fn post(s: *Socket, event: Event) void {
    if (s.closed.load(.acquire)) return;
    var p: Posted = .{ .event = event, .owned = null };
    switch (p.event) {
        .message => |*m| {
            const d = gpa.dupe(u8, m.data) catch return;
            p.owned = d;
            m.data = d;
        },
        .close => |*c| {
            const d = gpa.dupe(u8, c.reason) catch return;
            p.owned = d;
            c.reason = d;
        },
        .open => {},
    }
    s.lock.lock();
    defer s.lock.unlock();
    s.in.append(gpa, p) catch {
        if (p.owned) |o| gpa.free(o);
        return;
    };
    s.in_bytes += p.size();
    if (!s.draining) {
        s.draining = true;
        s.ref();
        // A little data (the echo of a key, a prompt) is delivered ahead of the next frame so
        // it is drawn in that frame; a lot waits until after it, so a flood never holds up
        // drawing.
        if (s.in_bytes <= quick_bytes)
            _ = glib.idleAddFull(glib.PRIORITY_DEFAULT, &drainQuick, s, null)
        else
            _ = glib.idleAddFull(deliver_priority, &drain, s, null);
    }
    while (s.in_bytes > max_in_bytes and !s.closed.load(.acquire)) s.in_cond.wait(&s.lock);
}

/// The quick delivery, ahead of drawing. If more arrived than fits its few milliseconds, the
/// rest goes the ordinary way, after the frame.
fn drainQuick(data: ?*anyopaque) callconv(.c) c_int {
    if (drain(data) != 0) _ = glib.idleAddFull(deliver_priority, &drain, data, null);
    return 0;
}

/// Delivers queued events on the main loop, in order, for a few milliseconds at a time so a
/// flood of them never holds up drawing or typing.
fn drain(data: ?*anyopaque) callconv(.c) c_int {
    const s: *Socket = @ptrCast(@alignCast(data.?));
    const started = glib.getMonotonicTime();
    while (true) {
        s.lock.lock();
        if (s.in_head >= s.in.items.len) {
            s.in_head = 0;
            if (s.in.capacity > 1024) s.in.clearAndFree(gpa) else s.in.clearRetainingCapacity();
            s.draining = false;
            s.lock.unlock();
            s.unref();
            return 0;
        }
        const p = s.in.items[s.in_head];
        s.in_head += 1;
        s.in_bytes -= p.size();
        s.in_cond.signal();
        s.lock.unlock();
        deliver(s, p);
        if (p.owned) |o| gpa.free(o);
        if (glib.getMonotonicTime() - started > deliver_budget_us) return 1;
    }
}

fn deliver(s: *Socket, p: Posted) void {
    if (s.closed.load(.acquire)) return;
    const h = s.handler;
    switch (p.event) {
        .open => h.on_open(h.ctx),
        .message => |m| h.on_message(h.ctx, m.binary, m.data),
        .close => |c| {
            // The owner hears about a close once; its socket is finished after that.
            if (!s.closed.swap(true, .acq_rel)) {
                h.on_close(h.ctx, c.code, c.reason);
                s.unref();
            }
        },
    }
}

test "host and status parsing" {
    try std.testing.expectEqualStrings("127.0.0.1:18765", hostOf("http://127.0.0.1:18765"));
    try std.testing.expectEqualStrings("mac.tail.ts.net", hostOf("https://mac.tail.ts.net/x"));
    try std.testing.expectEqualStrings("/run/user/1000/rex/server.sock", unixPath("unix:///run/user/1000/rex/server.sock").?);
    try std.testing.expect(unixPath("unix://") == null);
    try std.testing.expect(unixPath("http://box:8765") == null);
    try std.testing.expectEqual(@as(u16, 101), statusOf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket"));
    try std.testing.expectEqual(@as(u16, 403), statusOf("HTTP/1.1 403 Forbidden"));
}

test "frames carry their length and unmask to the payload" {
    const mask = [4]u8{ 1, 2, 3, 4 };
    inline for (.{ .{ 0, 2 }, .{ 125, 2 }, .{ 126, 4 }, .{ 65535, 4 }, .{ 65536, 10 } }) |case| {
        const payload = try std.testing.allocator.alloc(u8, case[0]);
        defer std.testing.allocator.free(payload);
        for (payload, 0..) |*b, i| b.* = @truncate(i * 7);
        const frame = try encodeFrame(0x2, payload, mask);
        defer gpa.free(frame);
        const head: usize = case[1];
        try std.testing.expectEqual(head + 4 + payload.len, frame.len);
        try std.testing.expectEqual(@as(u8, 0x82), frame[0]);
        try std.testing.expect(frame[1] & 0x80 != 0);
        const len: u64 = switch (head) {
            2 => frame[1] & 0x7f,
            4 => std.mem.readInt(u16, frame[2..4], .big),
            else => std.mem.readInt(u64, frame[2..10], .big),
        };
        try std.testing.expectEqual(@as(u64, payload.len), len);
        try std.testing.expectEqualSlices(u8, &mask, frame[head .. head + 4]);
        for (payload, 0..) |b, i| try std.testing.expectEqual(b, frame[head + 4 + i] ^ mask[i % 4]);
    }
}

test "backoff doubles to its cap and counts the retries" {
    var retries: u5 = 0;
    try std.testing.expectEqual(@as(c_uint, 1000), backoffMs(1000, 30_000, &retries));
    try std.testing.expectEqual(@as(c_uint, 2000), backoffMs(1000, 30_000, &retries));
    retries = 5;
    try std.testing.expectEqual(@as(c_uint, 30_000), backoffMs(1000, 30_000, &retries));
    retries = 31;
    try std.testing.expectEqual(@as(c_uint, 10_000), backoffMs(500, 10_000, &retries));
    try std.testing.expectEqual(@as(u5, 31), retries);
}
