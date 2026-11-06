//! Draws box-drawing and block characters to fill the cell exactly. Font glyphs rarely match the
//! cell height, which would leave gaps in the borders that terminal programs draw.
const std = @import("std");
const cairo = @import("cairo");

const none = 0;
const light = 1;
const heavy = 2;
const double = 3;

/// Left, right, up and down strokes of a line character.
const Segs = [4]u2;

const table = blk: {
    var t: [0x80]?Segs = @splat(null);
    const L = light;
    const H = heavy;
    const D = double;
    const entries = [_]struct { u21, Segs }{
        .{ 0x2500, .{ L, L, 0, 0 } }, .{ 0x2501, .{ H, H, 0, 0 } }, .{ 0x2502, .{ 0, 0, L, L } }, .{ 0x2503, .{ 0, 0, H, H } },
        // Dashed lines are drawn solid.
        .{ 0x2504, .{ L, L, 0, 0 } }, .{ 0x2508, .{ L, L, 0, 0 } }, .{ 0x254C, .{ L, L, 0, 0 } },
        .{ 0x2505, .{ H, H, 0, 0 } }, .{ 0x2509, .{ H, H, 0, 0 } }, .{ 0x254D, .{ H, H, 0, 0 } },
        .{ 0x2506, .{ 0, 0, L, L } }, .{ 0x250A, .{ 0, 0, L, L } }, .{ 0x254E, .{ 0, 0, L, L } },
        .{ 0x2507, .{ 0, 0, H, H } }, .{ 0x250B, .{ 0, 0, H, H } }, .{ 0x254F, .{ 0, 0, H, H } },
        .{ 0x250C, .{ 0, L, 0, L } }, .{ 0x250D, .{ 0, H, 0, L } }, .{ 0x250E, .{ 0, L, 0, H } }, .{ 0x250F, .{ 0, H, 0, H } },
        .{ 0x2510, .{ L, 0, 0, L } }, .{ 0x2511, .{ H, 0, 0, L } }, .{ 0x2512, .{ L, 0, 0, H } }, .{ 0x2513, .{ H, 0, 0, H } },
        .{ 0x2514, .{ 0, L, L, 0 } }, .{ 0x2515, .{ 0, H, L, 0 } }, .{ 0x2516, .{ 0, L, H, 0 } }, .{ 0x2517, .{ 0, H, H, 0 } },
        .{ 0x2518, .{ L, 0, L, 0 } }, .{ 0x2519, .{ H, 0, L, 0 } }, .{ 0x251A, .{ L, 0, H, 0 } }, .{ 0x251B, .{ H, 0, H, 0 } },
        .{ 0x251C, .{ 0, L, L, L } }, .{ 0x251D, .{ 0, H, L, L } }, .{ 0x251E, .{ 0, L, H, L } }, .{ 0x251F, .{ 0, L, L, H } },
        .{ 0x2520, .{ 0, L, H, H } }, .{ 0x2521, .{ 0, H, H, L } }, .{ 0x2522, .{ 0, H, L, H } }, .{ 0x2523, .{ 0, H, H, H } },
        .{ 0x2524, .{ L, 0, L, L } }, .{ 0x2525, .{ H, 0, L, L } }, .{ 0x2526, .{ L, 0, H, L } }, .{ 0x2527, .{ L, 0, L, H } },
        .{ 0x2528, .{ L, 0, H, H } }, .{ 0x2529, .{ H, 0, H, L } }, .{ 0x252A, .{ H, 0, L, H } }, .{ 0x252B, .{ H, 0, H, H } },
        .{ 0x252C, .{ L, L, 0, L } }, .{ 0x252D, .{ H, L, 0, L } }, .{ 0x252E, .{ L, H, 0, L } }, .{ 0x252F, .{ H, H, 0, L } },
        .{ 0x2530, .{ L, L, 0, H } }, .{ 0x2531, .{ H, L, 0, H } }, .{ 0x2532, .{ L, H, 0, H } }, .{ 0x2533, .{ H, H, 0, H } },
        .{ 0x2534, .{ L, L, L, 0 } }, .{ 0x2535, .{ H, L, L, 0 } }, .{ 0x2536, .{ L, H, L, 0 } }, .{ 0x2537, .{ H, H, L, 0 } },
        .{ 0x2538, .{ L, L, H, 0 } }, .{ 0x2539, .{ H, L, H, 0 } }, .{ 0x253A, .{ L, H, H, 0 } }, .{ 0x253B, .{ H, H, H, 0 } },
        .{ 0x253C, .{ L, L, L, L } }, .{ 0x253D, .{ H, L, L, L } }, .{ 0x253E, .{ L, H, L, L } }, .{ 0x253F, .{ H, H, L, L } },
        .{ 0x2540, .{ L, L, H, L } }, .{ 0x2541, .{ L, L, L, H } }, .{ 0x2542, .{ L, L, H, H } }, .{ 0x2543, .{ H, L, H, L } },
        .{ 0x2544, .{ L, H, H, L } }, .{ 0x2545, .{ H, L, L, H } }, .{ 0x2546, .{ L, H, L, H } }, .{ 0x2547, .{ H, H, H, L } },
        .{ 0x2548, .{ H, H, L, H } }, .{ 0x2549, .{ H, L, H, H } }, .{ 0x254A, .{ L, H, H, H } }, .{ 0x254B, .{ H, H, H, H } },
        .{ 0x2550, .{ D, D, 0, 0 } }, .{ 0x2551, .{ 0, 0, D, D } },
        .{ 0x2552, .{ 0, D, 0, L } }, .{ 0x2553, .{ 0, L, 0, D } }, .{ 0x2554, .{ 0, D, 0, D } },
        .{ 0x2555, .{ D, 0, 0, L } }, .{ 0x2556, .{ L, 0, 0, D } }, .{ 0x2557, .{ D, 0, 0, D } },
        .{ 0x2558, .{ 0, D, L, 0 } }, .{ 0x2559, .{ 0, L, D, 0 } }, .{ 0x255A, .{ 0, D, D, 0 } },
        .{ 0x255B, .{ D, 0, L, 0 } }, .{ 0x255C, .{ L, 0, D, 0 } }, .{ 0x255D, .{ D, 0, D, 0 } },
        .{ 0x255E, .{ 0, D, L, L } }, .{ 0x255F, .{ 0, L, D, D } }, .{ 0x2560, .{ 0, D, D, D } },
        .{ 0x2561, .{ D, 0, L, L } }, .{ 0x2562, .{ L, 0, D, D } }, .{ 0x2563, .{ D, 0, D, D } },
        .{ 0x2564, .{ D, D, 0, L } }, .{ 0x2565, .{ L, L, 0, D } }, .{ 0x2566, .{ D, D, 0, D } },
        .{ 0x2567, .{ D, D, L, 0 } }, .{ 0x2568, .{ L, L, D, 0 } }, .{ 0x2569, .{ D, D, D, 0 } },
        .{ 0x256A, .{ D, D, L, L } }, .{ 0x256B, .{ L, L, D, D } }, .{ 0x256C, .{ D, D, D, D } },
        .{ 0x2574, .{ L, 0, 0, 0 } }, .{ 0x2575, .{ 0, 0, L, 0 } }, .{ 0x2576, .{ 0, L, 0, 0 } }, .{ 0x2577, .{ 0, 0, 0, L } },
        .{ 0x2578, .{ H, 0, 0, 0 } }, .{ 0x2579, .{ 0, 0, H, 0 } }, .{ 0x257A, .{ 0, H, 0, 0 } }, .{ 0x257B, .{ 0, 0, 0, H } },
        .{ 0x257C, .{ L, H, 0, 0 } }, .{ 0x257D, .{ 0, 0, L, H } }, .{ 0x257E, .{ H, L, 0, 0 } }, .{ 0x257F, .{ 0, 0, H, L } },
    };
    for (entries) |e| t[e[0] - 0x2500] = e[1];
    break :blk t;
};

