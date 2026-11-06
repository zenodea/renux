//! A terminal pane: draws a block's frame with Pango and Cairo, and sends typing, clicks and
//! scrolling to the server. It finds its stream by block id each time, since the server may end
//! the stream (when the block closes) while the pane still exists.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const gdk = @import("gdk");
const cairo = @import("cairo");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const keys = @import("keys.zig");
const term = @import("term.zig");
const term_mod = term;
const Server = @import("server.zig").Server;
const Stream = @import("stream.zig").Stream;
const boxdraw = @import("boxdraw.zig");
const links = @import("links.zig");
const programs = @import("programs.zig");

const gpa = std.heap.c_allocator;

const pad = 8.0;
const size_debounce_ms = 200;

pub const Font = struct {
    regular: *pango.FontDescription,
    bold: *pango.FontDescription,
    italic: *pango.FontDescription,
    bold_italic: *pango.FontDescription,

    pub fn init(name: [:0]const u8) Font {
        return fromDesc(pango.FontDescription.fromString(name.ptr));
    }

    /// The same font at `scale` times its size, for a zoomed pane.
    pub fn scaled(f: Font, scale: f64) Font {
        const d = f.regular.copy().?;
        const size: f64 = @floatFromInt(d.getSize());
        d.setSize(@intFromFloat(@max(4 * pango.SCALE, size * scale)));
        return fromDesc(d);
    }

    fn fromDesc(regular: *pango.FontDescription) Font {
        const bold = regular.copy().?;
        bold.setWeight(.bold);
        const italic = regular.copy().?;
        italic.setStyle(.italic);
        const bold_italic = bold.copy().?;
        bold_italic.setStyle(.italic);
        return .{ .regular = regular, .bold = bold, .italic = italic, .bold_italic = bold_italic };
    }

    fn pick(f: Font, flags: term.Flags) *pango.FontDescription {
        if (flags.bold and flags.italic) return f.bold_italic;
        if (flags.bold) return f.bold;
        if (flags.italic) return f.italic;
        return f.regular;
    }
};

pub var font: ?Font = null;
/// Each pane's zoom, by block, so a pane keeps it when shown again.
var zooms: std.StringHashMapUnmanaged(f64) = .empty;
/// Whether a blinking cursor is in its visible half.
pub var blink_on = true;

