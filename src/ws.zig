//! A small WebSocket client on GIO. Each socket reads on its own thread with blocking calls and
//! hands every event back to the GTK main loop, so owners only ever see callbacks on the main
//! thread. Sends write straight to the connection from whichever thread calls them.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.ws);

pub const Handler = struct {
    ctx: *anyopaque,
    on_open: *const fn (ctx: *anyopaque) void,
    on_message: *const fn (ctx: *anyopaque, binary: bool, data: []const u8) void,
    /// Called once when the connection ends, unless the owner closed it first.
    on_close: *const fn (ctx: *anyopaque, code: u16, reason: []const u8) void,
};

pub const Options = struct {
    /// Base address, such as http://host:port or https://host.
    url: []const u8,
    path: []const u8,
    protocol: []const u8,
    /// A binary message sent as soon as the connection opens.
    first_message: ?[]const u8 = null,
};

pub const Socket = struct {
    refs: std.atomic.Value(u32) = .init(2), // the owner and the reader thread
    closed: std.atomic.Value(bool) = .init(false),
    handler: Handler,
    url: []u8,
    path: []u8,
    protocol: []u8,
    first_message: ?[]u8,
    cancellable: *gio.Cancellable,
    lock: glib.Mutex = undefined,
    conn: ?*gio.SocketConnection = null,

    /// Starts connecting. Events arrive through `handler` on the main thread.
    pub fn open(opts: Options, handler: Handler) !*Socket {
        const s = try gpa.create(Socket);
        s.* = .{
            .handler = handler,
            .url = try gpa.dupe(u8, opts.url),
            .path = try gpa.dupe(u8, opts.path),
            .protocol = try gpa.dupe(u8, opts.protocol),
            .first_message = if (opts.first_message) |m| try gpa.dupe(u8, m) else null,
            .cancellable = gio.Cancellable.new(),
        };
        s.lock.init();
        const thread = try std.Thread.spawn(.{}, readLoop, .{s});
        thread.detach();
        return s;
    }

    /// Ends the connection with a close frame. No more callbacks arrive after this.
    pub fn close(s: *Socket) void {
        if (s.closed.swap(true, .acq_rel)) return;
        _ = s.sendFrame(0x8, &.{ 0x03, 0xe8 }); // 1000, normal closure
        s.cancellable.cancel();
        s.unref();
    }

    /// Drops the connection without a close frame, so the server can keep state for a resume.
    pub fn abandon(s: *Socket) void {
        if (s.closed.swap(true, .acq_rel)) return;
        s.cancellable.cancel();
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
        s.lock.lock();
        if (s.conn) |c| c.as(gobject.Object).unref();
        s.conn = null;
        s.lock.unlock();
        s.lock.clear();
        s.cancellable.as(gobject.Object).unref();
        gpa.free(s.url);
        gpa.free(s.path);
        gpa.free(s.protocol);
        if (s.first_message) |m| gpa.free(m);
        gpa.destroy(s);
    }

    /// Writes one masked frame, as a client must. False when not connected.
    fn sendFrame(s: *Socket, opcode: u8, payload: []const u8) bool {
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
        const mask: [4]u8 = @bitCast(glib.randomInt());
        @memcpy(header[n .. n + 4], &mask);
        n += 4;
        const frame = gpa.alloc(u8, n + payload.len) catch return false;
        defer gpa.free(frame);
        @memcpy(frame[0..n], header[0..n]);
        for (payload, 0..) |b, i| frame[n + i] = b ^ mask[i % 4];

        s.lock.lock();
        defer s.lock.unlock();
        const conn = s.conn orelse return false;
        const out = conn.as(gio.IOStream).getOutputStream();
        var err: ?*glib.Error = null;
        if (out.writeAll(frame.ptr, frame.len, null, null, &err) == 0) {
            if (err) |e| e.free();
            return false;
        }
        return true;
    }
};

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

fn readLoop(s: *Socket) void {
    defer s.unref();
    run(s) catch |err| switch (err) {
        error.Ended => {},
        else => post(s, .{ .close = .{ .code = 1006, .reason = "Can't reach this server" } }),
    };
}

