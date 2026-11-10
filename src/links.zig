//! Finds web links in terminal text, including ones a narrow pane wrapped onto several rows.
const std = @import("std");

/// One row's part of a link; `end` is inclusive.
pub const Segment = struct { row: usize, start: usize, end: usize };

pub const Link = struct {
    url: []u8,
    segments: std.ArrayList(Segment),

    pub fn deinit(l: *Link, gpa: std.mem.Allocator) void {
        gpa.free(l.url);
        l.segments.deinit(gpa);
    }

    pub fn contains(l: Link, col: usize, row: usize) bool {
        for (l.segments.items) |s| if (s.row == row and col >= s.start and col <= s.end) return true;
        return false;
    }
};

fn notUrl(c: u21) bool {
    return switch (c) {
        ' ', '\t', '<', '>', '"', '\'', '`', '|', '\\', '^', '{', '}', 0 => true,
        else => false,
    };
}

fn trailing(c: u21) bool {
    return switch (c) {
        '.', ',', ';', ':', '!', '?', ')', ']', '}', '*', '_' => true,
        else => false,
    };
}

/// The link under (col, row), if any. `rows` holds one codepoint per column for each row, and
/// `wraps` says for each row whether its line carries on into the next: a link only continues
/// across rows the terminal wrapped, not into whatever the next line happens to start with.
pub fn at(gpa: std.mem.Allocator, rows: []const []const u21, wraps: []const bool, col: usize, row: usize) !?Link {
    var y: usize = 0;
    while (y < rows.len) {
        var next_row = y + 1;
        const r = rows[y];
        var x: usize = 0;
        while (x + 7 < r.len) : (x += 1) {
            const is_https = startsWith(r[x..], "https://");
            if (!is_https and !startsWith(r[x..], "http://")) continue;
            if (x > 0 and !notUrl(r[x - 1]) and r[x - 1] != '(' and r[x - 1] != '[') continue;
            var link: Link = .{ .url = &.{}, .segments = .empty };
            errdefer link.segments.deinit(gpa);
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(gpa);
            var end = x;
            while (end < r.len and !notUrl(r[end])) : (end += 1) try appendCp(gpa, &text, r[end]);
            try link.segments.append(gpa, .{ .row = y, .start = x, .end = end - 1 });
            // A link touching the right edge of a wrapped row carries on at the start of the next.
            var line = y;
            var reached = end == r.len;
            while (reached and line + 1 < rows.len and line < wraps.len and wraps[line]) {
                const nr = rows[line + 1];
                var run: usize = 0;
                while (run < nr.len and !notUrl(nr[run])) : (run += 1) try appendCp(gpa, &text, nr[run]);
                if (run == 0) break;
                line += 1;
                try link.segments.append(gpa, .{ .row = line, .start = 0, .end = run - 1 });
                reached = run == nr.len;
            }
            if (line + 1 > next_row) next_row = line + 1;
            trim(&text, &link.segments);
            x = end;
            if (link.contains(col, row)) {
                link.url = try text.toOwnedSlice(gpa);
                return link;
            }
            link.segments.deinit(gpa);
        }
        y = next_row;
    }
    return null;
}

/// Sentence punctuation after a link isn't part of it, but its closing brackets may be.
fn trim(text: *std.ArrayList(u8), segments: *std.ArrayList(Segment)) void {
    while (text.items.len > 0 and trailing(text.items[text.items.len - 1])) {
        const last_char = text.items[text.items.len - 1];
        if (last_char == ')' and std.mem.count(u8, text.items, "(") >= std.mem.count(u8, text.items, ")")) break;
        text.items.len -= 1;
        const last = &segments.items[segments.items.len - 1];
        if (last.end > last.start) last.end -= 1 else if (segments.items.len > 1) segments.items.len -= 1;
    }
}

fn startsWith(r: []const u21, prefix: []const u8) bool {
    if (r.len < prefix.len) return false;
    for (prefix, 0..) |c, i| if (r[i] != c) return false;
    return true;
}

fn appendCp(gpa: std.mem.Allocator, text: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try text.appendSlice(gpa, buf[0..n]);
}

fn toRow(comptime s: []const u8) [s.len]u21 {
    var out: [s.len]u21 = undefined;
    for (s, 0..) |c, i| out[i] = c;
    return out;
}

test "finds a link under the pointer, trims punctuation, and follows wraps" {
    const gpa = std.testing.allocator;
    const a = toRow("see https://example.com/x.");
    var l = (try at(gpa, &.{&a}, &.{false}, 8, 0)).?;
    defer l.deinit(gpa);
    try std.testing.expectEqualStrings("https://example.com/x", l.url);
    try std.testing.expect((try at(gpa, &.{&a}, &.{false}, 1, 0)) == null);

    const r1 = toRow("go https://exa");
    const r2 = toRow("mple.org/p ok  ");
    var w = (try at(gpa, &.{ &r1, &r2 }, &.{ true, false }, 3, 1)).?;
    defer w.deinit(gpa);
    try std.testing.expectEqualStrings("https://example.org/p", w.url);
}

test "a link ending at the right edge doesn't swallow the next line" {
    const gpa = std.testing.allocator;
    const r1 = toRow("go https://exa");
    const r2 = toRow("mple.org/p ok  ");
    // The same two rows, but the first ended with a new line rather than wrapping.
    var l = (try at(gpa, &.{ &r1, &r2 }, &.{ false, false }, 5, 0)).?;
    defer l.deinit(gpa);
    try std.testing.expectEqualStrings("https://exa", l.url);
    try std.testing.expect((try at(gpa, &.{ &r1, &r2 }, &.{ false, false }, 3, 1)) == null);

    // Three wrapped rows join; the wrap flags may be shorter than the rows without harm.
    const a = toRow("https://a.");
    const b = toRow("example/lo");
    const c = toRow("ng/path   ");
    var long = (try at(gpa, &.{ &a, &b, &c }, &.{ true, true, false }, 2, 2)).?;
    defer long.deinit(gpa);
    try std.testing.expectEqualStrings("https://a.example/long/path", long.url);
    var cut = (try at(gpa, &.{ &a, &b, &c }, &.{true}, 2, 1)).?;
    defer cut.deinit(gpa);
    try std.testing.expectEqualStrings("https://a.example/lo", cut.url);
}