pub fn handles(cp: u32) bool {
    if (cp >= 0x2500 and cp <= 0x257F) return table[cp - 0x2500] != null or (cp >= 0x256D and cp <= 0x2573);
    return cp >= 0x2580 and cp <= 0x2595;
}

/// Draws the character in the cell at (x, y) of size (w, h), in the current source color.
pub fn draw(cr: *cairo.Context, cp: u32, x: f64, y: f64, w: f64, h: f64) void {
    const thin = @max(1, @round(h / 16));
    if (cp >= 0x256D and cp <= 0x2570) return rounded(cr, cp, x, y, w, h, thin);
    if (cp >= 0x2571 and cp <= 0x2573) return diagonal(cr, cp, x, y, w, h, thin);
    if (cp >= 0x2580 and cp <= 0x2595) return block(cr, cp, x, y, w, h);
    if (cp >= 0x2500 and cp <= 0x257F) if (table[cp - 0x2500]) |s| lines(cr, s, x, y, w, h, thin);
}

fn rect(cr: *cairo.Context, x0: f64, y0: f64, x1: f64, y1: f64) void {
    cr.rectangle(x0, y0, x1 - x0, y1 - y0);
    cr.fill();
}

fn lines(cr: *cairo.Context, s: Segs, x: f64, y: f64, w: f64, h: f64, thin: f64) void {
    const cx = @round(x + w / 2);
    const cy = @round(y + h / 2);
    const reach = thin / 2;
    const vert = s[2] != none or s[3] != none;
    const horiz = s[0] != none or s[1] != none;
    horizontal(cr, x, cx + if (s[0] != none and vert) reach else 0, cy, s[0], thin);
    horizontal(cr, cx - if (s[1] != none and vert) reach else 0, x + w, cy, s[1], thin);
    vertical(cr, y, cy + if (s[2] != none and horiz) reach else 0, cx, s[2], thin);
    vertical(cr, cy - if (s[3] != none and horiz) reach else 0, y + h, cx, s[3], thin);
}

