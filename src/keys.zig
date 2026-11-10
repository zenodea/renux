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
    return modsFromGdkOn(state, @import("builtin").os.tag == .macos);
}

/// Command on a Mac arrives as Meta, so there it counts as Super. Elsewhere Meta often rides on
/// the Alt key (X11's Mod1), and counting it would turn every Alt combination into alt+super.
pub fn modsFromGdkOn(state: u32, mac: bool) u4 {
    var m: u4 = 0;
    if (state & (1 << 0) != 0) m |= shift;
    if (state & (1 << 2) != 0) m |= ctrl;
    if (state & (1 << 3) != 0) m |= alt;
    if (state & (1 << 26) != 0) m |= super;
    if (mac and state & (1 << 28) != 0) m |= super;
    return m;
}

/// With Caps Lock on, Ctrl+A arrives as a capital A without Shift held. A capital in a Control,
/// Alt or Super combination only means Shift when Shift is down, so it goes back to the letter.
pub fn uncapsed(keyval: u32, mods: u4) u32 {
    if (mods & (ctrl | alt | super) != 0 and mods & shift == 0 and keyval >= 'A' and keyval <= 'Z') return keyval + 32;
    return keyval;
}

/// One symbol a hardware key makes: in which layout (group) and at which shift level.
pub const Level = struct { group: i32, level: i32, keyval: u32 };

/// Whether a Control, Alt or Super combination needs the key's Latin symbol: the layout gave a
/// character outside ASCII, such as Cyrillic or Greek, which no binding or program expects.
pub fn needsLatin(keyval: u32, unicode: u32, mods: u4) bool {
    if (mods & (ctrl | alt | super) == 0 or isModifier(keyval) or def(keyval) != null) return false;
    return unicode == 0 or unicode > 0x7e;
}

/// The ASCII symbol a hardware key makes in the first layout that has one, so Ctrl+C works on
/// a Russian layout. `entries` are all the symbols of that key, from gdk_display_map_keycode.
pub fn latinKeyval(entries: []const Level, shifted: bool) ?u32 {
    var best: ?Level = null;
    for (entries) |e| {
        if (e.level != 0 or e.keyval < 0x20 or e.keyval > 0x7e) continue;
        if (best == null or e.group < best.?.group) best = e;
    }
    const base = best orelse return null;
    if (!shifted) return base.keyval;
    for (entries) |e| if (e.group == base.group and e.level == 1 and e.keyval >= 0x20 and e.keyval <= 0x7e) return e.keyval;
    return if (base.keyval >= 'a' and base.keyval <= 'z') base.keyval - 32 else base.keyval;
}

/// A key with a name rather than a character: its GDK keyval, what Rex's client.key calls it,
/// what Rex's config calls it in a binding, and the text it types on its own.
const Def = struct { keyval: u32, api: []const u8, config: []const u8, text: []const u8 = "" };

