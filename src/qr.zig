//! A small QR Code encoder: byte mode, error correction level M, versions 1 to 10.
//! It only builds the grid of dark and light modules; drawing is up to the caller.
const std = @import("std");

/// Version 10 is the largest supported, and it is 57 modules wide.
pub const max_size = 57;

/// A finished QR code. Only the top-left `size` x `size` corner of `modules` is used,
/// indexed as `modules[row][column]`, with true meaning a dark module.
pub const Code = struct { size: u8, modules: [max_size][max_size]bool };

const max_version = 10;
const max_codewords = 346; // total codewords at version 10
const max_blocks = 5;
const max_ec = 26;

/// How level M splits a version's codewords into blocks. The first `short_blocks`
/// blocks hold `short_data` data codewords each, the rest hold one more.
const Layout = struct { ec_per_block: u8, short_blocks: u8, short_data: u8, long_blocks: u8 };

const layouts_m = [max_version]Layout{
    .{ .ec_per_block = 10, .short_blocks = 1, .short_data = 16, .long_blocks = 0 }, // 1
    .{ .ec_per_block = 16, .short_blocks = 1, .short_data = 28, .long_blocks = 0 }, // 2
    .{ .ec_per_block = 26, .short_blocks = 1, .short_data = 44, .long_blocks = 0 }, // 3
    .{ .ec_per_block = 18, .short_blocks = 2, .short_data = 32, .long_blocks = 0 }, // 4
    .{ .ec_per_block = 24, .short_blocks = 2, .short_data = 43, .long_blocks = 0 }, // 5
    .{ .ec_per_block = 16, .short_blocks = 4, .short_data = 27, .long_blocks = 0 }, // 6
    .{ .ec_per_block = 18, .short_blocks = 4, .short_data = 31, .long_blocks = 0 }, // 7
    .{ .ec_per_block = 22, .short_blocks = 2, .short_data = 38, .long_blocks = 2 }, // 8
    .{ .ec_per_block = 22, .short_blocks = 3, .short_data = 36, .long_blocks = 2 }, // 9
    .{ .ec_per_block = 26, .short_blocks = 4, .short_data = 43, .long_blocks = 1 }, // 10
};

/// Centers of the alignment patterns along each axis, per version.
const alignment_centers = [max_version][]const u8{
    &.{},
    &.{ 6, 18 },
    &.{ 6, 22 },
    &.{ 6, 26 },
    &.{ 6, 30 },
    &.{ 6, 34 },
    &.{ 6, 22, 38 },
    &.{ 6, 24, 42 },
    &.{ 6, 26, 46 },
    &.{ 6, 28, 50 },
};

fn layout(version: u8) Layout {
    return layouts_m[version - 1];
}

fn blockCount(l: Layout) usize {
    return @as(usize, l.short_blocks) + l.long_blocks;
}

fn blockDataLen(l: Layout, block: usize) usize {
    return @as(usize, l.short_data) + @intFromBool(block >= l.short_blocks);
}

fn dataCodewords(version: u8) usize {
    const l = layout(version);
    return @as(usize, l.short_blocks) * l.short_data + @as(usize, l.long_blocks) * (@as(usize, l.short_data) + 1);
}

fn totalCodewords(version: u8) usize {
    const l = layout(version);
    return dataCodewords(version) + blockCount(l) * l.ec_per_block;
}

fn sizeOf(version: u8) u8 {
    return version * 4 + 17;
}

fn countBits(version: u8) u5 {
    return if (version < 10) 8 else 16;
}

