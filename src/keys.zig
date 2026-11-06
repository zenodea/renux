//! Turns GDK key presses into keys as Rex's client.key expects them. Characters map to US layout
//! key names, like the Android app, and the server encodes them for the program.
const std = @import("std");

pub const shift = 1;
pub const ctrl = 2;
pub const alt = 4;
pub const super = 8;

pub const Key = struct {
    name: []const u8,
    mods: u4 = 0,
    consumed_shift: bool = false,
    text_buf: [8]u8 = undefined,
    text_len: u8 = 0,
    unshifted: u21 = 0,

    pub fn text(k: *const Key) []const u8 {
        return k.text_buf[0..k.text_len];
    }

    pub fn jsonStringify(k: Key, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("key");
        try jw.write(k.name);
        try jw.objectField("mods");
        try jw.write(modsString(k.mods));
        try jw.objectField("consumed_mods");
        try jw.write(if (k.consumed_shift) "shift" else "");
        try jw.objectField("text");
        try jw.write(k.text_buf[0..k.text_len]);
        try jw.objectField("unshifted_codepoint");
        try jw.write(k.unshifted);
        try jw.objectField("composing");
        try jw.write(false);
        try jw.objectField("action");
        try jw.write("press");
        try jw.endObject();
    }
};

const mods_table = blk: {
    var t: [16][]const u8 = undefined;
    for (0..16) |m| {
        var s: []const u8 = "";
        for (.{ .{ shift, "shift" }, .{ ctrl, "ctrl" }, .{ alt, "alt" }, .{ super, "super" } }) |pair| {
            if (m & pair[0] != 0) s = if (s.len == 0) pair[1] else s ++ "+" ++ pair[1];
        }
        t[m] = s;
    }
    break :blk t;
};

pub fn modsString(m: u4) []const u8 {
    return mods_table[m];
}

/// GDK modifier bits for shift, control, alt (mod1) and super.
pub fn modsFromGdk(state: u32) u4 {
    var m: u4 = 0;
    if (state & (1 << 0) != 0) m |= shift;
    if (state & (1 << 2) != 0) m |= ctrl;
    if (state & (1 << 3) != 0) m |= alt;
    if (state & (1 << 26) != 0) m |= super;
    return m;
}

const special = [_]struct { u32, []const u8, []const u8 }{
    .{ 0xff0d, "enter", "\r" },
    .{ 0xff8d, "numpad_enter", "\r" },
    .{ 0xff09, "tab", "\t" },
    .{ 0xfe20, "tab", "" }, // ISO_Left_Tab, what Shift+Tab sends
    .{ 0xff08, "backspace", "" },
    .{ 0xff1b, "escape", "" },
    .{ 0xff52, "arrow_up", "" },
    .{ 0xff54, "arrow_down", "" },
    .{ 0xff51, "arrow_left", "" },
    .{ 0xff53, "arrow_right", "" },
    .{ 0xff50, "home", "" },
    .{ 0xff57, "end", "" },
    .{ 0xff55, "page_up", "" },
    .{ 0xff56, "page_down", "" },
    .{ 0xff63, "insert", "" },
    .{ 0xffff, "delete", "" },
};

const f_names = [_][]const u8{ "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" };

/// Keys that on their own change nothing, such as Shift.
pub fn isModifier(keyval: u32) bool {
    return (keyval >= 0xffe1 and keyval <= 0xffee) or keyval == 0xfe03; // Shift_L..Hyper_R, ISO_Level3_Shift
}

/// The key for a GDK key press, or null for keys Rex has no name for.
/// `unicode` is gdk_keyval_to_unicode(keyval), or 0.
pub fn fromGdk(keyval: u32, unicode: u32, mods: u4) ?Key {
    for (special) |s| if (s[0] == keyval) {
        var k: Key = .{ .name = s[1], .mods = mods };
        if (keyval == 0xfe20) k.mods |= shift;
        // Control and Alt combinations type nothing themselves; the server encodes them.
        if (mods & (ctrl | alt | super) == 0) setText(&k, s[2]);
        return k;
    };
    if (keyval >= 0xffbe and keyval <= 0xffc9) return .{ .name = f_names[keyval - 0xffbe], .mods = mods };
    if (unicode == 0 or unicode > 0x10ffff) return null;
    return forChar(@intCast(unicode), mods);
}

/// The key for a typed character on a US layout. Characters with no key, such as é, come back
/// as an unidentified key carrying only their text.
pub fn forChar(ch: u21, mods_in: u4) Key {
    var mods = mods_in;
    var name: []const u8 = "unidentified";
    var unshifted: u21 = 0;
    var consumed = false;
    if (ch >= 'a' and ch <= 'z') {
        name = letter_names[ch - 'a'];
        unshifted = ch;
    } else if (ch >= 'A' and ch <= 'Z') {
        name = letter_names[ch - 'A'];
        unshifted = ch + 32;
        mods |= shift;
        consumed = true;
    } else if (ch >= '0' and ch <= '9') {
        name = digit_names[ch - '0'];
        unshifted = ch;
    } else if (baseName(ch)) |n| {
        name = n;
        unshifted = ch;
    } else if (shiftedName(ch)) |pair| {
        name = pair[0];
        unshifted = pair[1];
        mods |= shift;
        consumed = true;
    }
    var k: Key = .{ .name = name, .mods = mods, .consumed_shift = consumed, .unshifted = unshifted };
    if (mods & (ctrl | alt | super) == 0) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &buf) catch 0;
        setText(&k, buf[0..n]);
    }
    return k;
}

