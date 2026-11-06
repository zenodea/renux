//! The live contents of one terminal block: its data stream from the server and the local
//! libghostty-vt terminal that interprets it. Views listen for changes and draw the frame.
const std = @import("std");
const glib = @import("glib");
const ws = @import("ws.zig");
const json = @import("json.zig");
const Term = @import("term.zig").Term;
const Server = @import("server.zig").Server;

const gpa = std.heap.c_allocator;

pub const protocol = "rex.data.terminal.v1";
const hello_byte = 0x01;
const resume_byte = 0x02;
const welcome_byte = 0x81;
const reject_byte = 0x82;
const reject_unavailable = 0x03;
const close_block_closed = 4000;

pub const State = enum { connecting, live, reconnecting, closed };

/// Default colors for a terminal. Each is 0xFFRRGGBB, or 0 for the built-in value.
pub const Colors = struct {
    fg: u32 = 0,
    bg: u32 = 0,
    cursor: u32 = 0,
    palette: ?[256]u32 = null,

    pub fn fromTheme(msg: json.Value) Colors {
        var c: Colors = .{
            .fg = hex(json.str(msg, "foreground")),
            .bg = hex(json.str(msg, "background")),
            .cursor = hex(json.str(msg, "cursor")),
        };
        const changes = json.array(msg, "palette");
        if (changes.len > 0) {
            var p = builtin_palette;
            for (changes) |change| {
                const s = switch (change) {
                    .string => |s| s,
                    else => continue,
                };
                const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
                const index = std.fmt.parseInt(u8, s[0..eq], 10) catch continue;
                const color = hex(s[eq + 1 ..]);
                if (color != 0) p[index] = color;
            }
            c.palette = p;
        }
        return c;
    }
};

pub fn hex(value: ?[]const u8) u32 {
    var s = std.mem.trim(u8, value orelse return 0, " ");
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (s.len != 6) return 0;
    return 0xFF000000 | (std.fmt.parseInt(u32, s, 16) catch return 0);
}

/// The standard xterm 256-color palette.
pub const builtin_palette: [256]u32 = blk: {
    var p: [256]u32 = undefined;
    const base = [16]u32{
        0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
        0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
    };
    for (0..16) |i| p[i] = base[i] | 0xFF000000;
    const steps = [6]u32{ 0, 95, 135, 175, 215, 255 };
    var n: usize = 16;
    for (steps) |r| for (steps) |g| for (steps) |b| {
        p[n] = 0xFF000000 | (r << 16) | (g << 8) | b;
        n += 1;
    };
    for (0..24) |i| {
        const v: u32 = 8 + @as(u32, @intCast(i)) * 10;
        p[n] = 0xFF000000 | (v << 16) | (v << 8) | v;
        n += 1;
    }
    break :blk p;
};

pub const Listener = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque) void,
};