/// Encodes bytes in byte mode with error correction level M, picking the smallest
/// version 1..10 that fits. Returns null if it doesn't fit.
pub fn encode(data: []const u8) ?Code {
    var version: u8 = 1;
    while (version <= max_version) : (version += 1) {
        if (4 + @as(usize, countBits(version)) + data.len * 8 <= dataCodewords(version) * 8) break;
    } else return null;

    var codewords: [max_codewords]u8 = undefined;
    const total = buildCodewords(data, version, &codewords);

    var m = Matrix.init(version);
    m.placeCodewords(codewords[0..total]);

    var best_mask: u3 = 0;
    var best_penalty: u32 = std.math.maxInt(u32);
    for (0..8) |i| {
        const mask: u3 = @intCast(i);
        m.applyMask(mask);
        m.drawFormat(mask);
        const p = m.penalty();
        if (p < best_penalty) {
            best_penalty = p;
            best_mask = mask;
        }
        m.applyMask(mask); // masking twice undoes it
    }
    m.applyMask(best_mask);
    m.drawFormat(best_mask);
    return .{ .size = m.size, .modules = m.modules };
}

/// Writes the data bits, padding, error correction and interleaving for `version`.
/// Returns the number of codewords written.
fn buildCodewords(data: []const u8, version: u8, out: *[max_codewords]u8) usize {
    const l = layout(version);
    const data_len = dataCodewords(version);

    var buf: [max_codewords]u8 = @splat(0);
    var w = BitWriter{ .buf = &buf };
    w.put(0b0100, 4);
    w.put(@intCast(data.len), countBits(version));
    for (data) |b| w.put(b, 8);
    const capacity = data_len * 8;
    w.put(0, @intCast(@min(4, capacity - w.len)));
    w.len = (w.len + 7) / 8 * 8;
    var pad: u8 = 0xEC;
    while (w.len < capacity) : (pad ^= 0xEC ^ 0x11) w.put(pad, 8);

    var divisor: [max_ec]u8 = undefined;
    rsDivisor(l.ec_per_block, &divisor);

    var ec: [max_blocks][max_ec]u8 = undefined;
    var starts: [max_blocks]usize = undefined;
    const blocks = blockCount(l);
    var start: usize = 0;
    for (0..blocks) |b| {
        starts[b] = start;
        const len = blockDataLen(l, b);
        rsRemainder(buf[start..][0..len], divisor[0..l.ec_per_block], ec[b][0..l.ec_per_block]);
        start += len;
    }

    var n: usize = 0;
    for (0..@as(usize, l.short_data) + 1) |i| {
        for (0..blocks) |b| {
            if (i < blockDataLen(l, b)) {
                out[n] = buf[starts[b] + i];
                n += 1;
            }
        }
    }
    for (0..l.ec_per_block) |i| {
        for (0..blocks) |b| {
            out[n] = ec[b][i];
            n += 1;
        }
    }
    return n;
}

const BitWriter = struct {
    buf: *[max_codewords]u8,
    len: usize = 0,

    fn put(w: *BitWriter, value: u16, bits: u5) void {
        var i: u5 = bits;
        while (i > 0) {
            i -= 1;
            if ((value >> @intCast(i)) & 1 != 0) w.buf[w.len / 8] |= @as(u8, 0x80) >> @intCast(w.len % 8);
            w.len += 1;
        }
    }
};

/// Multiplies in GF(256) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1.
fn gfMul(a: u8, b: u8) u8 {
    var x: u16 = a;
    var y: u8 = b;
    var r: u8 = 0;
    while (y != 0) : (y >>= 1) {
        if (y & 1 != 0) r ^= @truncate(x);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    return r;
}

/// The Reed-Solomon generator polynomial of the given degree, highest term dropped,
/// coefficients from the highest remaining power down.
fn rsDivisor(degree: usize, out: *[max_ec]u8) void {
    const d = out[0..degree];
    @memset(d, 0);
    d[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            d[j] = gfMul(d[j], root);
            if (j + 1 < degree) d[j] ^= d[j + 1];
        }
        root = gfMul(root, 2);
    }
}

/// The error correction codewords for one block of data.
fn rsRemainder(data: []const u8, divisor: []const u8, out: []u8) void {
    @memset(out, 0);
    for (data) |b| {
        const factor = b ^ out[0];
        std.mem.copyForwards(u8, out[0 .. out.len - 1], out[1..]);
        out[out.len - 1] = 0;
        for (out, divisor) |*o, c| o.* ^= gfMul(c, factor);
    }
}