pub const TermView = struct {
    area: *gtk.DrawingArea,
    server: *Server,
    session_id: []u8,
    block_id: []u8,
    cell_w: f64 = 8,
    cell_h: f64 = 16,
    baseline: f64 = 12,
    want_cols: u16 = 0,
    want_rows: u16 = 0,
    sent_cols: u16 = 0,
    sent_rows: u16 = 0,
    size_timer: c_uint = 0,
    /// Lines of scrolling not yet sent to a program that takes the mouse.
    scroll_rest: f64 = 0,
    /// How far up into history the view is, in pixels, where it's heading, and how fast a
    /// touchpad flick is still carrying it.
    scroll_px: f64 = 0,
    scroll_target: f64 = 0,
    scroll_velocity: f64 = 0,
    scroll_tick: c_uint = 0,
    last_frame_us: i64 = 0,
    last_total: u64 = 0,
    draw_frac: f64 = 0,
    listening: bool = false,
    /// This pane's text size relative to the setting, and its font at that size.
    zoom: f64 = 1,
    own_font: ?Font = null,
    im: *gtk.IMMulticontext = undefined,
    title_label: ?*gtk.Label = null,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    /// Where a selection drag started, in cells, and whether it has moved enough to select.
    anchor: [2]u16 = .{ 0, 0 },
    drag_origin: [2]f64 = .{ 0, 0 },
    selecting: bool = false,
    /// Whether the press that may start a selection belongs to the program, which takes the mouse.
    drag_to_program: bool = false,
    /// The button held for a program's drag, and the last cell reported, so moves within a cell
    /// aren't sent again.
    held_button: []const u8 = "left",
    last_motion: [2]u16 = .{ 65535, 65535 },
    /// How fast a selection drag past the top or bottom edge scrolls, in rows a tick.
    edge_scroll: f64 = 0,
    edge_timer: c_uint = 0,
    edge_point: [2]f64 = .{ 0, 0 },
    menu: ?*gtk.PopoverMenu = null,
    menu_link: ?[:0]u8 = null,
    /// Called when this pane is clicked, so the workspace can mark it focused.
    on_focus: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, block_id: []const u8) void } = null,

    pub fn create(server: *Server, session_id: []const u8, block_id: []const u8) !*TermView {
        const v = try gpa.create(TermView);
        const area = gtk.DrawingArea.new();
        v.* = .{
            .area = area,
            .server = server,
            .session_id = try gpa.dupe(u8, session_id),
            .block_id = try gpa.dupe(u8, block_id),
        };
        const w = area.as(gtk.Widget);
        w.setFocusable(1);
        w.setHexpand(1);
        w.setVexpand(1);
        w.setCursorFromName("text");
        area.setDrawFunc(&draw, v, null);
        _ = gtk.DrawingArea.signals.resize.connect(area, *TermView, &onResize, v, .{});
        _ = gtk.Widget.signals.destroy.connect(w, *TermView, &onDestroy, v, .{});

        const key = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(key, *TermView, &onKey, v, .{});
        // Typed text goes through the input method, so dead keys, compose sequences and input
        // methods for other scripts commit real text; other keys reach `onKey`.
        v.im = gtk.IMMulticontext.new();
        v.im.as(gtk.IMContext).setClientWidget(w);
        _ = gtk.IMContext.signals.commit.connect(v.im.as(gtk.IMContext), *TermView, &onCommit, v, .{});
        key.setImContext(v.im.as(gtk.IMContext));
        w.addController(key.as(gtk.EventController));

        const scroll = gtk.EventControllerScroll.new(.{ .vertical = true, .kinetic = true });
        _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *TermView, &onScroll, v, .{});
        _ = gtk.EventControllerScroll.signals.decelerate.connect(scroll, *TermView, &onDecelerate, v, .{});
        w.addController(scroll.as(gtk.EventController));

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(click, *TermView, &onPressed, v, .{});
        _ = gtk.GestureClick.signals.released.connect(click, *TermView, &onReleased, v, .{});
        w.addController(click.as(gtk.EventController));

        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *TermView, &onDragBegin, v, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *TermView, &onDragUpdate, v, .{});
        _ = gtk.GestureDrag.signals.drag_end.connect(drag, *TermView, &onDragEnd, v, .{});
        w.addController(drag.as(gtk.EventController));

        const focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(focus, *TermView, &onFocusIn, v, .{});
        _ = gtk.EventControllerFocus.signals.leave.connect(focus, *TermView, &onFocusOut, v, .{});
        w.addController(focus.as(gtk.EventController));

        if (zooms.get(block_id)) |z| v.setZoom(z);
        v.measure();
        if (server.terminal(session_id, block_id)) |st| {
            st.addListener(.{ .ctx = v, .changed = changed });
            v.listening = true;
        }
        return v;
    }

    pub fn widget(v: *TermView) *gtk.Widget {
        return v.area.as(gtk.Widget);
    }

    fn stream(v: *TermView) ?*Stream {
        return v.server.streams.get(v.block_id);
    }

    pub fn term(v: *TermView) ?*term_mod.Term {
        const st = v.stream() orelse return null;
        return st.term;
    }

    fn changed(ctx: *anyopaque) void {
        const v: *TermView = @ptrCast(@alignCast(ctx));
        v.widget().queueDraw();
        v.updateTitle();
    }

    pub fn setTitleLabel(v: *TermView, label: *gtk.Label) void {
        v.title_label = label;
        v.title_len = std.math.maxInt(usize);
        v.updateTitle();
    }

    /// The pane's title, as Rex shows it: a shell as "zsh ~/compy", anything else by the title it
    /// set, then by what runs and where.
    pub fn title(v: *TermView, out: []u8) []const u8 {
        const info = v.server.blockInfo(v.block_id);
        var folder_buf: [256]u8 = undefined;
        const folder: ?[]const u8 = if (info) |b| if (b.folder) |f| programs.shortFolder(&folder_buf, f) else null else null;
        const program: ?[]const u8 = if (info) |b| if (b.program) |p| std.mem.trimStart(u8, p[0 .. std.mem.indexOfScalar(u8, p, '/') orelse p.len], "-") else null else null;
        const shell = if (program) |p| isShell(p) else false;
        if (!shell) {
            var own_buf: [256]u8 = undefined;
            if (v.term()) |t| if (t.title(&own_buf)) |own| if (own.len > 0) return copy(out, own);
            if (info) |b| if (b.title) |t| if (t.len > 0) return copy(out, t);
        }
        if (program) |p| {
            if (folder) |f| return std.fmt.bufPrint(out, "{s} {s}", .{ p, f }) catch copy(out, p);
            return copy(out, p);
        }
        if (v.server.sessionView(v.session_id)) |sv| if (sv.windowOf(v.block_id)) |w| if (w.findBlock(v.block_id)) |blk| if (blk.label.len > 0) return copy(out, blk.label);
        return copy(out, "Terminal");
    }

    fn isShell(p: []const u8) bool {
        for ([_][]const u8{ "zsh", "bash", "fish", "sh", "dash", "nu", "elvish", "xonsh", "pwsh" }) |sh| if (std.mem.eql(u8, p, sh)) return true;
        return false;
    }

    fn copy(out: []u8, s: []const u8) []const u8 {
        const n = @min(s.len, out.len);
        @memcpy(out[0..n], s[0..n]);
        return out[0..n];
    }

    pub fn updateTitle(v: *TermView) void {
        const label = v.title_label orelse return;
        var buf: [256]u8 = undefined;
        const t = v.title(&buf);
        const n = @min(t.len, v.title_buf.len - 1);
        if (n == v.title_len and std.mem.eql(u8, v.title_buf[0..n], t[0..n])) return;
        @memcpy(v.title_buf[0..n], t[0..n]);
        v.title_buf[n] = 0;
        v.title_len = n;
        label.setText(@ptrCast(&v.title_buf));
    }

    fn onDestroy(_: *gtk.Widget, v: *TermView) callconv(.c) void {
        v.im.as(gtk.IMContext).setClientWidget(null);
        if (v.edge_timer != 0) _ = glib.Source.remove(v.edge_timer);
        if (v.menu) |m| m.as(gtk.Widget).unparent();
        if (v.menu_link) |l| gpa.free(l);
        v.im.as(gobject.Object).unref();
        if (v.size_timer != 0) _ = glib.Source.remove(v.size_timer);
        if (v.scroll_tick != 0) v.widget().removeTickCallback(v.scroll_tick);
        if (v.stream()) |st| st.removeListener(v);
        gpa.free(v.session_id);
        gpa.free(v.block_id);
        gpa.destroy(v);
    }

    /// Works out the cell size from the font. Monospace fonts have fractional advances, so it
    /// measures a long run and divides, which keeps long lines on the grid.
    fn measure(v: *TermView) void {
        const f = v.fontOf() orelse return;
        const layout = v.widget().createPangoLayout("MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM");
        defer layout.as(gobject.Object).unref();
        layout.setFontDescription(f.regular);
        var w: c_int = 0;
        var h: c_int = 0;
        layout.getSize(&w, &h);
        v.cell_w = @as(f64, @floatFromInt(w)) / pango.SCALE / 40.0;
        v.cell_h = @ceil(@as(f64, @floatFromInt(h)) / pango.SCALE);
        v.baseline = @as(f64, @floatFromInt(layout.getBaseline())) / pango.SCALE;
    }

    pub fn fontOf(v: *TermView) ?Font {
        return v.own_font orelse font;
    }

    fn setZoom(v: *TermView, z: f64) void {
        v.zoom = std.math.clamp(z, 0.4, 4);
        v.own_font = if (@abs(v.zoom - 1) < 0.01) null else if (font) |f| f.scaled(v.zoom) else null;
    }

    /// Makes this pane's text bigger or smaller by `steps`, or back to normal with 0.
    pub fn zoomBy(v: *TermView, steps: f64) void {
        v.setZoom(if (steps == 0) 1 else v.zoom * std.math.pow(f64, 1.1, steps));
        if (zooms.getPtr(v.block_id)) |z| {
            z.* = v.zoom;
        } else if (gpa.dupe(u8, v.block_id)) |key| {
            zooms.put(gpa, key, v.zoom) catch gpa.free(key);
        } else |_| {}
        v.fontChanged();
    }

    pub fn fontChanged(v: *TermView) void {
        if (v.own_font != null) v.setZoom(v.zoom);
        v.measure();
        v.want_cols = 0;
        v.want_rows = 0;
        const w = v.widget();
        onResize(v.area, w.getWidth(), w.getHeight(), v);
        w.queueDraw();
    }

    // Size.

    fn onResize(_: *gtk.DrawingArea, width: c_int, height: c_int, v: *TermView) callconv(.c) void {
        const cols: u16 = @intFromFloat(@max(1, @floor((@as(f64, @floatFromInt(width)) - 2 * pad) / v.cell_w)));
        const rows: u16 = @intFromFloat(@max(1, @floor((@as(f64, @floatFromInt(height)) - 2 * pad) / v.cell_h)));
        if (cols == v.want_cols and rows == v.want_rows) return;
        v.want_cols = cols;
        v.want_rows = rows;
        // Layout changes report many sizes in a row; only the last one matters.
        if (v.size_timer != 0) _ = glib.Source.remove(v.size_timer);
        v.size_timer = glib.timeoutAdd(size_debounce_ms, &applySize, v);
    }

    fn applySize(data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        v.size_timer = 0;
        v.sendSize();
        return 0;
    }

    /// Asks the server to fit the block to this pane, unless it already is.
    pub fn sendSize(v: *TermView) void {
        if (v.want_cols == 0) return;
        if (v.want_cols == v.sent_cols and v.want_rows == v.sent_rows) return;
        if (v.server.control == null) return;
        v.sent_cols = v.want_cols;
        v.sent_rows = v.want_rows;
        v.server.fitBlock(v.session_id, v.block_id, v.want_cols, v.want_rows, @intFromFloat(@round(v.cell_w)), @intFromFloat(v.cell_h));
    }

    /// Forgets the size sent, so the next call sends it again, such as after reconnecting.
    pub fn resendSize(v: *TermView) void {
        v.sent_cols = 0;
        v.sent_rows = 0;
        v.sendSize();
    }

    // Input.

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, v: *TermView) callconv(.c) c_int {
        if (keys.isModifier(keyval)) return 0;
        const bits: u32 = @bitCast(state);
        const mods = keys.modsFromGdk(bits);
        // Ctrl+Shift+C and V copy and paste, like other Linux terminals.
        if (mods == keys.ctrl | keys.shift) {
            if (keyval == 'V' or keyval == 'v') {
                v.pasteClipboard();
                return 1;
            }
            if (keyval == 'C' or keyval == 'c') {
                v.copySelection(false);
                return 1;
            }
        }
        // Ctrl with plus, minus or 0 sizes this pane's text, as in other terminals.
        if (mods & ~@as(u4, keys.shift) == keys.ctrl) switch (keyval) {
            '+', '=', 0xffab => {
                v.zoomBy(1);
                return 1;
            },
            '-', 0xffad => {
                v.zoomBy(-1);
                return 1;
            },
            '0', 0xffb0 => {
                v.zoomBy(0);
                return 1;
            },
            else => {},
        };
        if (mods & keys.super != 0) return 0; // leave shortcuts to the desktop
        const key = keys.fromGdk(keyval, gdk.keyvalToUnicode(keyval), mods) orelse return 0;
        v.scrollToBottom();
        if (v.term()) |t| t.clearSelection();
        v.server.sendKey(v.session_id, v.block_id, key);
        return 1;
    }

    /// Text from the input method: plain typing, a composed é, or a word from an input method.
    fn onCommit(_: *gtk.IMContext, text: [*:0]const u8, v: *TermView) callconv(.c) void {
        const t = std.mem.span(text);
        v.scrollToBottom();
        if (v.term()) |tm| tm.clearSelection();
        const view = std.unicode.Utf8View.init(t) catch return v.server.paste(v.session_id, v.block_id, t);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| v.server.sendKey(v.session_id, v.block_id, keys.forChar(cp, 0));
    }

    pub fn pasteClipboard(v: *TermView) void {
        const clipboard = v.widget().getClipboard();
        // The view could be gone when the text arrives, so carry the ids instead.
        const ids = gpa.create(PasteTarget) catch return;
        ids.* = .{
            .server = v.server,
            .session_id = gpa.dupe(u8, v.session_id) catch return,
            .block_id = gpa.dupe(u8, v.block_id) catch return,
        };
        clipboard.readTextAsync(null, &pasted, ids);
    }

    const PasteTarget = struct { server: *Server, session_id: []u8, block_id: []u8 };

    fn pasted(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const t: *PasteTarget = @ptrCast(@alignCast(data.?));
        defer {
            gpa.free(t.session_id);
            gpa.free(t.block_id);
            gpa.destroy(t);
        }
        const clipboard: *gdk.Clipboard = @ptrCast(source orelse return);
        const text = clipboard.readTextFinish(result, null) orelse return;
        defer glib.free(text);
        t.server.paste(t.session_id, t.block_id, std.mem.span(text));
    }

    fn onScroll(ctl: *gtk.EventControllerScroll, _: f64, dy: f64, v: *TermView) callconv(.c) c_int {
        const st = v.stream() orelse return 0;
        const t = st.term orelse return 0;
        // Ctrl and the wheel size the text.
        const bits: u32 = @bitCast(ctl.as(gtk.EventController).getCurrentEventState());
        if (keys.modsFromGdk(bits) & keys.ctrl != 0) {
            if (dy != 0) v.zoomBy(if (dy < 0) 1 else -1);
            return 1;
        }
        // Programs that take the mouse, or use the whole screen, scroll themselves.
        if (t.frame.mouse or t.frame.alt_screen) {
            v.scroll_rest += dy;
            const lines = @trunc(v.scroll_rest);
            if (lines == 0) return 1;
            v.scroll_rest -= lines;
            v.server.sendWheel(v.session_id, v.block_id, lines, 0, 0);
            return 1;
        }
        v.scroll_velocity = 0;
        if (ctl.getUnit() == .surface) {
            // A touchpad reports pixels: follow the fingers exactly.
            v.scroll_px -= dy;
            v.scroll_target = v.scroll_px;
        } else {
            // A wheel notch glides three lines.
            v.scroll_target = v.scroll_target - dy * 3 * v.cell_h;
        }
        v.clampScroll();
        v.startScrollTick();
        v.widget().queueDraw();
        return 1;
    }

    /// A touchpad flick carries on, slowing down.
    fn onDecelerate(_: *gtk.EventControllerScroll, _: f64, vy: f64, v: *TermView) callconv(.c) void {
        const t = v.term() orelse return;
        if (t.frame.mouse or t.frame.alt_screen) return;
        v.scroll_velocity = -vy;
        v.startScrollTick();
    }

    fn maxScroll(v: *TermView) f64 {
        const t = v.term() orelse return 0;
        return @as(f64, @floatFromInt(t.frame.scroll_total -| t.frame.scroll_len)) * v.cell_h;
    }

    fn clampScroll(v: *TermView) void {
        const max = v.maxScroll();
        v.scroll_target = std.math.clamp(v.scroll_target, 0, max);
        v.scroll_px = std.math.clamp(v.scroll_px, 0, max);
    }

    fn startScrollTick(v: *TermView) void {
        if (v.scroll_tick != 0) return;
        v.last_frame_us = 0;
        v.scroll_tick = v.widget().addTickCallback(&scrollTick, v, null);
    }

    fn scrollTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        const now = clock.getFrameTime();
        const dt: f64 = if (v.last_frame_us == 0) 1.0 / 60.0 else @min(0.05, @as(f64, @floatFromInt(now - v.last_frame_us)) / 1e6);
        v.last_frame_us = now;
        if (v.scroll_velocity != 0) {
            v.scroll_px += v.scroll_velocity * dt;
            v.scroll_target = v.scroll_px;
            v.scroll_velocity *= std.math.pow(f64, 0.05, dt);
            if (@abs(v.scroll_velocity) < 15) v.scroll_velocity = 0;
        } else {
            // Ease toward the target, quickly at first.
            const gap = v.scroll_target - v.scroll_px;
            v.scroll_px += gap * (1 - std.math.pow(f64, 0.0005, dt));
            if (@abs(gap) < 0.5) v.scroll_px = v.scroll_target;
        }
        v.clampScroll();
        v.widget().queueDraw();
        if (v.scroll_velocity == 0 and v.scroll_px == v.scroll_target) {
            v.scroll_tick = 0;
            return 0;
        }
        return 1;
    }

    /// Output that arrives while looking back through history shouldn't move what's shown.
    fn followOutput(v: *TermView, total: u64) void {
        if (total > v.last_total and v.scroll_px > 0 and v.last_total > 0) {
            const grown = @as(f64, @floatFromInt(total - v.last_total)) * v.cell_h;
            v.scroll_px += grown;
            v.scroll_target += grown;
        }
        v.last_total = total;
    }

    /// Scrolls as a wheel would, by `dy` notches; for the development script.
    pub fn scrollBy(v: *TermView, dy: f64) void {
        v.scroll_target -= dy * 3 * v.cell_h;
        v.clampScroll();
        v.startScrollTick();
    }

    /// Back to the live screen, such as when typing.
    pub fn scrollToBottom(v: *TermView) void {
        v.scroll_px = 0;
        v.scroll_target = 0;
        v.scroll_velocity = 0;
        if (v.term()) |t| t.scrollToBottom();
    }

    fn cellAt(v: *TermView, x: f64, y: f64) struct { u16, u16 } {
        const col = @max(0, @floor((x - pad) / v.cell_w));
        const row = @max(0, @floor((y - pad - v.draw_frac) / v.cell_h));
        return .{ @intFromFloat(@min(col, 65535)), @intFromFloat(@min(row, 65535)) };
    }

    fn buttonName(gesture: *gtk.GestureClick) []const u8 {
        return switch (gesture.as(gtk.GestureSingle).getCurrentButton()) {
            1 => "left",
            2 => "middle",
            3 => "right",
            else => "left",
        };
    }

    fn modsNow(gesture: anytype) u4 {
        const ev = gesture.as(gtk.EventController);
        const bits: u32 = @bitCast(ev.getCurrentEventState());
        return keys.modsFromGdk(bits);
    }

    /// Whether clicks go to the program: it asked for the mouse, and Shift isn't held to select.
    fn programHasMouse(v: *TermView, mods: u4) bool {
        const t = v.term() orelse return false;
        return t.frame.mouse and mods & keys.shift == 0;
    }

    fn onPressed(gesture: *gtk.GestureClick, n_press: c_int, x: f64, y: f64, v: *TermView) callconv(.c) void {
        _ = v.widget().grabFocus();
        if (v.on_focus) |f| f.f(f.ctx, v.block_id);
        const t = v.term() orelse return;
        const mods = modsNow(gesture);
        const cell = v.cellAt(x, y);
        const button = gesture.as(gtk.GestureSingle).getCurrentButton();
        if (v.programHasMouse(mods)) {
            v.held_button = buttonName(gesture);
            v.last_motion = cell;
            v.server.sendMouse(v.session_id, v.block_id, "press", v.held_button, cell[0], cell[1]);
            return;
        }
        if (button == 2) return v.pastePrimary();
        if (button == 3) return v.openMenu(x, y);
        if (button != 1) return;
        if (mods & keys.shift != 0 and n_press == 1) {
            if (t.extendSelection(cell[0], cell[1])) {
                v.copySelection(true);
                v.selecting = true;
                v.widget().queueDraw();
            }
            return;
        }
        if (n_press == 2) {
            t.selectWord(cell[0], cell[1]);
            v.copySelection(true);
            v.widget().queueDraw();
        } else if (n_press == 3) {
            t.selectRange(0, cell[1], t.frame.cols -| 1, cell[1]);
            v.copySelection(true);
            v.widget().queueDraw();
        }
    }

    fn onReleased(gesture: *gtk.GestureClick, n_press: c_int, x: f64, y: f64, v: *TermView) callconv(.c) void {
        const t = v.term() orelse return;
        const mods = modsNow(gesture);
        const cell = v.cellAt(x, y);
        if (v.programHasMouse(mods)) {
            v.server.sendMouse(v.session_id, v.block_id, "release", buttonName(gesture), cell[0], cell[1]);
            return;
        }
        if (gesture.as(gtk.GestureSingle).getCurrentButton() != 1 or n_press != 1 or v.selecting) return;
        // Ctrl+click opens a link; a plain click drops the selection.
        if (mods & keys.ctrl != 0) {
            if (v.linkAt(t, cell[0], cell[1])) |url| {
                defer gpa.free(url);
                const launcher = gtk.UriLauncher.new(url.ptr);
                launcher.launch(@ptrCast(@alignCast(v.widget().getRoot())), null, null, null);
                return;
            }
        }
        t.clearSelection();
        v.widget().queueDraw();
    }

    /// The link at a cell: an OSC 8 hyperlink, or a web address written in the text.
    fn linkAt(v: *TermView, t: *term_mod.Term, col: u16, row: u16) ?[:0]u8 {
        _ = v;
        if (t.hyperlinkAt(col, row)) |u| return u;
        const f = &t.frame;
        var rows: std.ArrayList([]u21) = .empty;
        defer {
            for (rows.items) |r| gpa.free(r);
            rows.deinit(gpa);
        }
        for (0..f.rows) |y| {
            const r = gpa.alloc(u21, f.cols) catch return null;
            for (0..f.cols) |x| {
                const cp = f.cell(x, y).cp;
                r[x] = if (cp == 0 or cp > 0x10ffff) ' ' else @intCast(cp);
            }
            rows.append(gpa, r) catch return null;
        }
        const casted: []const []const u21 = @ptrCast(rows.items);
        var link = (links.at(gpa, casted, col, row) catch return null) orelse return null;
        defer link.deinit(gpa);
        return gpa.dupeSentinel(u8, link.url, 0) catch null;
    }

    fn onDragBegin(gesture: *gtk.GestureDrag, x: f64, y: f64, v: *TermView) callconv(.c) void {
        v.selecting = false;
        v.drag_to_program = v.programHasMouse(modsNow(gesture));
        v.drag_origin = .{ x, y };
        const cell = v.cellAt(x, y);
        v.anchor = .{ cell[0], cell[1] };
    }

    fn onDragUpdate(gesture: *gtk.GestureDrag, dx: f64, dy: f64, v: *TermView) callconv(.c) void {
        const x = v.drag_origin[0] + dx;
        const y = v.drag_origin[1] + dy;
        if (v.drag_to_program) {
            // Programs that take the mouse see the drag, one report per cell.
            const cell = v.cellAt(x, y);
            if (cell[0] == v.last_motion[0] and cell[1] == v.last_motion[1]) return;
            v.last_motion = cell;
            v.server.sendMouse(v.session_id, v.block_id, "motion", v.held_button, cell[0], cell[1]);
            return;
        }
        if (gesture.as(gtk.GestureSingle).getCurrentButton() != 1) return;
        if (!v.selecting and @abs(dx) < 4 and @abs(dy) < 4) return;
        const t = v.term() orelse return;
        const first = !v.selecting;
        v.selecting = true;
        v.edge_point = .{ x, y };
        v.extendTo(t, x, y, first);
        // Past the top or bottom edge, the view scrolls to keep selecting.
        const h: f64 = @floatFromInt(v.widget().getHeight());
        v.edge_scroll = if (y < 0) @max(-4, y / 24) else if (y > h) @min(4, (y - h) / 24) else 0;
        if (v.edge_scroll != 0 and v.edge_timer == 0) v.edge_timer = glib.timeoutAdd(50, &edgeTick, v);
    }

    fn extendTo(v: *TermView, t: *term_mod.Term, x: f64, y: f64, first: bool) void {
        const cell = v.cellAt(x, @max(pad, y));
        const last_col = t.frame.cols -| 1;
        const last_row = t.frame.rows -| 1;
        const cx = @min(cell[0], last_col);
        const cy = @min(cell[1], last_row);
        if (first) {
            t.selectRange(@min(v.anchor[0], last_col), @min(v.anchor[1], last_row), cx, cy);
        } else if (!t.extendSelection(cx, cy)) {
            t.selectRange(@min(v.anchor[0], last_col), @min(v.anchor[1], last_row), cx, cy);
        }
        v.widget().queueDraw();
    }

    fn edgeTick(data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        if (v.edge_scroll == 0 or !v.selecting) {
            v.edge_timer = 0;
            return 0;
        }
        const t = v.term() orelse return 1;
        // Up into history, or back down; the selection's start stays pinned to its text.
        v.scroll_px = std.math.clamp(v.scroll_px - v.edge_scroll * v.cell_h, 0, v.maxScroll());
        v.scroll_target = v.scroll_px;
        _ = t.render(true);
        const rows_up = @floor(v.scroll_px / v.cell_h);
        const current_up: f64 = @floatFromInt(t.frame.scroll_total -| t.frame.scroll_len -| t.frame.scroll_offset);
        if (current_up != rows_up) {
            t.scroll(@intFromFloat(current_up - rows_up));
            _ = t.render(true);
        }
        const h: f64 = @floatFromInt(v.widget().getHeight());
        v.extendTo(t, v.edge_point[0], std.math.clamp(v.edge_point[1], 0, h - 1), false);
        return 1;
    }

    fn onDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, v: *TermView) callconv(.c) void {
        v.edge_scroll = 0;
        if (v.selecting) v.copySelection(true);
        // The release that ends a drag also reaches the click gesture, which checks this.
        const Later = struct {
            fn run(data: ?*anyopaque) callconv(.c) c_int {
                const tv: *TermView = @ptrCast(@alignCast(data.?));
                tv.selecting = false;
                return 0;
            }
        };
        _ = glib.idleAdd(&Later.run, v);
    }

    /// The right-click menu: copy, paste, a link under the pointer, and this pane's layout.
    fn openMenu(v: *TermView, x: f64, y: f64) void {
        const t = v.term() orelse return;
        if (v.menu_link) |l| gpa.free(l);
        const cell = v.cellAt(x, y);
        v.menu_link = v.linkAt(t, cell[0], cell[1]);
        const sel = t.selectionText();
        defer if (sel) |s_| gpa.free(s_);
        if (v.menu == null) {
            const group = gio.SimpleActionGroup.new();
            inline for (.{ .{ "copy", menuCopy }, .{ "paste", menuPaste }, .{ "open-link", menuOpenLink }, .{ "copy-link", menuCopyLink } }) |e| {
                const action = gio.SimpleAction.new(e[0], null);
                const Thunk = struct {
                    fn run(_: *gio.SimpleAction, _: ?*glib.Variant, tv: *TermView) callconv(.c) void {
                        e[1](tv);
                    }
                };
                _ = gio.SimpleAction.signals.activate.connect(action, *TermView, &Thunk.run, v, .{});
                group.as(gio.ActionMap).addAction(action.as(gio.Action));
            }
            v.widget().insertActionGroup("pane", group.as(gio.ActionGroup));
        }
        const menu = gio.Menu.new();
        const edit = gio.Menu.new();
        if (sel != null) edit.append("Copy", "pane.copy");
        edit.append("Paste", "pane.paste");
        menu.appendSection(null, edit.as(gio.MenuModel));
        if (v.menu_link != null) {
            const link = gio.Menu.new();
            link.append("Open Link", "pane.open-link");
            link.append("Copy Link", "pane.copy-link");
            menu.appendSection(null, link.as(gio.MenuModel));
        }
        const layout = gio.Menu.new();
        const target = gpa.dupeSentinel(u8, v.block_id, 0) catch return;
        defer gpa.free(target);
        inline for (.{ .{ "Split Right", "app.pane-split-right" }, .{ "Split Down", "app.pane-split-down" }, .{ "Float or Dock", "app.pane-float" }, .{ "Zoom", "app.pane-zoom" }, .{ "Close Pane", "app.pane-close" } }) |e| {
            const item = gio.MenuItem.new(e[0], null);
            item.setActionAndTargetValue(e[1], glib.Variant.newString(target.ptr));
            layout.appendItem(item);
        }
        menu.appendSection(null, layout.as(gio.MenuModel));
        if (v.menu) |old| old.as(gtk.Widget).unparent();
        const pop = gtk.PopoverMenu.newFromModel(menu.as(gio.MenuModel));
        pop.as(gtk.Widget).setParent(v.widget());
        pop.as(gtk.Popover).setHasArrow(0);
        const r: gdk.Rectangle = .{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
        pop.as(gtk.Popover).setPointingTo(&r);
        pop.as(gtk.Popover).popup();
        v.menu = pop;
    }

    /// For the development script.
    pub fn showMenuAt(v: *TermView, x: f64, y: f64) void {
        v.openMenu(x, y);
    }

    fn menuCopy(v: *TermView) void {
        v.copySelection(false);
    }

    fn menuPaste(v: *TermView) void {
        v.pasteClipboard();
    }

    fn menuOpenLink(v: *TermView) void {
        const l = v.menu_link orelse return;
        const launcher = gtk.UriLauncher.new(l.ptr);
        launcher.launch(@ptrCast(@alignCast(v.widget().getRoot())), null, null, null);
    }

    fn menuCopyLink(v: *TermView) void {
        const l = v.menu_link orelse return;
        v.widget().getClipboard().setText(l.ptr);
    }

    /// Copies the selection to the clipboard, or to the primary selection that middle-click pastes.
    pub fn copySelection(v: *TermView, primary: bool) void {
        const t = v.term() orelse return;
        const text = t.selectionText() orelse return;
        defer gpa.free(text);
        const clipboard = if (primary) v.widget().getPrimaryClipboard() else v.widget().getClipboard();
        clipboard.setText(text.ptr);
    }

    fn pastePrimary(v: *TermView) void {
        const clipboard = v.widget().getPrimaryClipboard();
        const ids = gpa.create(PasteTarget) catch return;
        ids.* = .{
            .server = v.server,
            .session_id = gpa.dupe(u8, v.session_id) catch return,
            .block_id = gpa.dupe(u8, v.block_id) catch return,
        };
        clipboard.readTextAsync(null, &pasted, ids);
    }

    fn onFocusIn(_: *gtk.EventControllerFocus, v: *TermView) callconv(.c) void {
        v.im.as(gtk.IMContext).focusIn();
        v.server.sendFocus(v.session_id, v.block_id, true);
        v.widget().queueDraw();
    }

    fn onFocusOut(_: *gtk.EventControllerFocus, v: *TermView) callconv(.c) void {
        v.im.as(gtk.IMContext).focusOut();
        v.server.sendFocus(v.session_id, v.block_id, false);
        v.widget().queueDraw();
    }
};