fn horizontal(cr: *cairo.Context, x0: f64, x1: f64, cy: f64, weight: u2, thin: f64) void {
    switch (weight) {
        none => {},
        double => {
            rect(cr, x0, cy - thin * 1.5, x1, cy - thin * 0.5);
            rect(cr, x0, cy + thin * 0.5, x1, cy + thin * 1.5);
        },
        else => {
            const t = if (weight == heavy) thin * 2 else thin;
            rect(cr, x0, cy - t / 2, x1, cy + t / 2);
        },
    }
}

fn vertical(cr: *cairo.Context, y0: f64, y1: f64, cx: f64, weight: u2, thin: f64) void {
    switch (weight) {
        none => {},
        double => {
            rect(cr, cx - thin * 1.5, y0, cx - thin * 0.5, y1);
            rect(cr, cx + thin * 0.5, y0, cx + thin * 1.5, y1);
        },
        else => {
            const t = if (weight == heavy) thin * 2 else thin;
            rect(cr, cx - t / 2, y0, cx + t / 2, y1);
        },
    }
}

fn rounded(cr: *cairo.Context, cp: u32, x: f64, y: f64, w: f64, h: f64, thin: f64) void {
    const cx = @round(x + w / 2);
    const cy = @round(y + h / 2);
    const r = @min(w, h) / 2;
    switch (cp) {
        0x256D => {
            cr.moveTo(x + w, cy);
            cr.curveTo(cx, cy, cx, cy, cx, cy + r);
            cr.lineTo(cx, y + h);
        },
        0x256E => {
            cr.moveTo(x, cy);
            cr.curveTo(cx, cy, cx, cy, cx, cy + r);
            cr.lineTo(cx, y + h);
        },
        0x256F => {
            cr.moveTo(x, cy);
            cr.curveTo(cx, cy, cx, cy, cx, cy - r);
            cr.lineTo(cx, y);
        },
        else => {
            cr.moveTo(x + w, cy);
            cr.curveTo(cx, cy, cx, cy, cx, cy - r);
            cr.lineTo(cx, y);
        },
    }
    cr.setLineWidth(thin);
    cr.stroke();
}

fn diagonal(cr: *cairo.Context, cp: u32, x: f64, y: f64, w: f64, h: f64, thin: f64) void {
    cr.setLineWidth(thin);
    if (cp == 0x2571 or cp == 0x2573) {
        cr.moveTo(x + w, y);
        cr.lineTo(x, y + h);
        cr.stroke();
    }
    if (cp == 0x2572 or cp == 0x2573) {
        cr.moveTo(x, y);
        cr.lineTo(x + w, y + h);
        cr.stroke();
    }
}

/// Block elements. Shades paint the cell at part strength; the caller's color alpha is kept.
fn block(cr: *cairo.Context, cp: u32, x: f64, y: f64, w: f64, h: f64) void {
    const f = struct {
        fn fill(c: *cairo.Context, bx: f64, by: f64, bw: f64, bh: f64, x0: f64, y0: f64, x1: f64, y1: f64) void {
            rect(c, bx + bw * x0, by + bh * y0, bx + bw * x1, by + bh * y1);
        }
    }.fill;
    switch (cp) {
        0x2580 => f(cr, x, y, w, h, 0, 0, 1, 0.5),
        0x2581...0x2588 => f(cr, x, y, w, h, 0, 1 - @as(f64, @floatFromInt(cp - 0x2580)) / 8, 1, 1),
        0x2589...0x258F => f(cr, x, y, w, h, 0, 0, @as(f64, @floatFromInt(0x2590 - cp)) / 8, 1),
        0x2590 => f(cr, x, y, w, h, 0.5, 0, 1, 1),
        0x2591, 0x2592, 0x2593 => {
            cr.pushGroup();
            f(cr, x, y, w, h, 0, 0, 1, 1);
            cr.popGroupToSource();
            cr.paintWithAlpha(@as(f64, @floatFromInt(cp - 0x2590)) / 4);
        },
        0x2594 => f(cr, x, y, w, h, 0, 0, 1, 0.125),
        0x2595 => f(cr, x, y, w, h, 0.875, 0, 1, 1),
        else => {},
    }
}

test "box drawing covers lines, corners and blocks" {
    try std.testing.expect(handles(0x2500));
    try std.testing.expect(handles(0x256D));
    try std.testing.expect(handles(0x2588));
    try std.testing.expect(!handles('a'));
    try std.testing.expect(!handles(0x2596));
}