/// BCH code for 15-bit format info: 2 bits of level, 3 of mask, 10 of check, then XOR 0x5412.
fn formatBits(mask: u3) u15 {
    const data: u32 = (0b00 << 3) | @as(u32, mask); // level M is 00
    var rem = data;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return @intCast(((data << 10) | rem) ^ 0x5412);
}

/// BCH code for 18-bit version info, used from version 7.
fn versionBits(version: u8) u18 {
    var rem: u32 = version;
    for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return @intCast((@as(u32, version) << 12) | rem);
}

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => x * y % 2 + x * y % 3 == 0,
        6 => (x * y % 2 + x * y % 3) % 2 == 0,
        7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };
}

/// The grid while it's being built, with a note of which modules are fixed patterns.
const Matrix = struct {
    size: u8,
    version: u8,
    modules: [max_size][max_size]bool = std.mem.zeroes([max_size][max_size]bool),
    function: [max_size][max_size]bool = std.mem.zeroes([max_size][max_size]bool),

    /// A grid with every fixed pattern drawn and the format area reserved.
    fn init(version: u8) Matrix {
        var m = Matrix{ .size = sizeOf(version), .version = version };
        const s: usize = m.size;
        for (0..s) |i| {
            m.set(6, i, i % 2 == 0);
            m.set(i, 6, i % 2 == 0);
        }
        m.drawFinder(3, 3);
        m.drawFinder(s - 4, 3);
        m.drawFinder(3, s - 4);

        const centers = alignment_centers[version - 1];
        for (centers, 0..) |cx, i| {
            for (centers, 0..) |cy, j| {
                const last = centers.len - 1;
                if ((i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0)) continue;
                for (0..5) |dy| for (0..5) |dx| {
                    const dist = @max(absDiff(dx, 2), absDiff(dy, 2));
                    m.set(cx - 2 + dx, cy - 2 + dy, dist != 1);
                };
            }
        }

        m.drawFormat(0);
        if (version >= 7) {
            const bits = versionBits(version);
            for (0..18) |i| {
                const bit = (bits >> @intCast(i)) & 1 != 0;
                const a = s - 11 + i % 3;
                const b = i / 3;
                m.set(a, b, bit);
                m.set(b, a, bit);
            }
        }
        return m;
    }

    fn set(m: *Matrix, x: usize, y: usize, dark: bool) void {
        m.modules[y][x] = dark;
        m.function[y][x] = true;
    }

    /// A finder pattern centered at (cx, cy), with its light separator clipped to the grid.
    fn drawFinder(m: *Matrix, cx: usize, cy: usize) void {
        for (0..9) |dy| for (0..9) |dx| {
            const x = @as(isize, @intCast(cx + dx)) - 4;
            const y = @as(isize, @intCast(cy + dy)) - 4;
            if (x < 0 or y < 0 or x >= m.size or y >= m.size) continue;
            const dist = @max(absDiff(dx, 4), absDiff(dy, 4));
            m.set(@intCast(x), @intCast(y), dist != 2 and dist != 4);
        };
    }

    /// Both copies of the format info, plus the dark module.
    fn drawFormat(m: *Matrix, mask: u3) void {
        const bits = formatBits(mask);
        const s: usize = m.size;
        for (format_positions, 0..) |p, i| {
            const bit = (bits >> @intCast(i)) & 1 != 0;
            m.set(p[0], p[1], bit);
            const q = formatPosition2(s, i);
            m.set(q[0], q[1], bit);
        }
        m.set(8, s - 8, true);
    }

    /// Fills the non-fixed modules in the zigzag order, two columns at a time from the right.
    fn placeCodewords(m: *Matrix, codewords: []const u8) void {
        var i: usize = 0;
        var it = ZigZag.init(m);
        while (it.next()) |p| {
            if (i < codewords.len * 8) {
                m.modules[p[1]][p[0]] = (codewords[i / 8] >> @intCast(7 - i % 8)) & 1 != 0;
                i += 1;
            }
        }
    }

    fn applyMask(m: *Matrix, mask: u3) void {
        for (0..m.size) |y| for (0..m.size) |x| {
            if (!m.function[y][x] and maskBit(mask, x, y)) m.modules[y][x] = !m.modules[y][x];
        };
    }

    /// The standard mask penalty: long runs, 2x2 blocks, finder-like patterns, dark balance.
    fn penalty(m: *const Matrix) u32 {
        const s: usize = m.size;
        var total: u32 = 0;
        for (0..2) |dir| {
            for (0..s) |a| {
                var line: [max_size]bool = undefined;
                for (0..s) |b| line[b] = if (dir == 0) m.modules[a][b] else m.modules[b][a];
                total += linePenalty(line[0..s]);
            }
        }
        var dark: u32 = 0;
        for (0..s) |y| for (0..s) |x| {
            if (m.modules[y][x]) dark += 1;
            if (x + 1 < s and y + 1 < s) {
                const c = m.modules[y][x];
                if (m.modules[y][x + 1] == c and m.modules[y + 1][x] == c and m.modules[y + 1][x + 1] == c) total += 3;
            }
        };
        const cells: u32 = @intCast(s * s);
        // Ten points for each full 5% step away from half dark.
        const diff = @max(dark * 20, cells * 10) - @min(dark * 20, cells * 10);
        total += diff / cells * 10;
        return total;
    }
};