/// Every named key, in one place: sending keys, matching bindings and reading binding names all
/// go through this table. Keypad keys without Num Lock count as the keys they are labelled with.
const defs = [_]Def{
    .{ .keyval = 0xff0d, .api = "enter", .config = "enter", .text = "\r" },
    .{ .keyval = 0xff8d, .api = "numpad_enter", .config = "enter", .text = "\r" },
    .{ .keyval = 0xff09, .api = "tab", .config = "tab", .text = "\t" },
    .{ .keyval = 0xfe20, .api = "tab", .config = "tab" }, // ISO_Left_Tab, what Shift+Tab sends
    .{ .keyval = 0xff08, .api = "backspace", .config = "backspace" },
    .{ .keyval = 0xff1b, .api = "escape", .config = "escape" },
    .{ .keyval = 0xff52, .api = "arrow_up", .config = "up" },
    .{ .keyval = 0xff54, .api = "arrow_down", .config = "down" },
    .{ .keyval = 0xff51, .api = "arrow_left", .config = "left" },
    .{ .keyval = 0xff53, .api = "arrow_right", .config = "right" },
    .{ .keyval = 0xff50, .api = "home", .config = "home" },
    .{ .keyval = 0xff57, .api = "end", .config = "end" },
    .{ .keyval = 0xff55, .api = "page_up", .config = "page_up" },
    .{ .keyval = 0xff56, .api = "page_down", .config = "page_down" },
    .{ .keyval = 0xff63, .api = "insert", .config = "insert" },
    .{ .keyval = 0xffff, .api = "delete", .config = "delete" },
    .{ .keyval = 0xff97, .api = "arrow_up", .config = "up" }, // KP_Up and the rest of the keypad
    .{ .keyval = 0xff99, .api = "arrow_down", .config = "down" },
    .{ .keyval = 0xff96, .api = "arrow_left", .config = "left" },
    .{ .keyval = 0xff98, .api = "arrow_right", .config = "right" },
    .{ .keyval = 0xff95, .api = "home", .config = "home" },
    .{ .keyval = 0xff9c, .api = "end", .config = "end" },
    .{ .keyval = 0xff9a, .api = "page_up", .config = "page_up" },
    .{ .keyval = 0xff9b, .api = "page_down", .config = "page_down" },
    .{ .keyval = 0xff9e, .api = "insert", .config = "insert" },
    .{ .keyval = 0xff9f, .api = "delete", .config = "delete" },
} ++ f_defs;

const f_defs = blk: {
    var t: [12]Def = undefined;
    for (0..12) |i| {
        const name = std.fmt.comptimePrint("f{d}", .{i + 1});
        t[i] = .{ .keyval = 0xffbe + i, .api = name, .config = name };
    }
    break :blk t;
};

fn def(keyval: u32) ?*const Def {
    for (&defs) |*d| if (d.keyval == keyval) return d;
    return null;
}

/// Keys that on their own change nothing, such as Shift.
pub fn isModifier(keyval: u32) bool {
    return (keyval >= 0xffe1 and keyval <= 0xffee) or keyval == 0xfe03; // Shift_L..Hyper_R, ISO_Level3_Shift
}

/// The key for a GDK key press, or null for keys Rex has no name for.
/// `unicode` is gdk_keyval_to_unicode(keyval), or 0.
pub fn fromGdk(keyval: u32, unicode: u32, mods: u4) ?Key {
    if (def(keyval)) |d| {
        var k: Key = .{ .name = d.api, .mods = mods };
        if (keyval == 0xfe20) k.mods |= shift;
        // Control and Alt combinations type nothing themselves; the server encodes them.
        if (mods & (ctrl | alt | super) == 0) setText(&k, d.text);
        return k;
    }
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
    const base: []const u8 = if (def(keyval)) |d| d.config else if (keyval == ' ') "space" else blk: {
        if (unicode == 0 or unicode > 0x7e) return null;
        var ch: u8 = @intCast(unicode);
        if (ch >= 'A' and ch <= 'Z') {
            ch += 32;
            mods |= shift;
        }
        buf[buf.len - 1] = ch;
        break :blk buf[buf.len - 1 ..];
    };
    const prefix = modsString(mods);
    if (prefix.len == 0) return base;
    var tmp: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&tmp, "{s}+{s}", .{ prefix, base }) catch return null;
    @memcpy(buf[0..out.len], out);
    return buf[0..out.len];
}

/// A key as Rex names it, taken apart: its modifiers and the key itself, with shifted symbols
/// and capitals written as shift and the plain key, the way a US keyboard makes them.
pub const Name = struct {
    mods: u4,
    base_buf: [16]u8 = undefined,
    base_len: usize = 0,

    pub fn base(n: *const Name) []const u8 {
        return n.base_buf[0..n.base_len];
    }
};

pub const us_shifted = "!@#$%^&*()_+{}|:\"<>?~";
pub const us_unshifted = "1234567890-=[]\\;',./`";