/// Runs the connection until it ends, posting the close event itself before `error.Ended`.
fn run(s: *Socket) !void {
    const client = gio.SocketClient.new();
    defer client.as(gobject.Object).unref();
    client.setTimeout(15);
    if (std.mem.startsWith(u8, s.url, "https://")) client.setTls(1);

    const uri = try std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ s.url, s.path }, 0);
    defer gpa.free(uri);
    var err: ?*glib.Error = null;
    const conn = client.connectToUri(uri.ptr, 80, s.cancellable, &err) orelse {
        const msg: []const u8 = if (err) |e| std.mem.span(e.f_message orelse "") else "";
        log.info("connect {s} failed: {s}", .{ uri, msg });
        if (err) |e| e.free();
        post(s, .{ .close = .{ .code = 1006, .reason = "Can't reach this server" } });
        return error.Ended;
    };
    // The client's timeout was for connecting; reads wait as long as the server stays quiet.
    conn.getSocket().setTimeout(0);
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
    const host = hostOf(s.url);
    const request = try std.fmt.allocPrint(gpa, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: {s}\r\n\r\n", .{ s.path, host, key, s.protocol });
    defer gpa.free(request);
    {
        s.lock.lock();
        defer s.lock.unlock();
        if (io.getOutputStream().writeAll(request.ptr, request.len, null, s.cancellable, &err) == 0) {
            if (err) |e| e.free();
            post(s, .{ .close = .{ .code = 1006, .reason = "Can't reach this server" } });
            return error.Ended;
        }
    }

    // Read the response head; whatever follows it is already frame data.
    while (true) {
        if (std.mem.indexOf(u8, r.buf[r.start..r.end], "\r\n\r\n")) |at| {
            const head = r.buf[r.start .. r.start + at];
            r.start += at + 4;
            const status = statusOf(head);
            if (status != 101) {
                post(s, .{ .close = .{
                    .code = if (status == 0) 1006 else status,
                    .reason = if (status == 403) "This server doesn't allow your account" else "The server refused the connection",
                } });
                return error.Ended;
            }
            break;
        }
        r.fill() catch {
            post(s, .{ .close = .{ .code = 1006, .reason = "Can't reach this server" } });
            return error.Ended;
        };
    }

    post(s, .open);
    if (s.first_message) |m| _ = s.sendBinary(m);

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);
    var message_binary = false;
    while (true) {
        var h: [2]u8 = undefined;
        r.readInto(&h) catch break;
        const fin = h[0] & 0x80 != 0;
        const opcode = h[0] & 0x0f;
        const masked = h[1] & 0x80 != 0;
        var len: u64 = h[1] & 0x7f;
        if (len == 126) {
            var b: [2]u8 = undefined;
            r.readInto(&b) catch break;
            len = std.mem.readInt(u16, &b, .big);
        } else if (len == 127) {
            var b: [8]u8 = undefined;
            r.readInto(&b) catch break;
            len = std.mem.readInt(u64, &b, .big);
        }
        if (len > 64 * 1024 * 1024) break;
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) r.readInto(&mask) catch break;
        const payload = gpa.alloc(u8, @intCast(len)) catch break;
        defer gpa.free(payload);
        r.readInto(payload) catch break;
        if (masked) for (payload, 0..) |*b, i| {
            b.* ^= mask[i % 4];
        };

        switch (opcode) {
            0x0, 0x1, 0x2 => {
                if (opcode != 0) {
                    message.clearRetainingCapacity();
                    message_binary = opcode == 0x2;
                }
                message.appendSlice(gpa, payload) catch break;
                if (fin) {
                    post(s, .{ .message = .{ .binary = message_binary, .data = message.items } });
                    message.clearRetainingCapacity();
                }
            },
            0x8 => {
                const code: u16 = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else 1005;
                _ = s.sendFrame(0x8, payload[0..@min(payload.len, 2)]);
                post(s, .{ .close = .{ .code = code, .reason = if (payload.len > 2) payload[2..] else "Connection closed" } });
                return error.Ended;
            },
            0x9 => _ = s.sendFrame(0xA, payload),
            else => {},
        }
    }
    post(s, .{ .close = .{ .code = 1006, .reason = "Connection lost" } });
    return error.Ended;
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
    s: *Socket,
    event: Event,
    owned: ?[]u8,
};

fn post(s: *Socket, event: Event) void {
    if (s.closed.load(.acquire)) return;
    const p = gpa.create(Posted) catch return;
    var copy = event;
    p.owned = null;
    switch (copy) {
        .message => |*m| {
            const d = gpa.dupe(u8, m.data) catch {
                gpa.destroy(p);
                return;
            };
            p.owned = d;
            m.data = d;
        },
        .close => |*c| {
            const d = gpa.dupe(u8, c.reason) catch {
                gpa.destroy(p);
                return;
            };
            p.owned = d;
            c.reason = d;
        },
        .open => {},
    }
    p.s = s;
    p.event = copy;
    s.ref();
    _ = glib.idleAdd(&deliver, p);
}

fn deliver(data: ?*anyopaque) callconv(.c) c_int {
    const p: *Posted = @ptrCast(@alignCast(data.?));
    const s = p.s;
    defer {
        if (p.owned) |o| gpa.free(o);
        gpa.destroy(p);
        s.unref();
    }
    if (s.closed.load(.acquire)) return 0;
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
    return 0;
}

test "host and status parsing" {
    try std.testing.expectEqualStrings("127.0.0.1:18765", hostOf("http://127.0.0.1:18765"));
    try std.testing.expectEqualStrings("mac.tail.ts.net", hostOf("https://mac.tail.ts.net/x"));
    try std.testing.expectEqual(@as(u16, 101), statusOf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket"));
    try std.testing.expectEqual(@as(u16, 403), statusOf("HTTP/1.1 403 Forbidden"));
}