/// Runs of five or more (N1) and the 1:1:3:1:1 finder look-alike with four light modules
/// on one side (N3), for one row or column. Modules past the edge count as light.
fn linePenalty(line: []const bool) u32 {
    var total: u32 = 0;
    var run: usize = 1;
    for (1..line.len + 1) |i| {
        if (i < line.len and line[i] == line[i - 1]) {
            run += 1;
        } else {
            if (run >= 5) total += @intCast(3 + run - 5);
            run = 1;
        }
    }
    const finder = [7]bool{ true, false, true, true, true, false, true };
    const n: isize = @intCast(line.len);
    var k: isize = -4;
    while (k + 10 < n + 4) : (k += 1) {
        // Finder at k, light after it; or light at k, finder after it.
        inline for (.{ 0, 4 }) |off| {
            var ok = true;
            for (0..11) |j| {
                const pos = k + @as(isize, @intCast(j));
                const want = if (j >= off and j < off + 7) finder[j - off] else false;
                const have = pos >= 0 and pos < n and line[@intCast(pos)];
                if (have != want) {
                    ok = false;
                    break;
                }
            }
            if (ok) total += 40;
        }
    }
    return total;
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

/// Where format bit i (0 is least significant) sits beside the top-left finder, as (x, y).
const format_positions = blk: {
    var p: [15][2]u8 = undefined;
    for (0..6) |i| p[i] = .{ 8, i };
    p[6] = .{ 8, 7 };
    p[7] = .{ 8, 8 };
    p[8] = .{ 7, 8 };
    for (9..15) |i| p[i] = .{ 14 - i, 8 };
    break :blk p;
};

/// Where the second copy of format bit i sits, split between the other two finders.
fn formatPosition2(size: usize, i: usize) [2]usize {
    return if (i < 8) .{ size - 1 - i, 8 } else .{ 8, size - 15 + i };
}

/// Walks the non-fixed modules in placement order.
const ZigZag = struct {
    m: *const Matrix,
    right: isize,
    vert: usize = 0,
    j: usize = 0,

    fn init(m: *const Matrix) ZigZag {
        return .{ .m = m, .right = @as(isize, m.size) - 1 };
    }

    fn next(z: *ZigZag) ?[2]usize {
        const s: usize = z.m.size;
        while (z.right >= 1) {
            if (z.right == 6) z.right = 5;
            while (z.vert < s) {
                while (z.j < 2) {
                    const x: usize = @as(usize, @intCast(z.right)) - z.j;
                    z.j += 1;
                    const upward = (@as(usize, @intCast(z.right)) + 1) & 2 == 0;
                    const y = if (upward) s - 1 - z.vert else z.vert;
                    if (!z.m.function[y][x]) return .{ x, y };
                }
                z.j = 0;
                z.vert += 1;
            }
            z.vert = 0;
            z.right -= 2;
        }
        return null;
    }
};

// ---- Tests ----

const testing = std.testing;

fn expectFinder(code: *const Code, x0: usize, y0: usize) !void {
    for (0..7) |dy| for (0..7) |dx| {
        const dist = @max(absDiff(dx, 3), absDiff(dy, 3));
        try testing.expectEqual(dist != 2, code.modules[y0 + dy][x0 + dx]);
    };
}

/// Reads the format info back out of a code and checks both copies and the BCH code.
/// Returns the mask.
fn decodeFormat(code: *const Code) !u3 {
    const s: usize = code.size;
    var first: u15 = 0;
    var second: u15 = 0;
    for (format_positions, 0..) |p, i| {
        if (code.modules[p[1]][p[0]]) first |= @as(u15, 1) << @intCast(i);
        const q = formatPosition2(s, i);
        if (code.modules[q[1]][q[0]]) second |= @as(u15, 1) << @intCast(i);
    }
    try testing.expectEqual(first, second);
    const raw: u32 = first ^ 0x5412;
    // A valid BCH codeword divides evenly by the generator.
    var rem = raw;
    var bit: u5 = 14;
    while (bit >= 10) : (bit -= 1) {
        if ((rem >> bit) & 1 != 0) rem ^= @as(u32, 0x537) << (bit - 10);
    }
    try testing.expectEqual(@as(u32, 0), rem);
    try testing.expectEqual(@as(u32, 0b00), raw >> 13); // level M
    try testing.expect(code.modules[s - 8][8]); // dark module
    return @intCast((raw >> 10) & 7);
}

/// Decodes a code back to its bytes: format, unmask, zigzag read, de-interleave,
/// check every block's error correction, then parse the byte-mode segment.
fn decode(code: *const Code, out: []u8) ![]u8 {
    const mask = try decodeFormat(code);
    const version: u8 = (code.size - 17) / 4;
    var m = Matrix.init(version);
    m.modules = code.modules;
    m.applyMask(mask);

    const total = totalCodewords(version);
    var raw: [max_codewords]u8 = @splat(0);
    var i: usize = 0;
    var it = ZigZag.init(&m);
    while (it.next()) |p| : (i += 1) {
        if (i < total * 8 and m.modules[p[1]][p[0]]) raw[i / 8] |= @as(u8, 0x80) >> @intCast(i % 8);
    }
    try testing.expect(i >= total * 8);

    const l = layout(version);
    const blocks = blockCount(l);
    var block_data: [max_blocks][max_codewords]u8 = undefined;
    var block_ec: [max_blocks][max_ec]u8 = undefined;
    var n: usize = 0;
    for (0..@as(usize, l.short_data) + 1) |k| for (0..blocks) |b| {
        if (k < blockDataLen(l, b)) {
            block_data[b][k] = raw[n];
            n += 1;
        }
    };
    for (0..l.ec_per_block) |k| for (0..blocks) |b| {
        block_ec[b][k] = raw[n];
        n += 1;
    };
    try testing.expectEqual(total, n);

    var divisor: [max_ec]u8 = undefined;
    rsDivisor(l.ec_per_block, &divisor);
    var data: [max_codewords]u8 = @splat(0);
    var d: usize = 0;
    for (0..blocks) |b| {
        const len = blockDataLen(l, b);
        var ec: [max_ec]u8 = undefined;
        rsRemainder(block_data[b][0..len], divisor[0..l.ec_per_block], ec[0..l.ec_per_block]);
        try testing.expectEqualSlices(u8, ec[0..l.ec_per_block], block_ec[b][0..l.ec_per_block]);
        @memcpy(data[d..][0..len], block_data[b][0..len]);
        d += len;
    }

    var r = BitReader{ .buf = data[0..d] };
    try testing.expectEqual(@as(u16, 0b0100), r.get(4));
    const len = r.get(countBits(version));
    for (0..len) |k| out[k] = @intCast(r.get(8));
    return out[0..len];
}

const BitReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn get(r: *BitReader, bits: u5) u16 {
        var v: u16 = 0;
        for (0..bits) |_| {
            v = (v << 1) | ((r.buf[r.pos / 8] >> @intCast(7 - r.pos % 8)) & 1);
            r.pos += 1;
        }
        return v;
    }
};