pub fn parseName(name: []const u8) ?Name {
    var n: Name = .{ .mods = 0 };
    var rest = name;
    while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        // A trailing "+" is the plus key itself.
        if (i == rest.len - 1 and i > 0 and rest[i - 1] == '+') break;
        if (i == 0) break;
        const m = rest[0..i];
        if (std.mem.eql(u8, m, "shift")) n.mods |= shift else if (std.mem.eql(u8, m, "ctrl") or std.mem.eql(u8, m, "control")) n.mods |= ctrl else if (std.mem.eql(u8, m, "alt") or std.mem.eql(u8, m, "option")) n.mods |= alt else if (std.mem.eql(u8, m, "super") or std.mem.eql(u8, m, "cmd") or std.mem.eql(u8, m, "command")) n.mods |= super else return null;
        rest = rest[i + 1 ..];
    }
    if (rest.len == 0 or rest.len > n.base_buf.len) return null;
    var b = rest;
    if (b.len == 1) {
        var ch = b[0];
        if (ch >= 'A' and ch <= 'Z') {
            ch += 32;
            n.mods |= shift;
        } else if (std.mem.indexOfScalar(u8, us_shifted, ch)) |k| {
            ch = us_unshifted[k];
            n.mods |= shift;
        }
        n.base_buf[0] = ch;
        n.base_len = 1;
        return n;
    }
    if (std.mem.eql(u8, b, "return")) b = "enter";
    if (std.mem.eql(u8, b, "esc")) b = "escape";
    for (b, 0..) |ch, i| n.base_buf[i] = std.ascii.toLower(ch);
    n.base_len = b.len;
    return n;
}

/// Whether two Rex key names mean the same key, such as "ctrl+shift+n" and "shift+ctrl+N".
pub fn sameKey(a: []const u8, b: []const u8) bool {
    const x = parseName(a) orelse return false;
    const y = parseName(b) orelse return false;
    return x.mods == y.mods and std.mem.eql(u8, x.base(), y.base());
}

/// The key a Rex name such as "ctrl+a" or "shift+left" stands for, as if it were typed.
pub fn fromName(name: []const u8) ?Key {
    const n = parseName(name) orelse return null;
    const b = n.base();
    if (std.mem.eql(u8, b, "space")) return fromGdk(' ', ' ', n.mods);
    for (&defs) |*d| if (std.mem.eql(u8, d.config, b)) return fromGdk(d.keyval, 0, n.mods);
    if (b.len != 1) return null;
    var ch: u32 = b[0];
    if (n.mods & shift != 0) {
        if (ch >= 'a' and ch <= 'z') ch -= 32 else if (std.mem.indexOfScalar(u8, us_unshifted, b[0])) |k| ch = us_shifted[k];
    }
    return fromGdk(ch, ch, n.mods);
}

test "Rex key names compare by meaning" {
    try std.testing.expect(sameKey("ctrl+shift+n", "shift+ctrl+n"));
    try std.testing.expect(sameKey("shift+-", "shift+_"));
    try std.testing.expect(sameKey("shift+7", "&"));
    try std.testing.expect(sameKey("shift+n", "N"));
    try std.testing.expect(!sameKey("ctrl+a", "a"));
    try std.testing.expect(sameKey("ctrl++", "ctrl+shift+="));
}

test "keys as Rex config names them" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("shift+right", rexName(&buf, 0xff53, 0, shift).?);
    try std.testing.expectEqualStrings("shift+l", rexName(&buf, 'L', 'L', shift).?);
    try std.testing.expectEqualStrings("=", rexName(&buf, '=', '=', 0).?);
    try std.testing.expectEqualStrings("enter", rexName(&buf, 0xff0d, 0, 0).?);
}

test "typed characters match bindings written with shift" {
    var buf: [40]u8 = undefined;
    const underscore = rexName(&buf, '_', '_', 0).?;
    try std.testing.expect(sameKey("shift+-", underscore));
    var buf2: [40]u8 = undefined;
    const capital = rexName(&buf2, 'N', 'N', 0).?;
    try std.testing.expect(sameKey("shift+n", capital));
    var buf3: [40]u8 = undefined;
    try std.testing.expect(sameKey("-", rexName(&buf3, '-', '-', 0).?));
}