fn setText(k: *Key, t: []const u8) void {
    const n = @min(t.len, k.text_buf.len);
    @memcpy(k.text_buf[0..n], t[0..n]);
    k.text_len = @intCast(n);
}

const letter_names = blk: {
    var t: [26][]const u8 = undefined;
    for (0..26) |i| t[i] = "key_" ++ [_]u8{'a' + i};
    break :blk t;
};

const digit_names = blk: {
    var t: [10][]const u8 = undefined;
    for (0..10) |i| t[i] = "digit_" ++ [_]u8{'0' + i};
    break :blk t;
};

fn baseName(ch: u21) ?[]const u8 {
    return switch (ch) {
        ' ' => "space",
        '-' => "minus",
        '=' => "equal",
        '[' => "bracket_left",
        ']' => "bracket_right",
        '\\' => "backslash",
        ';' => "semicolon",
        '\'' => "quote",
        '`' => "backquote",
        ',' => "comma",
        '.' => "period",
        '/' => "slash",
        else => null,
    };
}

fn shiftedName(ch: u21) ?struct { []const u8, u21 } {
    return switch (ch) {
        '!' => .{ "digit_1", '1' },
        '@' => .{ "digit_2", '2' },
        '#' => .{ "digit_3", '3' },
        '$' => .{ "digit_4", '4' },
        '%' => .{ "digit_5", '5' },
        '^' => .{ "digit_6", '6' },
        '&' => .{ "digit_7", '7' },
        '*' => .{ "digit_8", '8' },
        '(' => .{ "digit_9", '9' },
        ')' => .{ "digit_0", '0' },
        '_' => .{ "minus", '-' },
        '+' => .{ "equal", '=' },
        '{' => .{ "bracket_left", '[' },
        '}' => .{ "bracket_right", ']' },
        '|' => .{ "backslash", '\\' },
        ':' => .{ "semicolon", ';' },
        '"' => .{ "quote", '\'' },
        '~' => .{ "backquote", '`' },
        '<' => .{ "comma", ',' },
        '>' => .{ "period", '.' },
        '?' => .{ "slash", '/' },
        else => null,
    };
}

test "keys serialize the way Rex expects" {
    const gpa = std.testing.allocator;
    const a = try std.json.Stringify.valueAlloc(gpa, forChar('A', 0), .{});
    defer gpa.free(a);
    try std.testing.expectEqualStrings(
        \\{"key":"key_a","mods":"shift","consumed_mods":"shift","text":"A","unshifted_codepoint":97,"composing":false,"action":"press"}
    , a);
    const cc = fromGdk('c', 'c', ctrl).?;
    try std.testing.expectEqualStrings("key_c", cc.name);
    try std.testing.expectEqualStrings("", cc.text());
    try std.testing.expectEqualStrings("ctrl", modsString(cc.mods));
    const enter = fromGdk(0xff0d, 0, 0).?;
    try std.testing.expectEqualStrings("\r", enter.text());
    try std.testing.expectEqualStrings("shift+ctrl+alt", modsString(shift | ctrl | alt));
    try std.testing.expectEqualStrings("digit_1", forChar('!', 0).name);
}

/// A key press written the way Rex's config writes keys: "shift+right", "l", "=", "enter".
pub fn rexName(buf: []u8, keyval: u32, unicode: u32, mods_in: u4) ?[]const u8 {
    var mods = mods_in;
    const base: []const u8 = switch (keyval) {
        0xff0d, 0xff8d => "enter",
        0xff1b => "escape",
        0xff09, 0xfe20 => "tab",
        0xff08 => "backspace",
        0xff51 => "left",
        0xff52 => "up",
        0xff53 => "right",
        0xff54 => "down",
        0xff50 => "home",
        0xff57 => "end",
        0xff55 => "page_up",
        0xff56 => "page_down",
        ' ' => "space",
        else => blk: {
            if (unicode == 0 or unicode > 0x7e) return null;
            var ch: u8 = @intCast(unicode);
            if (ch >= 'A' and ch <= 'Z') {
                ch += 32;
                mods |= shift;
            }
            buf[buf.len - 1] = ch;
            break :blk buf[buf.len - 1 ..];
        },
    };
    const prefix = modsString(mods);
    if (prefix.len == 0) return base;
    var tmp: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&tmp, "{s}+{s}", .{ prefix, base }) catch return null;
    @memcpy(buf[0..out.len], out);
    return buf[0..out.len];
}

test "keys as Rex config names them" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("shift+right", rexName(&buf, 0xff53, 0, shift).?);
    try std.testing.expectEqualStrings("shift+l", rexName(&buf, 'L', 'L', shift).?);
    try std.testing.expectEqualStrings("=", rexName(&buf, '=', '=', 0).?);
    try std.testing.expectEqualStrings("enter", rexName(&buf, 0xff0d, 0, 0).?);
}