test "short data makes a version 1 code with three finder patterns" {
    const code = encode("HELLO WORLD").?;
    try testing.expectEqual(@as(u8, 21), code.size);
    try expectFinder(&code, 0, 0);
    try expectFinder(&code, 14, 0);
    try expectFinder(&code, 0, 14);
    // Separators are light, timing patterns alternate.
    for (0..8) |i| {
        try testing.expect(!code.modules[7][i]);
        try testing.expect(!code.modules[i][7]);
    }
    for (8..13) |i| {
        try testing.expectEqual(i % 2 == 0, code.modules[6][i]);
        try testing.expectEqual(i % 2 == 0, code.modules[i][6]);
    }
}

test "a 100-byte https URL fits and decodes back" {
    const url = "https://my-mac.tail1234.ts.net/some/longer/path?with=query&and=more&padding=xxxxxxxxxxxxxxxxxxxxxxxx";
    try testing.expectEqual(@as(usize, 100), url.len);
    const code = encode(url).?;
    try testing.expect(code.size <= max_size);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(url, try decode(&code, &buf));
}

test "https://example.com round-trips through format info, mask and zigzag" {
    const input = "https://example.com";
    const code = encode(input).?;
    try testing.expectEqual(@as(u8, 25), code.size); // 19 bytes need version 2 at level M
    _ = try decodeFormat(&code);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(input, try decode(&code, &buf));
}

