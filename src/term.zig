//! A libghostty-vt terminal and the frame copied out of it for drawing. Main thread only.
const std = @import("std");
const c = @import("vtc");

const gpa = std.heap.c_allocator;

pub const Flags = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strike: bool = false,
    overline: bool = false,
    underline: bool = false,
    selected: bool = false,
    wide: bool = false,
    spacer: bool = false,
    link: bool = false,
    _: u3 = 0,
};

pub const Cell = struct {
    /// The codepoint, or 0 for an empty cell. Longer graphemes start at `extra` in the frame's extras.
    cp: u32 = 0,
    extra: u32 = 0,
    extra_len: u16 = 0,
    flags: Flags = .{},
    /// 0xRRGGBB with the top byte set, or 0 for the terminal's default.
    fg: u32 = 0,
    bg: u32 = 0,
};

pub const Frame = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    bg: u32 = 0,
    fg: u32 = 0,
    cursor_color: u32 = 0,
    cursor_visible: bool = false,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    cursor_style: c_int = 0,
    scroll_total: u64 = 0,
    scroll_offset: u64 = 0,
    scroll_len: u64 = 0,
    mouse: bool = false,
    alt_screen: bool = false,
    bracketed_paste: bool = false,
    cells: std.ArrayList(Cell) = .empty,
    extras: std.ArrayList(u32) = .empty,

    pub fn cell(f: *const Frame, x: usize, y: usize) Cell {
        return f.cells.items[y * f.cols + x];
    }

    pub fn grapheme(f: *const Frame, cl: Cell) []const u32 {
        return f.extras.items[cl.extra .. cl.extra + cl.extra_len];
    }
};

/// A search match on screen; `end` is inclusive.
pub const Match = struct { x0: u16, y0: u32, x1: u16, y1: u32, selected: bool };