// Drawing.

fn setColor(cr: *cairo.Context, color: u32, alpha: f64) void {
    const r: f64 = @floatFromInt((color >> 16) & 0xff);
    const g: f64 = @floatFromInt((color >> 8) & 0xff);
    const b: f64 = @floatFromInt(color & 0xff);
    cr.setSourceRgba(r / 255, g / 255, b / 255, alpha);
}

fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const v: *TermView = @ptrCast(@alignCast(data.?));
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const st = v.stream() orelse return drawEmpty(cr, w, h, "Closed");
    const t = st.term orelse return drawEmpty(cr, w, h, switch (st.state) {
        .closed => "This pane has closed",
        else => "Connecting…",
    });
    _ = t.render(true);
    const f = &t.frame;
    const f_font = v.fontOf() orelse return;

    setColor(cr, f.bg, 1);
    cr.rectangle(0, 0, w, h);
    cr.fill();

    // The widget's own Pango context, the one the cell size was measured with, so runs of text
    // advance exactly one cell per character.
    const layout = v.widget().createPangoLayout(null);
    defer layout.as(gobject.Object).unref();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);

    // Smooth scrolling: the view sits a fraction of a row lower than the viewport while partway
    // into history, and the row above the viewport fills the gap at the top.
    const max_up: f64 = @floatFromInt(f.scroll_total -| f.scroll_len);
    v.followOutput(f.scroll_total);
    v.scroll_px = std.math.clamp(v.scroll_px, 0, max_up * v.cell_h);
    const rows_up = @floor(v.scroll_px / v.cell_h);
    const frac = v.scroll_px - rows_up * v.cell_h;
    v.draw_frac = frac;
    const current_up: f64 = @floatFromInt(f.scroll_total -| f.scroll_len -| f.scroll_offset);
    if (current_up != rows_up) {
        t.scroll(@intFromFloat(current_up - rows_up));
        _ = t.render(true);
    }
    if (frac > 0.01 and rows_up < max_up) {
        t.scroll(-1);
        _ = t.render(true);
        drawRow(v, cr, t, &t.frame, layout, &text, f_font, 0, pad + frac - v.cell_h);
        t.scroll(1);
        _ = t.render(true);
    }
    var y: usize = 0;
    while (y < f.rows) : (y += 1) {
        const top = pad + frac + @as(f64, @floatFromInt(y)) * v.cell_h;
        if (top > h) break;
        drawRow(v, cr, t, f, layout, &text, f_font, y, top);
    }

    // Input methods place their candidate popup by the cursor.
    {
        var r: gdk.Rectangle = .{
            .f_x = @intFromFloat(pad + @as(f64, @floatFromInt(f.cursor_x)) * v.cell_w),
            .f_y = @intFromFloat(pad + v.draw_frac + @as(f64, @floatFromInt(f.cursor_y)) * v.cell_h),
            .f_width = @intFromFloat(v.cell_w),
            .f_height = @intFromFloat(v.cell_h),
        };
        v.im.as(gtk.IMContext).setCursorLocation(&r);
    }

    // The cursor, hollow when the pane doesn't have the keyboard.
    if (f.cursor_visible and f.cursor_y < f.rows and f.cursor_x < f.cols and f.scroll_offset + f.scroll_len >= f.scroll_total) {
        const cx = pad + @as(f64, @floatFromInt(f.cursor_x)) * v.cell_w;
        const cy = pad + @as(f64, @floatFromInt(f.cursor_y)) * v.cell_h;
        const color = if (f.cursor_color != 0) f.cursor_color else f.fg;
        setColor(cr, color, 1);
        const focused = v.widget().hasFocus() != 0;
        const prefs = &@import("settings.zig").current;
        const style: c_int = switch (prefs.cursor_style) {
            .program => f.cursor_style,
            .bar => 0,
            .block => 1,
            .underline => 2,
        };
        const blinks = prefs.cursor_blink and focused;
        const under = f.cell(f.cursor_x, f.cursor_y);
        const cw = v.cell_w * @as(f64, if (under.flags.wide) 2 else 1);
        if (blinks and !blink_on) {
            // The hidden half of a blink.
        } else if (!focused or style == 3) {
            cr.setLineWidth(1);
            cr.rectangle(cx + 0.5, cy + 0.5, cw - 1, v.cell_h - 1);
            cr.stroke();
        } else switch (style) {
            0 => {
                cr.rectangle(cx, cy, 2, v.cell_h);
                cr.fill();
            },
            2 => {
                cr.rectangle(cx, cy + v.cell_h - 2, cw, 2);
                cr.fill();
            },
            else => {
                cr.rectangle(cx, cy, cw, v.cell_h);
                cr.fill();
                // The character under a block cursor, in the background color.
                if (under.cp != 0 and under.cp != ' ') {
                    text.clearRetainingCapacity();
                    appendCell(&text, f, under);
                    text.append(gpa, 0) catch return;
                    layout.setFontDescription(f_font.pick(under.flags));
                    layout.setText(@ptrCast(text.items.ptr), @intCast(text.items.len - 1));
                    setColor(cr, f.bg, 1);
                    showOnBaseline(cr, layout, cx, cy + v.baseline);
                }
            },
        }
    }

    // A thin scroll position marker while looking back through history.
    if (f.scroll_total > f.scroll_len and f.scroll_offset + f.scroll_len < f.scroll_total) {
        const total: f64 = @floatFromInt(f.scroll_total);
        const bar_h = @max(24, h * @as(f64, @floatFromInt(f.scroll_len)) / total);
        const bar_y = (h - bar_h) * @as(f64, @floatFromInt(f.scroll_offset)) / @max(1, total - @as(f64, @floatFromInt(f.scroll_len)));
        setColor(cr, f.fg, 0.35);
        cr.rectangle(w - 5, bar_y, 3, bar_h);
        cr.fill();
    }
}

