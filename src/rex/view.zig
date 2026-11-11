//! What a session looks like: its windows, their layers, and how panes tile. Each view owns an
//! arena holding everything it points at, so it is replaced as a whole when the server changes it.
const std = @import("std");
const json = @import("../util/json.zig");

const gpa = std.heap.c_allocator;

/// A rectangle in fractions of a window's width and height.
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 1,
    h: f64 = 1,
};

/// `v` kept between `lo` and `hi`. Unlike `std.math.clamp` the range may be empty or not a
/// number, as it is for a layer the server placed past the window's edge; `lo` wins then.
pub fn clampWithin(v: f64, lo: f64, hi: f64) f64 {
    if (!(hi > lo)) return lo;
    if (!(v > lo)) return lo;
    return @min(v, hi);
}

pub const Block = struct {
    id: []const u8,
    label: []const u8,
    creator: []const u8,
    flavor: []const u8,
    owner: ?[]const u8,

    pub fn isTerminal(b: Block) bool {
        return std.mem.endsWith(u8, b.creator, ".terminal");
    }
};

pub const Node = union(enum) {
    leaf: struct { rect: Rect, block_id: []const u8 },
    split: struct {
        rect: Rect,
        id: []const u8,
        /// Side by side when true; stacked otherwise.
        horizontal: bool,
        ratio: f64,
        before: *Node,
        after: *Node,
    },

    pub fn rect(n: Node) Rect {
        return switch (n) {
            inline else => |v| v.rect,
        };
    }
};

pub const Layer = struct {
    id: []const u8,
    floating: bool,
    minimized: bool,
    bounds: Rect,
    layout: ?*Node,
    blocks: []Block,
};

pub const Window = struct {
    id: []const u8,
    label: []const u8,
    focused_block_id: ?[]const u8,
    zoomed_block_id: ?[]const u8,
    layers: []Layer,

    pub fn tiled(w: Window) ?Layer {
        for (w.layers) |l| if (!l.floating) return l;
        return null;
    }

    pub fn findBlock(w: Window, id: []const u8) ?Block {
        for (w.layers) |l| for (l.blocks) |b| if (std.mem.eql(u8, b.id, id)) return b;
        return null;
    }

    /// The label, unless Rex generated it ("Window 1a2b3c4d").
    pub fn title(w: Window) ?[]const u8 {
        if (w.label.len == 0) return null;
        if (w.label.len == 15 and std.mem.startsWith(u8, w.label, "Window ")) return null;
        return w.label;
    }
};

pub const SessionView = struct {
    arena: std.heap.ArenaAllocator,
    revision: i64,
    session_id: []const u8,
    label: []const u8,
    active_window_id: ?[]const u8,
    windows: []Window,

    pub fn destroy(v: *SessionView) void {
        var arena = v.arena;
        gpa.destroy(v);
        arena.deinit();
    }

    pub fn activeWindow(v: *const SessionView) ?*const Window {
        if (v.active_window_id) |id| for (v.windows) |*w| if (std.mem.eql(u8, w.id, id)) return w;
        return if (v.windows.len > 0) &v.windows[0] else null;
    }

    pub fn window(v: *const SessionView, id: []const u8) ?*const Window {
        for (v.windows) |*w| if (std.mem.eql(u8, w.id, id)) return w;
        return null;
    }

    pub fn windowOf(v: *const SessionView, block_id: []const u8) ?*const Window {
        for (v.windows) |*w| if (w.findBlock(block_id) != null) return w;
        return null;
    }
};

/// Parses a session.view payload. Returns null when it isn't one.
pub fn parse(value: ?json.Value) !?*SessionView {
    const v = value orelse return null;
    const session_id = json.str(v, "session_id") orelse return null;
    const view = try gpa.create(SessionView);
    errdefer gpa.destroy(view);
    view.arena = .init(gpa);
    errdefer view.arena.deinit();
    const a = view.arena.allocator();
    view.revision = json.int(v, "revision") orelse 0;
    view.session_id = try a.dupe(u8, session_id);
    view.label = try a.dupe(u8, json.str(v, "label") orelse "");
    view.active_window_id = try dupeOpt(a, json.str(v, "active_window_id"));

    var windows: std.ArrayList(Window) = .empty;
    for (json.array(v, "windows")) |w| {
        const id = json.str(w, "window_id") orelse continue;
        var layers: std.ArrayList(Layer) = .empty;
        for (json.array(w, "layers")) |l| try layers.append(a, try parseLayer(a, l));
        try windows.append(a, .{
            .id = try a.dupe(u8, id),
            .label = try a.dupe(u8, json.str(w, "label") orelse ""),
            .focused_block_id = try dupeOpt(a, json.str(w, "focused_block_id")),
            .zoomed_block_id = try dupeOpt(a, json.str(w, "zoomed_block_id")),
            .layers = layers.items,
        });
    }
    view.windows = windows.items;
    return view;
}