test "every length round-trips, and the version 10 limit is 213 bytes" {
    var input: [214]u8 = undefined;
    for (&input, 0..) |*c, i| c.* = @truncate(i * 37 + 11);
    var buf: [256]u8 = undefined;
    for (0..214) |len| {
        const code = encode(input[0..len]).?;
        try testing.expectEqualSlices(u8, input[0..len], try decode(&code, &buf));
    }
    try testing.expectEqual(@as(u8, 57), encode(input[0..213]).?.size);
    try testing.expect(encode(input[0..214]) == null);
}

test "tables agree with the module count of each version" {
    for (1..max_version + 1) |v| {
        const ver: u8 = @intCast(v);
        // Count the modules left for data by building the grid.
        const m = Matrix.init(ver);
        var free: usize = 0;
        for (0..m.size) |y| for (0..m.size) |x| {
            if (!m.function[y][x]) free += 1;
        };
        try testing.expectEqual(free / 8, totalCodewords(ver));
    }
}

test "Reed-Solomon matches the published HELLO WORLD 1-M example" {
    const data = [_]u8{ 32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17 };
    const want = [_]u8{ 196, 35, 39, 119, 235, 215, 231, 226, 93, 23 };
    var divisor: [max_ec]u8 = undefined;
    rsDivisor(10, &divisor);
    var ec: [10]u8 = undefined;
    rsRemainder(&data, divisor[0..10], &ec);
    try testing.expectEqualSlices(u8, &want, &ec);
}

test "format and version info match the published tables" {
    const want = [8]u15{
        0b101010000010010, 0b101000100100101, 0b101111001111100, 0b101101101001011,
        0b100010111111001, 0b100000011001110, 0b100111110010111, 0b100101010100000,
    };
    for (want, 0..) |w, i| try testing.expectEqual(w, formatBits(@intCast(i)));
    try testing.expectEqual(@as(u18, 0x07C94), versionBits(7));
    try testing.expectEqual(@as(u18, 0x085BC), versionBits(8));
    try testing.expectEqual(@as(u18, 0x09A99), versionBits(9));
    try testing.expectEqual(@as(u18, 0x0A4D3), versionBits(10));
}