/// Draws one row of the frame with its top at `top`: backgrounds, search matches, then text.
fn drawRow(v: *TermView, cr: *cairo.Context, t: *term.Term, f: *const term.Frame, layout: *pango.Layout, text: *std.ArrayList(u8), f_font: Font, y: usize, top: f64) void {
    // Backgrounds first, so wide glyphs can overhang into the next cell.
    var x: usize = 0;
    while (x < f.cols) : (x += 1) {
        const cl = f.cell(x, y);
        const colors = cellColors(f, cl);
        if (colors.bg == f.bg) continue;
        const span: f64 = if (cl.flags.wide) 2 else 1;
        setColor(cr, colors.bg, 1);
        cr.rectangle(pad + @as(f64, @floatFromInt(x)) * v.cell_w, top, v.cell_w * span + 0.5, v.cell_h);
        cr.fill();
    }
    // Search matches, under the text.
    if (t.finding()) {
        var found: [128]term.Match = undefined;
        const n = t.matches(&found);
        for (found[0..n]) |m| {
            if (m.y0 > y or m.y1 < y) continue;
            const from: usize = if (m.y0 == y) m.x0 else 0;
            const to: usize = if (m.y1 == y) m.x1 else f.cols -| 1;
            setColor(cr, if (m.selected) 0xffb020 else 0xd8b040, if (m.selected) 0.75 else 0.35);
            cr.rectangle(pad + @as(f64, @floatFromInt(from)) * v.cell_w, top, @as(f64, @floatFromInt(to - from + 1)) * v.cell_w, v.cell_h);
            cr.fill();
        }
    }
    // Then text, in runs of one style. Anything outside ASCII is placed on its own cell,
    // since fallback fonts don't keep to the grid.
    x = 0;
    while (x < f.cols) {
        const cl = f.cell(x, y);
        if (cl.cp == 0 or cl.cp == ' ' or cl.flags.spacer or cl.flags.invisible) {
            x += 1;
            continue;
        }
        if (boxdraw.handles(cl.cp)) {
            setColor(cr, cellColors(f, cl).fg, if (cl.flags.faint) 0.6 else 1);
            boxdraw.draw(cr, cl.cp, pad + @as(f64, @floatFromInt(x)) * v.cell_w, top, v.cell_w, v.cell_h);
            x += 1;
            continue;
        }
        const start = x;
        const colors = cellColors(f, cl);
        text.clearRetainingCapacity();
        while (x < f.cols) {
            const n = f.cell(x, y);
            if (x > start) {
                if (n.cp >= 0x80 or n.cp == 0 or n.flags.spacer or boxdraw.handles(n.cp) or !sameStyle(cl, n) or cellColors(f, n).fg != colors.fg) break;
            }
            appendCell(text, f, n);
            x += if (n.flags.wide) 2 else 1;
            if (n.cp >= 0x80) break;
        }
        const left = pad + @as(f64, @floatFromInt(start)) * v.cell_w;
        layout.setFontDescription(f_font.pick(cl.flags));
        text.append(gpa, 0) catch break;
        layout.setText(@ptrCast(text.items.ptr), @intCast(text.items.len - 1));
        setColor(cr, colors.fg, if (cl.flags.faint) 0.6 else 1);
        showOnBaseline(cr, layout, left, top + v.baseline);
        const run_w = @as(f64, @floatFromInt(x - start)) * v.cell_w;
        if (cl.flags.underline or cl.flags.link) {
            cr.rectangle(left, top + v.baseline + 1.5, run_w, 1);
            cr.fill();
        }
        if (cl.flags.strike) {
            cr.rectangle(left, top + v.cell_h / 2, run_w, 1);
            cr.fill();
        }
    }
}