pub const Stream = struct {
    server: *Server,
    session_id: []u8,
    block_id: []u8,
    socket: ?*ws.Socket = null,
    welcomed: bool = false,
    term: ?*Term = null,
    state: State = .connecting,
    cols: u16 = 0,
    rows: u16 = 0,
    used_fallback: bool = false,
    child_exited: bool = false,
    token: ?[16]u8 = null,
    nonce: u64 = 0,
    received: u64 = 0,
    parser: ?Parser = null,
    generation: u32 = 0,
    retries: u5 = 0,
    retry_timer: c_uint = 0,
    stopped: bool = false,
    theme: ?Colors = null,
    listeners: std.ArrayList(Listener) = .empty,

    pub fn create(server: *Server, session_id: []const u8, block_id: []const u8) !*Stream {
        const s = try gpa.create(Stream);
        s.* = .{
            .server = server,
            .session_id = try gpa.dupe(u8, session_id),
            .block_id = try gpa.dupe(u8, block_id),
        };
        s.openNew();
        return s;
    }

    pub fn destroy(s: *Stream) void {
        s.stopped = true;
        s.cancelRetry();
        s.dropSocket(true);
        if (s.term) |t| t.destroy();
        if (s.parser) |*p| p.deinit();
        s.listeners.deinit(gpa);
        gpa.free(s.session_id);
        gpa.free(s.block_id);
        gpa.destroy(s);
    }

    pub fn addListener(s: *Stream, l: Listener) void {
        s.listeners.append(gpa, l) catch {};
        l.changed(l.ctx);
    }

    pub fn removeListener(s: *Stream, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < s.listeners.items.len) {
            if (s.listeners.items[i].ctx == ctx) _ = s.listeners.swapRemove(i) else i += 1;
        }
    }

    fn changed(s: *Stream) void {
        for (s.listeners.items) |l| l.changed(l.ctx);
    }

    /// Connects again after the network or the control connection returned.
    pub fn reconnect(s: *Stream) void {
        if (s.stopped or s.state == .closed) return;
        s.cancelRetry();
        s.dropSocket(false);
        if (s.token != null) s.openResume() else s.openNew();
    }

    /// Call when the host's usual colors change.
    pub fn hostColorsChanged(s: *Stream) void {
        s.applyColors();
        s.changed();
    }

    fn applyColors(s: *Stream) void {
        const t = s.term orelse return;
        const theme = @import("theme.zig");
        const c = s.theme orelse s.server.host_colors orelse Colors{};
        t.setColors(if (c.fg != 0) c.fg else theme.default_fg, if (c.bg != 0) c.bg else theme.default_bg, c.cursor, if (c.palette) |*p| p else null);
    }

    fn cancelRetry(s: *Stream) void {
        if (s.retry_timer != 0) _ = glib.Source.remove(s.retry_timer);
        s.retry_timer = 0;
    }

    fn dropSocket(s: *Stream, clean: bool) void {
        const sock = s.socket orelse return;
        s.socket = null;
        if (clean) sock.close() else sock.abandon();
    }

    fn openNew(s: *Stream) void {
        s.generation +%= 1;
        s.state = if (s.term == null) .connecting else .reconnecting;
        s.server.requestTicket(s, s.generation);
    }

    /// The server issued a ticket for the attempt numbered `gen`.
    pub fn gotTicket(s: *Stream, gen: u32, ticket: []const u8) void {
        if (gen != s.generation or s.stopped) return;
        if (s.parser) |*p| p.deinit();
        s.parser = null;
        s.received = 0;
        s.token = null;
        var hello: [17]u8 = @splat(0);
        hello[0] = hello_byte;
        std.base64.url_safe_no_pad.Decoder.decode(hello[1..], std.mem.trimEnd(u8, ticket, "=")) catch {
            s.scheduleRetry(gen, true);
            return;
        };
        s.connect(&hello);
    }

    pub fn ticketFailed(s: *Stream, gen: u32) void {
        if (gen != s.generation or s.stopped) return;
        s.scheduleRetry(gen, true);
    }

    fn openResume(s: *Stream) void {
        const t = s.token orelse return s.openNew();
        s.generation +%= 1;
        s.state = .reconnecting;
        var msg: [25]u8 = undefined;
        msg[0] = resume_byte;
        @memcpy(msg[1..17], &t);
        std.mem.writeInt(u64, msg[17..25], s.received, .little);
        s.connect(&msg);
    }

    fn connect(s: *Stream, handshake: []const u8) void {
        s.welcomed = false;
        s.socket = ws.Socket.open(.{
            .url = s.server.url,
            .path = "/api/data",
            .protocol = protocol,
            .first_message = handshake,
        }, .{ .ctx = s, .on_open = onOpen, .on_message = onMessage, .on_close = onClose }) catch {
            s.scheduleRetry(s.generation, false);
            return;
        };
    }

    fn scheduleRetry(s: *Stream, gen: u32, fresh: bool) void {
        if (gen != s.generation or s.stopped) return;
        s.dropSocket(false);
        s.state = .reconnecting;
        if (fresh) s.token = null;
        s.changed();
        const wait: c_uint = @min(10_000, @as(c_uint, 500) << @min(s.retries, 5));
        if (s.retries < 31) s.retries += 1;
        s.cancelRetry();
        s.retry_timer = glib.timeoutAdd(wait, &retryNow, s);
    }

    fn retryNow(data: ?*anyopaque) callconv(.c) c_int {
        const s: *Stream = @ptrCast(@alignCast(data.?));
        s.retry_timer = 0;
        if (!s.stopped) {
            if (s.token != null) s.openResume() else s.openNew();
        }
        return 0;
    }

    fn handshakeReply(s: *Stream, data: []const u8) void {
        if (data.len == 0) return;
        switch (data[0]) {
            welcome_byte => if (data.len >= 32) {
                s.welcomed = true;
                s.retries = 0;
                s.token = data[1..17].*;
                const nonce = std.mem.readInt(u64, data[24..32], .little);
                const resumed = s.parser != null and nonce == s.nonce;
                s.nonce = nonce;
                if (!resumed) {
                    if (s.parser) |*p| p.deinit();
                    s.parser = Parser.init(nonce);
                }
                s.state = .live;
            },
            reject_byte => {
                // A refused RESUME or HELLO means starting over with a new ticket.
                s.token = null;
                if (s.parser) |*p| p.deinit();
                s.parser = null;
                const reason: u8 = if (data.len > 1) data[1] else 0;
                if (reason == reject_unavailable and !s.child_exited and s.term == null) {
                    s.dropSocket(false);
                    s.state = .closed;
                    s.changed();
                } else {
                    s.scheduleRetry(s.generation, true);
                }
            },
            else => {},
        }
    }

    fn onOpen(_: *anyopaque) void {}

    fn onMessage(ctx: *anyopaque, binary: bool, data: []const u8) void {
        const s: *Stream = @ptrCast(@alignCast(ctx));
        if (!binary) return;
        if (!s.welcomed) {
            s.handshakeReply(data);
            s.changed();
            return;
        }
        s.received += data.len;
        if (s.parser) |*p| p.feed(s, data);
        s.changed();
    }

    fn onClose(ctx: *anyopaque, code: u16, _: []const u8) void {
        const s: *Stream = @ptrCast(@alignCast(ctx));
        s.socket = null; // already gone
        if (s.stopped) return;
        switch (code) {
            close_block_closed, 1000 => s.state = .closed,
            1013, 1008, 1011 => s.scheduleRetry(s.generation, true),
            else => s.scheduleRetry(s.generation, false),
        }
        s.changed();
    }

    // Parser output.

    fn handleSnapshot(s: *Stream, bytes: []const u8) void {
        const old = s.term;
        if (Term.fromSnapshot(bytes)) |t| {
            s.used_fallback = false;
            s.term = t;
        } else {
            s.used_fallback = true;
            s.term = Term.create(@max(s.cols, 80), @max(s.rows, 24));
            s.server.readScreen(s);
        }
        if (old) |o| o.destroy();
        s.applyColors();
    }

    /// The fallback screen, fetched as escape sequences after a snapshot failed to decode.
    pub fn gotScreen(s: *Stream, screen: []const u8) void {
        if (s.term) |t| t.write(screen);
        s.changed();
    }

    fn handleOutput(s: *Stream, data: []const u8) void {
        if (s.term) |t| t.write(data);
    }

    fn handleMessage(s: *Stream, msg: json.Value) void {
        const kind = json.str(msg, "type") orelse return;
        if (std.mem.eql(u8, kind, "resize")) {
            const cols = json.int(msg, "cols") orelse return;
            const rows = json.int(msg, "rows") orelse return;
            s.cols = @intCast(std.math.clamp(cols, 1, 65535));
            s.rows = @intCast(std.math.clamp(rows, 1, 65535));
            if (s.term) |t| t.resize(s.cols, s.rows, @intCast(@max(0, json.int(msg, "cell_width_px") orelse 0)), @intCast(@max(0, json.int(msg, "cell_height_px") orelse 0)));
        } else if (std.mem.eql(u8, kind, "theme")) {
            s.theme = Colors.fromTheme(msg);
            s.server.gotHostColors(s.theme.?);
            s.applyColors();
        } else if (std.mem.eql(u8, kind, "child_exited")) {
            s.child_exited = true;
        }
    }
};