pub const Term = struct {
    term: c.GhosttyTerminal,
    search: c.GhosttySearch = null,
    rs: c.GhosttyRenderState = null,
    rows: c.GhosttyRenderStateRowIterator = null,
    cells: c.GhosttyRenderStateRowCells = null,
    frame: Frame = .{},

    pub fn create(cols: u16, rows: u16) ?*Term {
        var t: c.GhosttyTerminal = null;
        if (c.ghostty_terminal_new(null, &t, cols, rows) != c.GHOSTTY_SUCCESS) return null;
        return wrap(t);
    }

    /// Builds a terminal from a Ghostty snapshot, or null if it doesn't decode.
    pub fn fromSnapshot(bytes: []const u8) ?*Term {
        var d: c.GhosttySnapshotDecoder = null;
        var t: c.GhosttyTerminal = null;
        var r = c.ghostty_snapshot_decoder_new_buf(null, &d, bytes.ptr, bytes.len);
        if (r == c.GHOSTTY_SUCCESS) {
            const compress = true;
            _ = c.ghostty_snapshot_decoder_set(d, c.GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &compress);
            r = c.ghostty_snapshot_decoder_decode(d, &t);
        }
        if (d != null) c.ghostty_snapshot_decoder_free(d);
        if (r != c.GHOSTTY_SUCCESS or t == null) return null;
        return wrap(t);
    }

    fn wrap(t: c.GhosttyTerminal) ?*Term {
        const self = gpa.create(Term) catch {
            c.ghostty_terminal_free(t);
            return null;
        };
        self.* = .{ .term = t };
        _ = c.ghostty_render_state_new(null, &self.rs);
        _ = c.ghostty_render_state_row_iterator_new(null, &self.rows);
        _ = c.ghostty_render_state_row_cells_new(null, &self.cells);
        return self;
    }

    pub fn destroy(self: *Term) void {
        if (self.search != null) c.ghostty_search_free(self.search);
        c.ghostty_render_state_row_cells_free(self.cells);
        c.ghostty_render_state_row_iterator_free(self.rows);
        c.ghostty_render_state_free(self.rs);
        c.ghostty_terminal_free(self.term);
        self.frame.cells.deinit(gpa);
        self.frame.extras.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn write(self: *Term, data: []const u8) void {
        if (data.len > 0) c.ghostty_terminal_vt_write(self.term, data.ptr, data.len);
    }

    pub fn resize(self: *Term, cols: u16, rows: u16, cell_w: u32, cell_h: u32) void {
        _ = c.ghostty_terminal_resize(self.term, cols, rows, cell_w, cell_h);
    }

    pub fn scroll(self: *Term, delta: isize) void {
        var b: c.GhosttyTerminalScrollViewport = std.mem.zeroes(c.GhosttyTerminalScrollViewport);
        b.tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA;
        b.value.delta = delta;
        c.ghostty_terminal_scroll_viewport(self.term, b);
    }

    pub fn scrollToBottom(self: *Term) void {
        var b: c.GhosttyTerminalScrollViewport = std.mem.zeroes(c.GhosttyTerminalScrollViewport);
        b.tag = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
        c.ghostty_terminal_scroll_viewport(self.term, b);
    }

    /// Colors are 0xRRGGBB; 0 goes back to the built-in value. A null palette resets it too.
    pub fn setColors(self: *Term, fg: u32, bg: u32, cursor: u32, palette: ?*const [256]u32) void {
        const f = rgbOf(fg);
        const b = rgbOf(bg);
        const k = rgbOf(cursor);
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, if (fg == 0) null else &f);
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, if (bg == 0) null else &b);
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, if (cursor == 0) null else &k);
        if (palette) |p| {
            var pal: [256]c.GhosttyColorRgb = undefined;
            for (p, 0..) |v, i| pal[i] = rgbOf(v);
            _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &pal);
        } else {
            _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, null);
        }
    }

    /// The title the program set with OSC 0 or 2, copied into `buf`.
    pub fn title(self: *Term, buf: []u8) ?[]const u8 {
        var str: c.GhosttyString = std.mem.zeroes(c.GhosttyString);
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_TITLE, &str) != c.GHOSTTY_SUCCESS or str.len == 0) return null;
        const n = @min(str.len, buf.len);
        @memcpy(buf[0..n], str.ptr[0..n]);
        return buf[0..n];
    }

    // Selection, by viewport cell.

    fn viewportRef(self: *Term, x: u16, y: u32, ref: *c.GhosttyGridRef) bool {
        var p: c.GhosttyPoint = std.mem.zeroes(c.GhosttyPoint);
        p.tag = c.GHOSTTY_POINT_TAG_VIEWPORT;
        p.value.coordinate.x = x;
        p.value.coordinate.y = y;
        ref.* = std.mem.zeroes(c.GhosttyGridRef);
        return c.ghostty_terminal_grid_ref(self.term, p, ref) == c.GHOSTTY_SUCCESS;
    }

    pub fn selectRange(self: *Term, x1: u16, y1: u32, x2: u16, y2: u32) void {
        var sel: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
        if (!self.viewportRef(x1, y1, &sel.start) or !self.viewportRef(x2, y2, &sel.end)) return;
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
    }

    pub fn selectWord(self: *Term, x: u16, y: u32) void {
        var o: c.GhosttyTerminalSelectWordOptions = std.mem.zeroes(c.GhosttyTerminalSelectWordOptions);
        o.size = @sizeOf(c.GhosttyTerminalSelectWordOptions);
        if (!self.viewportRef(x, y, &o.ref)) return;
        var sel: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_select_word(self.term, &o, &sel) != c.GHOSTTY_SUCCESS) return;
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
    }

    pub fn clearSelection(self: *Term) void {
        _ = c.ghostty_terminal_set(self.term, c.GHOSTTY_TERMINAL_OPT_SELECTION, null);
    }

    /// The selected text, unwrapped and trimmed, or null when nothing is selected. Caller frees.
    pub fn selectionText(self: *Term) ?[:0]u8 {
        var sel: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != c.GHOSTTY_SUCCESS) return null;
        var o: c.GhosttyTerminalSelectionFormatOptions = std.mem.zeroes(c.GhosttyTerminalSelectionFormatOptions);
        o.size = @sizeOf(c.GhosttyTerminalSelectionFormatOptions);
        o.emit = c.GHOSTTY_FORMATTER_FORMAT_PLAIN;
        o.unwrap = true;
        o.trim = true;
        o.selection = &sel;
        var out: [*c]u8 = null;
        var len: usize = 0;
        if (c.ghostty_terminal_selection_format_alloc(self.term, null, &o, &out, &len) != c.GHOSTTY_SUCCESS or out == null) return null;
        defer c.ghostty_free(null, out, len);
        if (len == 0) return null;
        return gpa.dupeSentinel(u8, out[0..len], 0) catch null;
    }

    /// The OSC 8 link target at a cell, or null. Caller frees.
    pub fn hyperlinkAt(self: *Term, x: u16, y: u32) ?[:0]u8 {
        var ref: c.GhosttyGridRef = undefined;
        if (!self.viewportRef(x, y, &ref)) return null;
        var buf: [2048]u8 = undefined;
        var len: usize = 0;
        if (c.ghostty_grid_ref_hyperlink_uri(&ref, &buf, buf.len - 1, &len) != c.GHOSTTY_SUCCESS or len == 0) return null;
        return gpa.dupeSentinel(u8, buf[0..len], 0) catch null;
    }

    // Search.

    /// Starts or changes a search; returns how many matches it found.
    pub fn find(self: *Term, needle: []const u8) usize {
        if (self.search == null and c.ghostty_search_new(null, &self.search, self.term) != c.GHOSTTY_SUCCESS) return 0;
        var text: c.GhosttyString = .{ .ptr = needle.ptr, .len = needle.len };
        if (c.ghostty_search_set(self.search, c.GHOSTTY_SEARCH_OPT_NEEDLE, &text) != c.GHOSTTY_SUCCESS) return 0;
        if (c.ghostty_search_run(self.search) != c.GHOSTTY_SUCCESS) return 0;
        var total: usize = 0;
        _ = c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total);
        return total;
    }

    /// Moves to the next older or newer match, scrolling to it. Returns its index.
    pub fn findStep(self: *Term, older: bool) ?usize {
        if (self.search == null) return null;
        if (c.ghostty_search_set(self.search, if (older) c.GHOSTTY_SEARCH_OPT_SELECT_NEXT else c.GHOSTTY_SEARCH_OPT_SELECT_PREV, null) != c.GHOSTTY_SUCCESS) return null;
        var index: usize = 0;
        if (c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) != c.GHOSTTY_SUCCESS) return null;
        return index;
    }

    pub fn endFind(self: *Term) void {
        if (self.search != null) c.ghostty_search_free(self.search);
        self.search = null;
    }

    pub fn finding(self: *const Term) bool {
        return self.search != null;
    }

    fn matchPoints(self: *Term, m: *const c.GhosttySelection, a: *c.GhosttyPointCoordinate, b: *c.GhosttyPointCoordinate) bool {
        return c.ghostty_terminal_point_from_grid_ref(self.term, &m.start, c.GHOSTTY_POINT_TAG_VIEWPORT, a) == c.GHOSTTY_SUCCESS and
            c.ghostty_terminal_point_from_grid_ref(self.term, &m.end, c.GHOSTTY_POINT_TAG_VIEWPORT, b) == c.GHOSTTY_SUCCESS;
    }

    /// Fills `out` with the matches on screen and returns how many.
    pub fn matches(self: *Term, out: []Match) usize {
        if (self.search == null or c.ghostty_search_feed(self.search) != c.GHOSTTY_SUCCESS) return 0;
        var storage: [128]c.GhosttySelection = undefined;
        var buffer: c.GhosttySelectionBuffer = .{ .ptr = &storage, .cap = storage.len, .len = 0 };
        const r = c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer);
        if (r != c.GHOSTTY_SUCCESS and r != c.GHOSTTY_OUT_OF_SPACE) return 0;
        const found = @min(buffer.len, storage.len);
        var sa: c.GhosttyPointCoordinate = undefined;
        var sb: c.GhosttyPointCoordinate = undefined;
        var selected: c.GhosttySelection = std.mem.zeroes(c.GhosttySelection);
        const has_selected = c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &selected) == c.GHOSTTY_SUCCESS and
            self.matchPoints(&selected, &sa, &sb);
        var n: usize = 0;
        for (storage[0..found]) |*m| {
            if (n == out.len) break;
            var a: c.GhosttyPointCoordinate = undefined;
            var b: c.GhosttyPointCoordinate = undefined;
            if (!self.matchPoints(m, &a, &b)) continue;
            out[n] = .{ .x0 = a.x, .y0 = a.y, .x1 = b.x, .y1 = b.y, .selected = has_selected and a.x == sa.x and a.y == sa.y and b.x == sb.x and b.y == sb.y };
            n += 1;
        }
        return n;
    }

    /// Copies the screen into `frame`. False when nothing changed since last time.
    pub fn render(self: *Term, force: bool) bool {
        if (c.ghostty_render_state_update(self.rs, self.term) != c.GHOSTTY_SUCCESS) return false;
        var dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = c.ghostty_render_state_get(self.rs, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
        if (!force and dirty == c.GHOSTTY_RENDER_STATE_DIRTY_FALSE) return false;

        const f = &self.frame;
        var cols: u16 = 0;
        var rows: u16 = 0;
        _ = c.ghostty_render_state_get(self.rs, c.GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
        _ = c.ghostty_render_state_get(self.rs, c.GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
        f.cols = cols;
        f.rows = rows;

        var colors: c.GhosttyRenderStateColors = std.mem.zeroes(c.GhosttyRenderStateColors);
        colors.size = @sizeOf(c.GhosttyRenderStateColors);
        _ = c.ghostty_render_state_get(self.rs, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
        f.bg = rgb(colors.background);
        f.fg = rgb(colors.foreground);
        f.cursor_color = if (colors.cursor_has_value) rgb(colors.cursor) else 0;

        var cursor: c.GhosttyRenderStateCursor = std.mem.zeroes(c.GhosttyRenderStateCursor);
        cursor.size = @sizeOf(c.GhosttyRenderStateCursor);
        _ = c.ghostty_render_state_get(self.rs, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
        f.cursor_visible = cursor.visible and cursor.viewport_has_value;
        f.cursor_x = cursor.viewport_x;
        f.cursor_y = cursor.viewport_y;
        f.cursor_style = @intCast(cursor.visual_style);

        var sb: c.GhosttyTerminalScrollbar = std.mem.zeroes(c.GhosttyTerminalScrollbar);
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
        f.scroll_total = sb.total;
        f.scroll_offset = sb.offset;
        f.scroll_len = sb.len;

        var mouse = false;
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &mouse);
        f.mouse = mouse;
        var screen: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
        f.alt_screen = screen != c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        var bracket: c.GhosttyTerminalModeConfig = std.mem.zeroes(c.GhosttyTerminalModeConfig);
        bracket.mode = c.GHOSTTY_MODE_BRACKETED_PASTE;
        _ = c.ghostty_terminal_get(self.term, c.GHOSTTY_TERMINAL_DATA_MODE, &bracket);
        f.bracketed_paste = bracket.value;

        const count = @as(usize, cols) * rows;
        f.cells.resize(gpa, count) catch return false;
        @memset(f.cells.items, .{});
        f.extras.clearRetainingCapacity();

        _ = c.ghostty_render_state_get(self.rs, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.rows));
        var y: usize = 0;
        while (y < rows and c.ghostty_render_state_row_iterator_next(self.rows)) : (y += 1) {
            var sel: c.GhosttyRenderStateRowSelection = std.mem.zeroes(c.GhosttyRenderStateRowSelection);
            sel.size = @sizeOf(c.GhosttyRenderStateRowSelection);
            const has_sel = c.ghostty_render_state_row_get(self.rows, c.GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &sel) == c.GHOSTTY_SUCCESS;
            _ = c.ghostty_render_state_row_get(self.rows, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.cells));
            var x: usize = 0;
            while (x < cols and c.ghostty_render_state_row_cells_next(self.cells)) : (x += 1) {
                const out = &f.cells.items[y * cols + x];
                var glen: u32 = 0;
                _ = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
                if (glen > 0 and glen <= 32) {
                    var buf: [32]u32 = undefined;
                    _ = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buf);
                    out.cp = buf[0];
                    if (glen > 1) {
                        out.extra = @intCast(f.extras.items.len);
                        out.extra_len = @intCast(glen);
                        f.extras.appendSlice(gpa, buf[0..glen]) catch {};
                    }
                }
                var col: c.GhosttyColorRgb = undefined;
                if (c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &col) == c.GHOSTTY_SUCCESS) out.bg = rgb(col);
                var styled = false;
                _ = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled);
                if (styled) {
                    if (c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &col) == c.GHOSTTY_SUCCESS) out.fg = rgb(col);
                    var style: c.GhosttyStyle = std.mem.zeroes(c.GhosttyStyle);
                    _ = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
                    const s: u32 = @intCast(style.flags);
                    out.flags.bold = s & (1 << 0) != 0;
                    out.flags.italic = s & (1 << 1) != 0;
                    out.flags.faint = s & (1 << 2) != 0;
                    out.flags.blink = s & (1 << 3) != 0;
                    out.flags.inverse = s & (1 << 4) != 0;
                    out.flags.invisible = s & (1 << 5) != 0;
                    out.flags.strike = s & (1 << 6) != 0;
                    out.flags.overline = s & (1 << 7) != 0;
                    out.flags.underline = (s >> 8) & 0x7 != 0;
                }
                var raw: c.GhosttyCell = 0;
                if (c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == c.GHOSTTY_SUCCESS) {
                    var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
                    _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide);
                    if (wide == c.GHOSTTY_CELL_WIDE_WIDE) out.flags.wide = true else if (wide != c.GHOSTTY_CELL_WIDE_NARROW) out.flags.spacer = true;
                    var link = false;
                    _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_HAS_HYPERLINK, &link);
                    out.flags.link = link;
                }
                if (has_sel and x >= sel.start_x and x <= sel.end_x) out.flags.selected = true;
            }
        }
        _ = c.ghostty_render_state_clean(self.rs);
        return true;
    }
};