/// Draws a layout with its baseline at `baseline`. Fallback fonts have other ascents, so
/// placing by the top would put their glyphs at the wrong height.
fn showOnBaseline(cr: *cairo.Context, layout: *pango.Layout, x: f64, baseline: f64) void {
    const own = @as(f64, @floatFromInt(layout.getBaseline())) / pango.SCALE;
    cr.moveTo(x, baseline - own);
    pangocairo.showLayout(cr, layout);
}

fn drawEmpty(cr: *cairo.Context, w: f64, h: f64, message: [:0]const u8) void {
    cr.setSourceRgb(0.1, 0.1, 0.12);
    cr.rectangle(0, 0, w, h);
    cr.fill();
    const f = font orelse return;
    const layout = pangocairo.createLayout(cr);
    defer layout.as(gobject.Object).unref();
    layout.setFontDescription(f.regular);
    layout.setText(message.ptr, @intCast(message.len));
    var lw: c_int = 0;
    var lh: c_int = 0;
    layout.getPixelSize(&lw, &lh);
    cr.setSourceRgba(1, 1, 1, 0.45);
    cr.moveTo((w - @as(f64, @floatFromInt(lw))) / 2, (h - @as(f64, @floatFromInt(lh))) / 2);
    pangocairo.showLayout(cr, layout);
}