/// Splits a terminal stream into its three parts: the leading Ghostty snapshot, program output,
/// and Rex's own messages. A Rex message is `ESC _ rex1;<nonce>;<json> ESC \`, and the first one
/// comes straight after the snapshot, so its marker also shows where the snapshot ends.
pub const Parser = struct {
    marker_buf: [48]u8,
    marker_len: usize,
    snapshot: std.ArrayList(u8) = .empty,
    in_snapshot: bool = true,
    pending: std.ArrayList(u8) = .empty,
    searched_to: usize = 0,

    const max_message = 1 << 20;

    pub fn init(nonce: u64) Parser {
        var p: Parser = .{ .marker_buf = undefined, .marker_len = 0 };
        const m = std.fmt.bufPrint(&p.marker_buf, "\x1b_rex1;{d};", .{nonce}) catch unreachable;
        p.marker_len = m.len;
        return p;
    }

    pub fn deinit(p: *Parser) void {
        p.snapshot.deinit(gpa);
        p.pending.deinit(gpa);
    }

    fn marker(p: *const Parser) []const u8 {
        return p.marker_buf[0..p.marker_len];
    }

    pub fn feed(p: *Parser, sink: anytype, data: []const u8) void {
        if (p.in_snapshot) {
            p.snapshot.appendSlice(gpa, data) catch return;
            const bytes = p.snapshot.items;
            const start = p.searched_to -| p.marker_len;
            const at = std.mem.indexOfPos(u8, bytes, start, p.marker()) orelse {
                p.searched_to = bytes.len;
                return;
            };
            p.in_snapshot = false;
            sink.handleSnapshot(bytes[0..at]);
            const rest = gpa.dupe(u8, bytes[at..]) catch return;
            defer gpa.free(rest);
            p.snapshot.clearAndFree(gpa);
            p.scan(sink, rest);
            return;
        }
        p.scan(sink, data);
    }

    fn scan(p: *Parser, sink: anytype, chunk: []const u8) void {
        var joined: ?[]u8 = null;
        defer if (joined) |j| gpa.free(j);
        var data = chunk;
        if (p.pending.items.len > 0) {
            const j = std.mem.concat(gpa, u8, &.{ p.pending.items, chunk }) catch return;
            joined = j;
            data = j;
            p.pending.clearRetainingCapacity();
        }
        const m = p.marker();
        var flushed: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            if (data[i] != 0x1b) {
                i += 1;
                continue;
            }
            var matched: usize = 0;
            while (matched < m.len and i + matched < data.len and data[i + matched] == m[matched]) matched += 1;
            if (matched == m.len) {
                const end = findTerminator(data, i + m.len) orelse {
                    if (data.len - i > max_message) {
                        // No real Rex message is this large, so treat it as output.
                        i += m.len;
                        continue;
                    }
                    if (i > flushed) sink.handleOutput(data[flushed..i]);
                    p.pending.appendSlice(gpa, data[i..]) catch {};
                    return;
                };
                if (i > flushed) sink.handleOutput(data[flushed..i]);
                parseMessage(sink, data[i + m.len .. end]);
                i = end + 2;
                flushed = i;
            } else if (i + matched == data.len) {
                // The chunk ends partway through what may be the marker.
                if (i > flushed) sink.handleOutput(data[flushed..i]);
                p.pending.appendSlice(gpa, data[i..]) catch {};
                return;
            } else {
                i += 1;
            }
        }
        if (data.len > flushed) sink.handleOutput(data[flushed..]);
    }

    fn findTerminator(data: []const u8, from: usize) ?usize {
        var i = from;
        while (i + 1 < data.len) : (i += 1) {
            if (data[i] == 0x1b and data[i + 1] == '\\') return i;
        }
        return null;
    }

    fn parseMessage(sink: anytype, text: []const u8) void {
        var parsed = std.json.parseFromSlice(json.Value, gpa, text, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value == .object) sink.handleMessage(parsed.value);
    }
};

