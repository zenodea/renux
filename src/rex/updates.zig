//! Whether a Rex server could be updated. Rex publishes the newest release of each of its
//! channels (snapshot, preview and stable) as a small public JSON document, and a server says
//! which version it runs, which also tells its channel. Comparing the two is all this does:
//! Renux never updates a server, which is the work of the package manager on its computer.
//! The document is fetched with `curl`, beside the main loop; where curl is missing, or the
//! network is, nothing is known and nothing is said. Main thread only.
const std = @import("std");
const glib = @import("glib");
const json = @import("../util/json.zig");
const proc = @import("../util/proc.zig");
const settings = @import("../settings/settings.zig");

const gpa = std.heap.c_allocator;

pub const Channel = enum { snapshot, preview, stable };

/// How long an answer is good for before the list is read again.
const fresh_us: i64 = 6 * 60 * 60 * 1_000_000;

var latest: [3]?[]u8 = @splat(null);
var asked_at: [3]i64 = @splat(0);
var asking: [3]bool = @splat(false);

/// Called when a channel's newest release becomes known.
pub var changed: ?*const fn () void = null;

/// The channel a version came from: a snapshot is `0.0.` and its build time, as in
/// `0.0.1792508098-g07b896`; a preview says so, as in `0.1.0-preview.14`.
pub fn channelOf(version: []const u8) Channel {
    if (std.mem.indexOf(u8, version, "preview") != null) return .preview;
    if (std.mem.startsWith(u8, version, "0.0.") and version.len > 4 and std.ascii.isDigit(version[4])) return .snapshot;
    return .stable;
}

/// Whether `candidate` is a later release than `running`, both of one channel. Versions are
/// compared number by number, left to right, and the letters between them only separate.
/// A snapshot's commit, after its `g`, is no number and is left out.
pub fn isNewer(candidate: []const u8, running: []const u8) bool {
    var a = Numbers{ .text = numbered(candidate) };
    var b = Numbers{ .text = numbered(running) };
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return false;
        if ((x orelse 0) != (y orelse 0)) return (x orelse 0) > (y orelse 0);
    }
}

/// A snapshot's version without its commit: `0.0.1792508098-g07b896` to `0.0.1792508098`.
/// Packages spell the separator as a dash, a dot or an underscore.
fn numbered(version: []const u8) []const u8 {
    if (channelOf(version) != .snapshot) return version;
    var i: usize = 4;
    while (i < version.len and std.ascii.isDigit(version[i])) i += 1;
    return version[0..i];
}

const Numbers = struct {
    text: []const u8,
    at: usize = 0,
    fn next(n: *Numbers) ?u64 {
        while (n.at < n.text.len and !std.ascii.isDigit(n.text[n.at])) n.at += 1;
        if (n.at >= n.text.len) return null;
        var value: u64 = 0;
        while (n.at < n.text.len and std.ascii.isDigit(n.text[n.at])) : (n.at += 1) value = value *% 10 +% (n.text[n.at] - '0');
        return value;
    }
};

/// The release a server running `version` could move to, if a later one is known.
pub fn available(version: ?[]const u8) ?[]const u8 {
    if (!settings.current.rex_updates) return null;
    const running = version orelse return null;
    const newest = latest[@backingInt(channelOf(running))] orelse return null;
    return if (isNewer(newest, running)) newest else null;
}

/// Reads the newest release of the channel `version` is from, unless that was done lately.
pub fn check(version: ?[]const u8) void {
    if (!settings.current.rex_updates) return;
    const running = version orelse return;
    const ch = channelOf(running);
    const k = @backingInt(ch);
    const now = glib.getMonotonicTime();
    if (asking[k] or (asked_at[k] != 0 and now - asked_at[k] < fresh_us)) return;
    const url: [:0]const u8 = switch (ch) {
        .snapshot => "https://blob.superlogical.com/api/releases/rex/snapshot",
        .preview => "https://blob.superlogical.com/api/releases/rex/preview",
        .stable => "https://blob.superlogical.com/api/releases/rex/stable",
    };
    asked_at[k] = now;
    asking[k] = proc.run(&.{ "curl", "-fsSL", "--max-time", "8", "-A", "renux", url }, @ptrFromInt(k + 1), &answered);
}

fn answered(ctx: ?*anyopaque, output: ?[]const u8) void {
    const k = @intFromPtr(ctx) - 1;
    asking[k] = false;
    const version = versionIn(output orelse return) orelse return;
    defer gpa.free(version);
    if (latest[k]) |old| {
        if (std.mem.eql(u8, old, version)) return;
        gpa.free(old);
    }
    latest[k] = gpa.dupe(u8, version) catch null;
    if (changed) |f| f();
}

/// The `version` of a release document, the caller's to free. Anything that could not be a
/// version, such as a web page from a network that answers every address, is turned down.
fn versionIn(text: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(json.Value, gpa, text, .{}) catch return null;
    defer parsed.deinit();
    const v = json.str(parsed.value, "version") orelse return null;
    if (v.len == 0 or v.len > 64 or !std.ascii.isDigit(v[0])) return null;
    for (v) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_' and c != '+') return null;
    return gpa.dupe(u8, v) catch null;
}

test channelOf {
    try std.testing.expectEqual(Channel.snapshot, channelOf("0.0.1792508098-g07b896"));
    try std.testing.expectEqual(Channel.snapshot, channelOf("0.0.1792508098.g07b896"));
    try std.testing.expectEqual(Channel.preview, channelOf("0.1.0-preview.14"));
    try std.testing.expectEqual(Channel.stable, channelOf("0.1.0"));
    try std.testing.expectEqual(Channel.stable, channelOf("0.1.0-r0"));
}

test isNewer {
    try std.testing.expect(isNewer("0.0.1794342211-g98dc41", "0.0.1793645657-gd018d2"));
    try std.testing.expect(!isNewer("0.0.1793645657-gd018d2", "0.0.1794342211-g98dc41"));
    // The same build under a package's spelling, and a commit whose digits would count.
    try std.testing.expect(!isNewer("0.0.1793645657-g918d27", "0.0.1793645657_g018d21"));
    try std.testing.expect(isNewer("0.1.0-preview.14", "0.1.0-preview.9"));
    try std.testing.expect(!isNewer("0.1.0-preview.14", "0.1.0-preview.14"));
    try std.testing.expect(isNewer("0.1.1", "0.1.0"));
    try std.testing.expect(isNewer("0.2.0", "0.1.9"));
    try std.testing.expect(!isNewer("0.1.0", "0.1.0"));
}

test versionIn {
    const v = versionIn("{\"schemaVersion\":1,\"channel\":\"preview\",\"version\":\"0.1.0-preview.14\",\"artifacts\":[]}").?;
    defer gpa.free(v);
    try std.testing.expectEqualStrings("0.1.0-preview.14", v);
    try std.testing.expect(versionIn("<!doctype html><html>") == null);
    try std.testing.expect(versionIn("{\"error\":\"No Rex stable release is available\"}") == null);
    try std.testing.expect(versionIn("{\"version\":\"1.0 <b>\"}") == null);
}