fn parseLayer(a: std.mem.Allocator, l: json.Value) !Layer {
    var blocks: std.ArrayList(Block) = .empty;
    for (json.array(l, "blocks")) |b| if (try parseBlock(a, b)) |block| try blocks.append(a, block);
    return .{
        .id = try a.dupe(u8, json.str(l, "layer_id") orelse ""),
        // The docs say to draw a kind we don't know as floating.
        .floating = !std.mem.eql(u8, json.str(l, "kind") orelse "", "tiled"),
        .minimized = std.mem.eql(u8, json.str(l, "state") orelse "", "minimized"),
        .bounds = rectOf(json.get(l, "bounds")),
        .layout = try parseNode(a, json.get(l, "layout")),
        .blocks = blocks.items,
    };
}

pub fn parseBlock(a: std.mem.Allocator, b: json.Value) !?Block {
    const id = json.str(b, "block_id") orelse return null;
    return .{
        .id = try a.dupe(u8, id),
        .label = try a.dupe(u8, json.str(b, "label") orelse ""),
        .creator = try a.dupe(u8, json.str(b, "creator_name") orelse ""),
        .flavor = try a.dupe(u8, json.str(b, "flavor") orelse ""),
        .owner = try dupeOpt(a, json.str(b, "owner")),
    };
}

fn parseNode(a: std.mem.Allocator, value: ?json.Value) !?*Node {
    const v = value orelse return null;
    if (!json.isObject(v)) return null;
    const r = rectOf(json.get(v, "rect"));
    if (json.get(v, "split")) |s| if (json.isObject(s)) {
        const before = try parseNode(a, json.get(s, "before"));
        const after = try parseNode(a, json.get(s, "after"));
        if (before == null) return after;
        if (after == null) return before;
        const n = try a.create(Node);
        n.* = .{
            .split = .{
                .rect = r,
                .id = try a.dupe(u8, json.str(s, "split_id") orelse ""),
                // The docs say to draw an unknown direction as horizontal.
                .horizontal = !std.mem.eql(u8, json.str(s, "direction") orelse "", "vertical"),
                .ratio = json.float(s, "ratio") orelse 0.5,
                .before = before.?,
                .after = after.?,
            },
        };
        return n;
    };
    const block = json.str(v, "block_id") orelse return null;
    const n = try a.create(Node);
    n.* = .{ .leaf = .{ .rect = r, .block_id = try a.dupe(u8, block) } };
    return n;
}

fn rectOf(v: ?json.Value) Rect {
    const items = switch (v orelse return .{}) {
        .array => |arr| arr.items,
        else => return .{},
    };
    if (items.len < 4) return .{};
    return .{
        .x = json.asFloat(items[0]) orelse 0,
        .y = json.asFloat(items[1]) orelse 0,
        .w = json.asFloat(items[2]) orelse 1,
        .h = json.asFloat(items[3]) orelse 1,
    };
}

fn dupeOpt(a: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try a.dupe(u8, v) else null;
}

test "clamping survives an empty range" {
    try std.testing.expectEqual(@as(f64, 0.5), clampWithin(0.5, 0, 1));
    try std.testing.expectEqual(@as(f64, 0), clampWithin(-2, 0, 1));
    try std.testing.expectEqual(@as(f64, 1), clampWithin(7, 0, 1));
    // A layer wider than the window leaves no room to move: it stays at the near edge.
    try std.testing.expectEqual(@as(f64, 0), clampWithin(0.3, 0, -0.2));
    try std.testing.expectEqual(@as(f64, 0.15), clampWithin(0.6, 0.15, 0.1));
    try std.testing.expectEqual(@as(f64, 0.15), clampWithin(std.math.nan(f64), 0.15, 1));
    try std.testing.expectEqual(@as(f64, 0), clampWithin(0.5, 0, std.math.nan(f64)));
}

test "parses a split window" {
    const text =
        \\{"revision":3,"session_id":"s1","label":"work","active_window_id":"w1","windows":[{"window_id":"w1","label":"Window 0a1b2c3d",
        \\"focused_block_id":"b2","layers":[{"layer_id":"l1","kind":"tiled","bounds":[0,0,1,1],"layout":{"rect":[0,0,1,1],
        \\"split":{"split_id":"p1","direction":"horizontal","ratio":0.25,"before":{"rect":[0,0,0.25,1],"block_id":"b1"},
        \\"after":{"rect":[0.25,0,0.75,1],"block_id":"b2"}}},"blocks":[{"block_id":"b1","creator_name":"com.superlogical.terminal"},
        \\{"block_id":"b2","creator_name":"com.superlogical.terminal"}]}]}]}
    ;
    var parsed = try std.json.parseFromSlice(json.Value, gpa, text, .{});
    defer parsed.deinit();
    const v = (try parse(parsed.value)).?;
    defer v.destroy();
    const w = v.activeWindow().?;
    try std.testing.expect(w.title() == null);
    const root = w.tiled().?.layout.?;
    try std.testing.expect(root.split.horizontal);
    try std.testing.expectEqualStrings("b2", root.split.after.leaf.block_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), root.split.after.rect().x, 1e-9);
}