test "function, editing and keypad keys have names for bindings and for sending" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("f5", rexName(&buf, 0xffc2, 0, 0).?);
    try std.testing.expectEqualStrings("ctrl+delete", rexName(&buf, 0xffff, 0, ctrl).?);
    try std.testing.expectEqualStrings("shift+insert", rexName(&buf, 0xff63, 0, shift).?);
    try std.testing.expectEqualStrings("up", rexName(&buf, 0xff97, 0, 0).?);
    try std.testing.expectEqualStrings("f12", fromGdk(0xffc9, 0, 0).?.name);
    try std.testing.expectEqualStrings("arrow_left", fromGdk(0xff96, 0, 0).?.name);
    try std.testing.expectEqualStrings("delete", fromGdk(0xff9f, 0, 0).?.name);
    try std.testing.expectEqualStrings("f5", fromName("f5").?.name);
    try std.testing.expectEqualStrings("delete", fromName("ctrl+delete").?.name);
    try std.testing.expectEqualStrings("arrow_up", fromName("shift+up").?.name);
    try std.testing.expectEqualStrings("space", fromName("space").?.name);
    var buf2: [40]u8 = undefined;
    try std.testing.expect(sameKey("F5", rexName(&buf2, 0xffc2, 0, 0).?));
}

test "Meta counts as Super only on a Mac" {
    const meta = 1 << 28;
    const mod1 = 1 << 3;
    try std.testing.expectEqual(@as(u4, alt), modsFromGdkOn(mod1 | meta, false));
    try std.testing.expectEqual(@as(u4, super), modsFromGdkOn(meta, true));
    try std.testing.expectEqual(@as(u4, super | ctrl), modsFromGdkOn((1 << 26) | (1 << 2), false));
}

test "Caps Lock doesn't turn Ctrl+A into Ctrl+Shift+A" {
    var buf: [40]u8 = undefined;
    const kv = uncapsed('A', ctrl);
    try std.testing.expectEqual(@as(u32, 'a'), kv);
    try std.testing.expectEqualStrings("ctrl+a", rexName(&buf, kv, kv, ctrl).?);
    const c = fromGdk(uncapsed('C', ctrl), 'c', ctrl).?;
    try std.testing.expectEqualStrings("key_c", c.name);
    try std.testing.expectEqualStrings("ctrl", modsString(c.mods));
    // Shift held, or no Control at all, leaves the capital alone.
    try std.testing.expectEqual(@as(u32, 'A'), uncapsed('A', ctrl | shift));
    try std.testing.expectEqual(@as(u32, 'A'), uncapsed('A', 0));
}

test "Control combinations on a layout without Latin letters use the key's Latin symbol" {
    // The C key with Russian first and US second.
    const key_c = [_]Level{
        .{ .group = 0, .level = 0, .keyval = 0x6d3 },
        .{ .group = 0, .level = 1, .keyval = 0x6f3 },
        .{ .group = 1, .level = 0, .keyval = 'c' },
        .{ .group = 1, .level = 1, .keyval = 'C' },
    };
    try std.testing.expect(needsLatin(0x6d3, 0x441, ctrl));
    try std.testing.expect(!needsLatin(0x6d3, 0x441, 0));
    try std.testing.expect(!needsLatin('c', 'c', ctrl));
    try std.testing.expect(!needsLatin(0xff0d, 0, ctrl));
    try std.testing.expectEqual(@as(?u32, 'c'), latinKeyval(&key_c, false));
    try std.testing.expectEqual(@as(?u32, 'C'), latinKeyval(&key_c, true));
    // A digit key: Shift picks the symbol above it.
    const key_2 = [_]Level{ .{ .group = 0, .level = 0, .keyval = '2' }, .{ .group = 0, .level = 1, .keyval = '@' } };
    try std.testing.expectEqual(@as(?u32, '@'), latinKeyval(&key_2, true));
    // A layout with no Latin group at all has nothing to offer.
    try std.testing.expectEqual(@as(?u32, null), latinKeyval(key_c[0..2], false));
    var buf: [40]u8 = undefined;
    const kv = latinKeyval(&key_c, false).?;
    try std.testing.expectEqualStrings("ctrl+c", rexName(&buf, kv, kv, ctrl).?);
}