fn rgb(v: c.GhosttyColorRgb) u32 {
    return 0xFF000000 | (@as(u32, v.r) << 16) | (@as(u32, v.g) << 8) | v.b;
}

fn rgbOf(v: u32) c.GhosttyColorRgb {
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

test "a terminal takes output and renders it" {
    const t = Term.create(20, 3) orelse return error.NoTerminal;
    defer t.destroy();
    t.write("hi \x1b[1mthere\x1b[0m");
    try std.testing.expect(t.render(true));
    try std.testing.expectEqual(@as(u16, 20), t.frame.cols);
    try std.testing.expectEqual(@as(u32, 'h'), t.frame.cell(0, 0).cp);
    try std.testing.expect(t.frame.cell(3, 0).flags.bold);
}

test "select a word, copy it, and find text" {
    const t = Term.create(30, 3) orelse return error.NoTerminal;
    defer t.destroy();
    t.write("hello brave world\r\nworld again");
    t.selectWord(7, 0);
    const text = t.selectionText() orelse return error.NoSelection;
    defer gpa.free(text);
    try std.testing.expectEqualStrings("brave", text);
    t.clearSelection();
    try std.testing.expect(t.selectionText() == null);
    try std.testing.expectEqual(@as(usize, 2), t.find("world"));
    _ = t.findStep(true);
    var out: [8]Match = undefined;
    try std.testing.expectEqual(@as(usize, 2), t.matches(&out));
    try std.testing.expect(t.hyperlinkAt(0, 0) == null);
    t.endFind();
}