const Colors = struct { fg: u32, bg: u32 };

fn cellColors(f: *const term.Frame, cl: term.Cell) Colors {
    var fg = if (cl.fg != 0) cl.fg else f.fg;
    var bg = if (cl.bg != 0) cl.bg else f.bg;
    if (cl.flags.inverse) std.mem.swap(u32, &fg, &bg);
    if (cl.flags.selected) std.mem.swap(u32, &fg, &bg);
    return .{ .fg = fg, .bg = bg };
}

fn sameStyle(a: term.Cell, b: term.Cell) bool {
    return a.flags.bold == b.flags.bold and a.flags.italic == b.flags.italic and a.flags.faint == b.flags.faint and
        a.flags.underline == b.flags.underline and a.flags.strike == b.flags.strike and a.flags.link == b.flags.link;
}

fn appendCell(text: *std.ArrayList(u8), f: *const term.Frame, cl: term.Cell) void {
    var buf: [4]u8 = undefined;
    if (cl.extra_len > 1) {
        for (f.grapheme(cl)) |cp| {
            const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
            text.appendSlice(gpa, buf[0..n]) catch {};
        }
        return;
    }
    const n = std.unicode.utf8Encode(@intCast(cl.cp), &buf) catch return;
    text.appendSlice(gpa, buf[0..n]) catch {};
}
