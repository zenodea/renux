//! What this computer's Tailscale knows: whether it's signed in, as whom, and which devices on
//! the tailnet run Rex. It only reads `tailscale status --json`; nothing is changed or sent.
const std = @import("std");
const glib = @import("glib");
const json = @import("json.zig");
const proc = @import("proc.zig");

const gpa = std.heap.c_allocator;

pub const Peer = struct { name: []u8, url: []u8, online: bool };

pub const Status = struct {
    running: bool = false,
    /// Why Tailscale couldn't be read, when it couldn't.
    problem: ?[]const u8 = null,
    login: ?[]u8 = null,
    tailnet: ?[]u8 = null,
    self_name: ?[]u8 = null,
    rex_hosts: std.ArrayList(Peer) = .empty,

    pub fn deinit(s: *Status) void {
        inline for (.{ "login", "tailnet", "self_name" }) |f| if (@field(s, f)) |v| gpa.free(v);
        for (s.rex_hosts.items) |p| {
            gpa.free(p.name);
            gpa.free(p.url);
        }
        s.rex_hosts.deinit(gpa);
    }
};

/// Where the tailscale command lives: on the path, or inside the Mac app.
const commands = [_][]const [:0]const u8{
    &.{ "tailscale", "status", "--json" },
    &.{ "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "status", "--json" },
};

/// Hears the status once. It lives only for the call.
pub const Done = *const fn (ctx: ?*anyopaque, status: *Status) void;

const Reading = struct { ctx: ?*anyopaque, done: Done };

/// Reads the status without holding up the window: a Tailscale that is stopped or stuck can
/// take seconds to answer. `done` is called once, at once if Tailscale isn't installed.
pub fn read(ctx: ?*anyopaque, done: Done) void {
    var st: Status = .{ .problem = "Tailscale isn't installed on this computer" };
    defer st.deinit();
    const reading = gpa.create(Reading) catch return done(ctx, &st);
    reading.* = .{ .ctx = ctx, .done = done };
    for (commands) |argv| if (proc.run(argv, reading, &answered)) return;
    gpa.destroy(reading);
    done(ctx, &st);
}

fn answered(data: ?*anyopaque, output: ?[]const u8) void {
    const reading: *Reading = @ptrCast(@alignCast(data.?));
    defer gpa.destroy(reading);
    var st: Status = if (output) |text| fromOutput(text) else .{ .problem = "Tailscale didn't answer on this computer" };
    defer st.deinit();
    reading.done(reading.ctx, &st);
}

fn fromOutput(text: []const u8) Status {
    if (std.mem.trim(u8, text, " \n\r\t").len == 0) return .{ .problem = "Tailscale isn't running on this computer" };
    return parse(text);
}

pub fn parse(text: []const u8) Status {
    var st: Status = .{};
    var parsed = std.json.parseFromSlice(json.Value, gpa, text, .{}) catch return .{ .problem = "Tailscale gave an answer Compy couldn't read" };
    defer parsed.deinit();
    const root = parsed.value;
    st.running = std.mem.eql(u8, json.str(root, "BackendState") orelse "", "Running");
    if (!st.running) st.problem = "Tailscale isn't connected on this computer";
    const self = json.get(root, "Self");
    if (json.str(self, "HostName")) |n| st.self_name = gpa.dupe(u8, n) catch null;
    if (json.str(json.get(root, "CurrentTailnet"), "Name")) |n| st.tailnet = gpa.dupe(u8, n) catch null;
    // The signed-in account: Self's user in the User table.
    if (json.get(self, "UserID")) |uid| {
        var buf: [32]u8 = undefined;
        const key = switch (uid) {
            .integer => |i| std.fmt.bufPrint(&buf, "{d}", .{i}) catch "",
            .string => |s| s,
            else => "",
        };
        if (json.str(json.get(json.get(root, "User"), key), "LoginName")) |l| st.login = gpa.dupe(u8, l) catch null;
    }
    // Rex serves each machine on the tailnet as a node whose name ends in "-rex".
    if (json.get(root, "Peer")) |peers| if (peers == .object) {
        var it = peers.object.iterator();
        while (it.next()) |e| {
            const p = e.value_ptr.*;
            const dns = std.mem.trimEnd(u8, json.str(p, "DNSName") orelse continue, ".");
            const first = dns[0 .. std.mem.indexOfScalar(u8, dns, '.') orelse dns.len];
            if (!std.mem.endsWith(u8, first, "-rex")) continue;
            st.rex_hosts.append(gpa, .{
                .name = gpa.dupe(u8, first) catch continue,
                .url = std.fmt.allocPrint(gpa, "https://{s}", .{dns}) catch continue,
                .online = json.boolean(p, "Online") orelse false,
            }) catch {};
        }
    };
    return st;
}

/// Whether text looks like a Rex address worth offering from the clipboard, such as the one
/// Rex's Pair button shows.
pub fn looksLikeAddress(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \n\r\t");
    if (t.len == 0 or t.len > 300 or std.mem.indexOfAny(u8, t, " \n") != null) return false;
    return std.mem.startsWith(u8, t, "https://") or std.mem.startsWith(u8, t, "http://") or std.mem.endsWith(u8, t, ".ts.net");
}

test "tailscale status finds Rex nodes and the account" {
    var st = parse(
        \\{"BackendState":"Running","CurrentTailnet":{"Name":"someone@example.com"},
        \\"Self":{"HostName":"laptop","UserID":42},"User":{"42":{"LoginName":"someone@example.com"}},
        \\"Peer":{"k1":{"DNSName":"desk-rex.tail0000.ts.net.","Online":true},"k2":{"DNSName":"phone.tail0000.ts.net.","Online":true}}}
    );
    defer st.deinit();
    try std.testing.expect(st.running);
    try std.testing.expectEqualStrings("someone@example.com", st.login.?);
    try std.testing.expectEqual(@as(usize, 1), st.rex_hosts.items.len);
    try std.testing.expectEqualStrings("https://desk-rex.tail0000.ts.net", st.rex_hosts.items[0].url);
    try std.testing.expect(looksLikeAddress("https://desk-rex.tail0000.ts.net"));
    try std.testing.expect(!looksLikeAddress("hello there"));
}

test "an empty answer means Tailscale isn't running" {
    var st = fromOutput(" \n");
    defer st.deinit();
    try std.testing.expect(!st.running);
    try std.testing.expectEqualStrings("Tailscale isn't running on this computer", st.problem.?);
}