test "parser splits snapshot, output and messages across chunks" {
    const Sink = struct {
        snapshot: std.ArrayList(u8) = .empty,
        output: std.ArrayList(u8) = .empty,
        messages: usize = 0,
        last_type: [16]u8 = undefined,
        fn handleSnapshot(k: *@This(), b: []const u8) void {
            k.snapshot.appendSlice(gpa, b) catch {};
        }
        fn handleOutput(k: *@This(), b: []const u8) void {
            k.output.appendSlice(gpa, b) catch {};
        }
        fn handleMessage(k: *@This(), v: json.Value) void {
            k.messages += 1;
            const t = json.str(v, "type") orelse "";
            @memcpy(k.last_type[0..t.len], t);
        }
    };
    var sink: Sink = .{};
    defer sink.snapshot.deinit(gpa);
    defer sink.output.deinit(gpa);
    var p = Parser.init(42);
    defer p.deinit();
    const stream = "SNAP\x1b_rex1;42;{\"type\":\"resize\",\"cols\":80}\x1b\\hello \x1b[1mworld\x1b_rex1;42;{\"type\":\"theme\"}\x1b\\!";
    // Feed it one byte at a time, the hardest split.
    for (0..stream.len) |i| p.feed(&sink, stream[i .. i + 1]);
    try std.testing.expectEqualStrings("SNAP", sink.snapshot.items);
    try std.testing.expectEqualStrings("hello \x1b[1mworld!", sink.output.items);
    try std.testing.expectEqual(@as(usize, 2), sink.messages);
    try std.testing.expectEqualStrings("theme", sink.last_type[0..5]);
}

test "theme colors" {
    var parsed = try std.json.parseFromSlice(json.Value, gpa, "{\"foreground\":\"#ffffff\",\"background\":\"101010\",\"palette\":[\"1=#ff0000\"]}", .{});
    defer parsed.deinit();
    const c = Colors.fromTheme(parsed.value);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), c.fg);
    try std.testing.expectEqual(@as(u32, 0xFF101010), c.bg);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), c.palette.?[1]);
    try std.testing.expectEqual(builtin_palette[2], c.palette.?[2]);
}
