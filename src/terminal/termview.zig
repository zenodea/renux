//! A terminal pane: draws a block's frame through GTK's snapshot, row by row, and sends typing,
//! clicks and scrolling to the server. It finds its stream by block id each time, since the server may end
//! the stream (when the block closes) while the pane still exists.
const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");
const gdk = @import("gdk");
const cairo = @import("cairo");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const gsk = @import("gsk");
const graphene = @import("graphene");
const keys = @import("keys.zig");
// Not `term`: inside TermView that name is the method that finds the pane's terminal.
const term_mod = @import("term.zig");
const Server = @import("../rex/server.zig").Server;
const Binding = @import("../rex/server.zig").Binding;
const Stream = @import("../rex/stream.zig").Stream;
const boxdraw = @import("boxdraw.zig");
const links = @import("links.zig");
const programs = @import("../icons/programs.zig");
const settings = @import("../settings/settings.zig");
const shader = @import("shader.zig");
const fonts = @import("fonts.zig");

const gpa = std.heap.c_allocator;

/// The space around the text, from the settings.
pub var pad_x: f64 = 8;
pub var pad_y: f64 = 8;
/// The theme's own background, for padding drawn in the theme's color.
pub var theme_bg: u32 = 0;
const size_debounce_ms = 200;

pub const Font = struct {
    regular: *pango.FontDescription,
    bold: *pango.FontDescription,
    italic: *pango.FontDescription,
    bold_italic: *pango.FontDescription,
    /// What the font is (family, size, style), for telling drawings made with another font apart.
    id: u64,

    pub fn init(name: [:0]const u8) Font {
        const desc = pango.FontDescription.fromString(name.ptr);
        // Nerd Font icons fall back to the symbols that come with Renux, unless the font has them.
        if (fonts.registered) if (desc.getFamily()) |fam| {
            const family = std.mem.span(fam);
            if (std.mem.indexOf(u8, family, "Nerd") == null) {
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrintSentinel(&buf, "{s},{s}", .{ family, fonts.symbols_family }, 0)) |both| desc.setFamily(both.ptr) else |_| {}
            }
        };
        return fromDesc(desc);
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
        return .{ .regular = regular, .bold = bold, .italic = italic, .bold_italic = bold_italic, .id = regular.hash() };
    }

    /// Frees the four descriptions. Layouts copy what they're given, so nothing else holds them.
    pub fn deinit(f: *Font) void {
        f.regular.free();
        f.bold.free();
        f.italic.free();
        f.bold_italic.free();
        f.* = undefined;
    }

    fn pick(f: Font, flags: term_mod.Flags) *pango.FontDescription {
        if (settings.current.bold_italic == .plain) return f.regular;
        if (flags.bold and flags.italic) return f.bold_italic;
        if (flags.bold) return f.bold;
        if (flags.italic) return f.italic;
        return f.regular;
    }
};

pub var font: ?Font = null;
/// The theme's accent as 0xRRGGBB, which the cursor takes unless a program sets its own.
pub var cursor_accent: u32 = 0;
/// How opaque a terminal's own background is.
pub var term_opacity: f64 = 1;
/// Set while the sidebar's edge is being dragged: panes keep the size their programs have, so
/// text isn't laid out again at every step of the drag, and take the new size once at the end.
pub var hold_sizes: bool = false;

/// How many panes are animating a scroll, for RENUX_PERF.
pub var scroll_ticking: u32 = 0;

/// The terminal's own widget. It draws through GTK's snapshot, so text goes to the GPU's glyph
/// cache, and each row's drawing is kept until that row changes.
const Canvas = extern struct {
    parent_instance: Parent,
    view: ?*TermView,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "RenuxTerminal",
        .classInit = &Class.init,
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn snapshot(self: *Self, sn: *gtk.Snapshot) callconv(.c) void {
        const v = self.view orelse return;
        // The shader's view shows what this drew, so it draws again after this does.
        defer if (v.shader_view) |sv| sv.as(gtk.Widget).queueDraw();
        if (!shader.active()) {
            v.shader_drawn = false;
            return snapshotTermImpl(v, sn);
        }
        // Through a custom shader: the pane draws itself aside, that becomes the shader's
        // picture, and the shader's view over this one shows what the shader makes of it.
        const own = gtk.Snapshot.new();
        snapshotTermImpl(v, own);
        const node = own.freeToNode() orelse return;
        defer node.unref();
        v.shader_drawn = shader.updateInput(&v.shader_pane, self.as(gtk.Widget), node);
        if (!v.shader_drawn) sn.appendNode(node);
    }

    fn sizeAllocate(self: *Self, width: c_int, height: c_int, _: c_int) callconv(.c) void {
        if (self.view) |v| v.resized(width, height);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gtk.Widget.virtual_methods.size_allocate.implement(class, &sizeAllocate);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};

/// Where a custom shader's picture of the pane is shown, over the terminal's own widget. A
/// widget of its own, so a shader that moves with time redraws only this: GTK keeps the
/// terminal's drawing as it is, and the pane isn't drawn and read back again every frame.
const ShaderView = extern struct {
    parent_instance: Parent,
    view: ?*TermView,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "RenuxShaderView",
        .classInit = &Class.init,
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn snapshot(self: *Self, sn: *gtk.Snapshot) callconv(.c) void {
        const v = self.view orelse return;
        if (!v.shader_drawn or !shader.active()) return;
        const focused = v.widget().hasFocus() != 0;
        _ = shader.drawOutput(&v.shader_pane, &v.shader_look, focused, sn);
        // A shader that moves with time draws the pane with the keyboard again every frame, as
        // Ghostty does; the others keep their last frame until the pane changes.
        if (focused and v.shader_tick == 0 and shader.wantsFrames(&v.shader_pane)) v.shader_tick = self.as(gtk.Widget).addTickCallback(&shaderTick, v, null);
    }

    fn shaderTick(widget: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        widget.queueDraw();
        if (v.widget().hasFocus() != 0 and shader.wantsFrames(&v.shader_pane)) return 1;
        // One more frame is drawn, so a fading effect doesn't stay half done.
        v.shader_tick = 0;
        return 0;
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};

/// One row's drawing, kept while the row's contents stay the same.
const RowCache = struct { hash: u64 = 0, node: ?*gsk.RenderNode = null };
/// The Rex key mode the client is in, such as "resize", or empty. Keys go to its bindings.
pub var key_mode: [32]u8 = undefined;
pub var key_mode_len: usize = 0;
/// Told when the key mode changes, so the window can show it.
pub var on_mode_changed: ?*const fn () void = null;

pub fn setKeyMode(name: []const u8) void {
    const n = @min(name.len, key_mode.len);
    @memcpy(key_mode[0..n], name[0..n]);
    key_mode_len = n;
    if (on_mode_changed) |f| f();
}

/// The keys of a sequence typed so far, such as ctrl+a waiting for the next key.
var chord_keys: [4][40]u8 = undefined;
var chord_lens: [4]usize = .{ 0, 0, 0, 0 };
var chord_len: usize = 0;
/// Told when a sequence starts or ends, to show what's been typed.
pub var on_chord_changed: ?*const fn (pending: []const u8) void = null;

/// A key that can come next in the sequence typed so far, and what it runs. `more` means it
/// starts a longer sequence rather than running something itself.
pub const Hint = struct { key: []const u8, action: []const u8, args: ?[]const u8, more: bool };

/// The keys that can follow the sequence typed so far, from the config's bindings, each once.
pub fn nextKeys(binds: []const Binding, out: *std.ArrayList(Hint)) void {
    if (chord_len == 0) return;
    for (binds) |*b| {
        if (!continuesChord(b)) continue;
        const key = b.keys[chord_len];
        const more = b.keys.len > chord_len + 1;
        const dup = for (out.items) |*h| {
            if (keys.sameKey(h.key, key)) {
                if (!more) h.* = .{ .key = key, .action = b.action, .args = b.args, .more = false };
                break true;
            }
        } else false;
        if (!dup) out.append(gpa, .{ .key = key, .action = b.action, .args = b.args, .more = more }) catch return;
    }
}

/// Whether a binding starts with the keys typed so far and has at least one more.
fn continuesChord(b: *const Binding) bool {
    if (b.keys.len <= chord_len) return false;
    for (0..chord_len) |i| if (!keys.sameKey(b.keys[i], chord_keys[i][0..chord_lens[i]])) return false;
    return true;
}

fn chordChanged() void {
    const f = on_chord_changed orelse return;
    var buf: [180]u8 = undefined;
    var n: usize = 0;
    for (0..chord_len) |i| {
        const k = chord_keys[i][0..chord_lens[i]];
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n .. n + k.len], k);
        n += k.len;
    }
    f(buf[0..n]);
}

pub fn keyMode() []const u8 {
    return key_mode[0..key_mode_len];
}
/// Each pane's zoom, by block, so a pane keeps it when shown again.
var zooms: std.StringHashMapUnmanaged(f64) = .empty;
/// Whether a blinking cursor is in its visible half.
var blink_on = true;
/// The cursor blinks on a timer that only runs while a pane is drawing a blinking cursor: with
/// blinking off, no pane focused or the window hidden, nothing wakes the app up.
var blink_timer: c_uint = 0;
/// The pane whose cursor blinks, and whether it drew that cursor since the last tick.
var blink_view: ?*TermView = null;
var blink_drawn = false;

/// Called by the pane drawing a blinking cursor, which keeps the timer going.
fn blinkWanted(v: *TermView) void {
    blink_view = v;
    blink_drawn = true;
    if (blink_timer == 0) blink_timer = glib.timeoutAdd(@intFromFloat(std.math.clamp(settings.current.cursor_blink_ms, 50, 10_000)), &blinkTick, null);
}

fn blinkTick(_: ?*anyopaque) callconv(.c) c_int {
    // Nobody drew a blinking cursor since the last tick: stop until one is drawn again.
    if (!blink_drawn or blink_view == null) {
        blink_timer = 0;
        blink_on = true;
        return 0;
    }
    blink_drawn = false;
    blink_on = !blink_on;
    blink_view.?.widget().queueDraw();
    return 1;
}

/// Starts the blink over, such as when its interval changes. The next cursor drawn restarts it.
pub fn blinkReset() void {
    if (blink_timer != 0) _ = glib.Source.remove(blink_timer);
    blink_timer = 0;
    blink_on = true;
}

pub const TermView = struct {
    canvas: *Canvas,
    /// Row drawings by position in the view; the last slot is the partly shown row above it.
    rows_cache: std.ArrayList(RowCache) = .empty,
    /// The drawings of the frame before, which a row that only moved takes its drawing from.
    rows_prev: std.ArrayList(RowCache) = .empty,
    layout: ?*pango.Layout = null,
    /// The letter spacing the layout was given, in pixels.
    spacing: f64 = 0,
    /// Whether the pane floats over the others.
    floating: bool = false,
    /// Textures of the Kitty images this pane shows, by image and generation.
    textures: std.ArrayList(TextureEntry) = .empty,
    /// Whether this pane has the window's keyboard focus, for fading the others.
    active_pane: bool = true,
    /// The background the program last drew with, to tell the frame when it changes.
    last_bg: u32 = 0,
    on_bg: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, block_id: []const u8, bg: u32) void } = null,
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
    frozen: bool = false,
    flash_timer: c_uint = 0,
    drag_idle: c_uint = 0,
    /// Lines of scrolling not yet sent to a program that takes the mouse.
    scroll_rest: f64 = 0,
    /// How far up into history the view is, in pixels, where it's heading, and how fast a
    /// touchpad flick is still carrying it.
    scroll_px: f64 = 0,
    scroll_target: f64 = 0,
    scroll_velocity: f64 = 0,
    scroll_tick: c_uint = 0,
    /// The pane's textures for a custom shader, and the tick that redraws it while the shader
    /// moves with time.
    shader_pane: shader.Pane = .{},
    shader_tick: c_uint = 0,
    /// The widget over the terminal that shows the shader's picture, and whether the last
    /// drawing went through the shader at all.
    shader_view: ?*ShaderView = null,
    shader_drawn: bool = false,
    /// What the last drawing knew of the cursor and colors, for the shader.
    shader_look: shader.Look = .{},
    last_frame_us: i64 = 0,
    last_total: u64 = 0,
    draw_frac: f64 = 0,
    /// Where the pointer is over the pane, so the wheel scrolls what's under it.
    pointer: [2]f64 = .{ 0, 0 },
    /// Text an input method is still composing, shown at the cursor until it's committed.
    preedit: ?[:0]u8 = null,
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
    menu_cell: [2]u16 = .{ 0, 0 },
    /// Dragging the scroll position marker.
    dragging_bar: bool = false,
    /// When a bell flash fades out, in monotonic microseconds.
    flash_until: i64 = 0,
    /// Called when this pane is clicked, so the workspace can mark it focused.
    on_focus: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, block_id: []const u8) void } = null,
    /// Told when this pane's selection reaches the clipboard, to show that it did.
    on_copied: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, block_id: []const u8) void } = null,

    pub fn create(server: *Server, session_id: []const u8, block_id: []const u8) !*TermView {
        const v = try gpa.create(TermView);
        const canvas = Canvas.new();
        v.* = .{
            .canvas = canvas,
            .server = server,
            .session_id = try gpa.dupe(u8, session_id),
            .block_id = try gpa.dupe(u8, block_id),
        };
        const w = canvas.as(gtk.Widget);
        canvas.view = v;
        const sv = ShaderView.new();
        sv.view = v;
        sv.as(gtk.Widget).setCanTarget(0);
        v.shader_view = sv;
        w.setFocusable(1);
        w.setHexpand(1);
        w.setVexpand(1);
        w.setCursorFromName("text");
        _ = gtk.Widget.signals.destroy.connect(w, *TermView, &onDestroy, v, .{});

        const key = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(key, *TermView, &onKey, v, .{});
        // Typed text goes through the input method, so dead keys, compose sequences and input
        // methods for other scripts commit real text; other keys reach `onKey`.
        v.im = gtk.IMMulticontext.new();
        // The input method holds on to the widget it serves, so it's given the widget only while
        // the widget is on screen. Held for longer, the widget could never be freed once its
        // card went: the pane lived on, still hearing its terminal, and wrote titles into a
        // label that was gone, which crashed.
        _ = gtk.Widget.signals.realize.connect(w, *TermView, &onRealize, v, .{});
        _ = gtk.Widget.signals.unrealize.connect(w, *TermView, &onUnrealize, v, .{});
        _ = gtk.IMContext.signals.commit.connect(v.im.as(gtk.IMContext), *TermView, &onCommit, v, .{});
        // What's being composed (pinyin before a character is picked, a dead key's accent) is
        // drawn at the cursor, or the person would type blind until it commits.
        _ = gtk.IMContext.signals.preedit_changed.connect(v.im.as(gtk.IMContext), *TermView, &onPreedit, v, .{});
        _ = gtk.IMContext.signals.preedit_end.connect(v.im.as(gtk.IMContext), *TermView, &onPreedit, v, .{});
        key.setImContext(v.im.as(gtk.IMContext));
        w.addController(key.as(gtk.EventController));

        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.motion.connect(motion, *TermView, &onMotion, v, .{});
        w.addController(motion.as(gtk.EventController));

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

        // A file dropped on the pane is pasted as its path, quoted for the shell.
        const drop = gtk.DropTarget.new(gio.File.getGObjectType(), .{ .copy = true });
        _ = gtk.DropTarget.signals.drop.connect(drop, *TermView, &onDrop, v, .{});
        w.addController(drop.as(gtk.EventController));

        const focus = gtk.EventControllerFocus.new();
        _ = gtk.EventControllerFocus.signals.enter.connect(focus, *TermView, &onFocusIn, v, .{});
        _ = gtk.EventControllerFocus.signals.leave.connect(focus, *TermView, &onFocusOut, v, .{});
        w.addController(focus.as(gtk.EventController));

        if (zooms.get(block_id)) |z| v.setZoom(z);
        v.measure();
        if (server.terminal(session_id, block_id)) |st| st.addListener(.{ .ctx = v, .changed = changed });
        return v;
    }

    /// Stops this view telling the server about its size, for a card on its way out.
    pub fn freeze(v: *TermView) void {
        v.frozen = true;
        if (v.size_timer != 0) _ = glib.Source.remove(v.size_timer);
        v.size_timer = 0;
    }

    /// The custom shader's picture of the pane, laid over `widget`, which the card shows too.
    pub fn shaderWidget(v: *TermView) *gtk.Widget {
        return v.shader_view.?.as(gtk.Widget);
    }

    pub fn widget(v: *TermView) *gtk.Widget {
        return v.canvas.as(gtk.Widget);
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
        if (perf_log and key_at != 0 and echo_at == 0) echo_at = glib.getMonotonicTime();
        v.widget().queueDraw();
        v.updateTitle();
    }

    pub fn setTitleLabel(v: *TermView, label: *gtk.Label) void {
        // Held until the pane goes: the card can be taken apart before this view is, and a
        // title arriving in between would otherwise be written into a freed label.
        _ = label.as(gobject.Object).ref();
        if (v.title_label) |old| old.as(gobject.Object).unref();
        v.title_label = label;
        v.title_len = std.math.maxInt(usize);
        v.updateTitle();
    }

    /// The pane's title, as Rex shows it: a shell as "zsh ~/renux", anything else by the title it
    /// set, then by what runs and where.
    pub fn title(v: *TermView, out: []u8) []const u8 {
        const info = v.server.blockInfo(v.block_id);
        var folder_buf: [256]u8 = undefined;
        const folder: ?[]const u8 = if (info) |b| if (b.folder) |f| programs.shortFolder(&folder_buf, f) else null else null;
        const program: ?[]const u8 = if (info) |b| if (b.program) |p| programs.programName(p) else null else null;
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

    pub fn isShell(p: []const u8) bool {
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

    fn onRealize(w: *gtk.Widget, v: *TermView) callconv(.c) void {
        v.im.as(gtk.IMContext).setClientWidget(w);
    }

    fn onUnrealize(_: *gtk.Widget, v: *TermView) callconv(.c) void {
        v.im.as(gtk.IMContext).setClientWidget(null);
    }

    fn onDestroy(_: *gtk.Widget, v: *TermView) callconv(.c) void {
        v.im.as(gtk.IMContext).setClientWidget(null);
        if (v.edge_timer != 0) _ = glib.Source.remove(v.edge_timer);
        if (v.menu) |m| m.as(gtk.Widget).unparent();
        if (v.menu_link) |l| gpa.free(l);
        v.im.as(gobject.Object).unref();
        if (v.size_timer != 0) _ = glib.Source.remove(v.size_timer);
        if (v.flash_timer != 0) _ = glib.Source.remove(v.flash_timer);
        if (v.drag_idle != 0) _ = glib.Source.remove(v.drag_idle);
        if (v.scroll_tick != 0) {
            v.widget().removeTickCallback(v.scroll_tick);
            scroll_ticking -= 1;
        }
        if (v.shader_view) |sv| {
            if (v.shader_tick != 0) sv.as(gtk.Widget).removeTickCallback(v.shader_tick);
            sv.view = null;
        }
        v.shader_pane.deinit();
        if (v.title_label) |l| l.as(gobject.Object).unref();
        v.title_label = null;
        v.canvas.view = null;
        if (blink_view == v) blink_view = null;
        if (v.own_font) |*f| f.deinit();
        if (v.preedit) |p| gpa.free(p);
        v.dropRows();
        for (v.textures.items) |e| e.texture.as(gobject.Object).unref();
        v.textures.deinit(gpa);
        v.rows_cache.deinit(gpa);
        v.rows_prev.deinit(gpa);
        if (v.layout) |l| l.as(gobject.Object).unref();
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
        const prefs = &settings.current;
        const natural_h = @ceil(@as(f64, @floatFromInt(h)) / pango.SCALE);
        v.cell_w = @max(1, @as(f64, @floatFromInt(w)) / pango.SCALE / 40.0 + prefs.letter_spacing);
        v.cell_h = @max(1, @round(natural_h * prefs.line_height));
        // Taller rows keep the text in their middle.
        v.baseline = @as(f64, @floatFromInt(layout.getBaseline())) / pango.SCALE + @floor((v.cell_h - natural_h) / 2);
        v.spacing = prefs.letter_spacing;
        if (v.layout) |l| setSpacing(l, v.spacing);
    }

    pub fn fontOf(v: *TermView) ?Font {
        return v.own_font orelse font;
    }

    fn setZoom(v: *TermView, z: f64) void {
        v.zoom = std.math.clamp(z, 0.4, 4);
        if (v.own_font) |*old| old.deinit();
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
        // Rows were drawn with the old font, which may be freed by now.
        v.dropRows();
        v.measure();
        v.want_cols = 0;
        v.want_rows = 0;
        const w = v.widget();
        v.resized(w.getWidth(), w.getHeight());
        w.queueDraw();
    }

    // Size.

    fn resized(v: *TermView, width: c_int, height: c_int) void {
        // A card shrinking away into the tray is no size for its program to hear about.
        if (v.frozen) return;
        const fit_cols = @floor((@as(f64, @floatFromInt(width)) - 2 * pad_x) / v.cell_w);
        const fit_rows = @floor((@as(f64, @floatFromInt(height)) - 2 * pad_y) / v.cell_h);
        // A pane with no room yet, or squeezed to nothing on its way to the tray, isn't a size
        // to tell the program about: it would reflow its screen to one cell.
        if (!(fit_cols >= 2 and fit_rows >= 1)) return;
        const cols: u16 = @intFromFloat(@min(fit_cols, 65535));
        const rows: u16 = @intFromFloat(@min(fit_rows, 65535));
        if (cols == v.want_cols and rows == v.want_rows) return;
        v.want_cols = cols;
        v.want_rows = rows;
        // Layout changes report many sizes in a row; only the last one matters.
        if (v.size_timer != 0) _ = glib.Source.remove(v.size_timer);
        v.size_timer = glib.timeoutAdd(size_debounce_ms, &applySize, v);
    }

    /// Tells the server a new pane's size straight away, from the room its card will have
    /// once it has settled. Left to the usual wait, the size arrived a moment after the shell
    /// had started drawing its prompt, and the shell drew the prompt a second time.
    pub fn presize(v: *TermView, width: f64, height: f64) void {
        if (v.frozen or v.sent_cols != 0 or v.cell_w <= 0 or v.cell_h <= 0) return;
        const fit_cols = @floor((width - 2 * pad_x) / v.cell_w);
        const fit_rows = @floor((height - 2 * pad_y) / v.cell_h);
        if (!(fit_cols >= 2 and fit_rows >= 1)) return;
        v.want_cols = @intFromFloat(@min(fit_cols, 65535));
        v.want_rows = @intFromFloat(@min(fit_rows, 65535));
        v.sendSize();
    }

    fn applySize(data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        v.size_timer = 0;
        // While an edge is being dragged the size waits; `sendSize` follows when it's let go.
        if (!hold_sizes) v.sendSize();
        return 0;
    }

    /// Asks the server to fit the block to this pane, unless it already is.
    pub fn sendSize(v: *TermView) void {
        if (v.want_cols == 0) return;
        if (v.want_cols == v.sent_cols and v.want_rows == v.sent_rows) return;
        if (v.server.control == null) return;
        v.sent_cols = v.want_cols;
        v.sent_rows = v.want_rows;
        if (perf_log) std.log.info("size: {s} is {d}x{d}", .{ v.block_id[v.block_id.len -| 6 ..], v.want_cols, v.want_rows });
        v.server.fitBlock(v.session_id, v.block_id, v.want_cols, v.want_rows, @intFromFloat(@round(v.cell_w)), @intFromFloat(v.cell_h));
    }

    /// Forgets the size sent, so the next call sends it again, such as after reconnecting.
    pub fn resendSize(v: *TermView) void {
        v.sent_cols = 0;
        v.sent_rows = 0;
        v.sendSize();
    }

    // Input.

    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, state: gdk.ModifierType, v: *TermView) callconv(.c) c_int {
        const bits: u32 = @bitCast(state);
        const mods = keys.modsFromGdk(bits);
        return v.handleKey(v.latinKey(keyval, keycode, mods), mods);
    }

    /// On a layout without Latin letters, Ctrl+C arrives as Ctrl+с, which no program or binding
    /// knows. Such combinations take the symbol the same key has in the first Latin layout.
    fn latinKey(v: *TermView, keyval: c_uint, keycode: c_uint, mods: u4) c_uint {
        if (!keys.needsLatin(keyval, gdk.keyvalToUnicode(keyval), mods)) return keyval;
        var map: [*]gdk.KeymapKey = undefined;
        var vals: [*]c_uint = undefined;
        var n: c_int = 0;
        if (v.widget().getDisplay().mapKeycode(keycode, &map, &vals, &n) == 0) return keyval;
        defer glib.free(@ptrCast(map));
        defer glib.free(@ptrCast(vals));
        var levels: [32]keys.Level = undefined;
        const count = @min(@as(usize, @intCast(@max(0, n))), levels.len);
        for (0..count) |i| levels[i] = .{ .group = map[i].f_group, .level = map[i].f_level, .keyval = vals[i] };
        return keys.latinKeyval(levels[0..count], mods & keys.shift != 0) orelse keyval;
    }

    /// Development: draws this pane offscreen and reports the average time per frame.
    pub fn bench(v: *TermView) void {
        const w = v.widget().getWidth();
        const h = v.widget().getHeight();
        v.dropRows();
        const first = glib.getMonotonicTime();
        {
            const sn = gtk.Snapshot.new();
            snapshotTermImpl(v, sn);
            if (sn.freeToNode()) |n| n.unref();
        }
        const cold = glib.getMonotonicTime() - first;
        const started = glib.getMonotonicTime();
        for (0..50) |_| {
            const sn = gtk.Snapshot.new();
            snapshotTermImpl(v, sn);
            if (sn.freeToNode()) |n| n.unref();
        }
        std.log.info("bench: {d}x{d} pane, {d} us for a new screen, {d} us per unchanged frame", .{ w, h, cold, @divTrunc(glib.getMonotonicTime() - started, 50) });
    }

    /// Forgets every row's drawing, such as when the font changes.
    pub fn dropRows(v: *TermView) void {
        for (v.rows_cache.items) |e| if (e.node) |n| n.unref();
        v.rows_cache.clearRetainingCapacity();
        for (v.rows_prev.items) |e| if (e.node) |n| n.unref();
        v.rows_prev.clearRetainingCapacity();
    }

    /// Start-up: lets terminals decode the PNGs programs send as images, and turns on the timing
    /// log when RENUX_PERF is set.
    pub fn enablePerfLog() void {
        if (!png_decoder_set) {
            png_decoder_set = true;
            term_mod.Term.setPngDecoder(&decodePng);
        }
        perf_log = @import("build_options").dev and std.c.getenv("RENUX_PERF") != null;
    }

    /// A key press, from the keyboard or the development script.
    pub fn handleKey(v: *TermView, keyval_in: c_uint, mods: u4) c_int {
        if (keys.isModifier(keyval_in)) return 0;
        const keyval = keys.uncapsed(keyval_in, mods);
        if (perf_log) {
            key_at = glib.getMonotonicTime();
            echo_at = 0;
        }
        // In a Rex key mode, keys run that mode's bindings instead of typing.
        if (key_mode_len > 0) {
            v.modeKey(keyval, mods);
            return 1;
        }
        // Keys bound in the Rex config, alone or in a sequence such as ctrl+a then -.
        var name_buf: [40]u8 = undefined;
        if (keys.rexName(&name_buf, keyval, gdk.keyvalToUnicode(keyval), mods)) |name| {
            if (v.chord(name)) return 1;
        }
        // Super+C and V (Command on a Mac) copy and paste. Ctrl+C copies while text is selected
        // and interrupts otherwise; Ctrl+Shift+C and V work too, like other Linux terminals.
        if (mods == keys.super and (keyval == 'c' or keyval == 'C')) {
            v.copySelection(false);
            return 1;
        }
        if (mods == keys.super and (keyval == 'v' or keyval == 'V')) {
            v.pasteClipboard();
            return 1;
        }
        if (mods == keys.ctrl and (keyval == 'c' or keyval == 'C')) if (v.term()) |t| if (t.selectionText()) |sel| {
            gpa.free(sel);
            v.copySelection(false);
            t.clearSelection();
            v.widget().queueDraw();
            return 1;
        };
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

    /// Follows a key through the config's bindings. True when it's taken: a binding ran, or the
    /// key starts or continues a sequence. A sequence that comes to nothing lets its last key
    /// through, as Rex does.
    fn chord(v: *TermView, name: []const u8) bool {
        const binds = v.server.bindings;
        if (chord_len > 0 and keys.sameKey(name, "escape")) {
            chord_len = 0;
            chordChanged();
            return true;
        }
        var exact: ?*const Binding = null;
        var longer = false;
        for (binds) |*b| {
            if (!continuesChord(b) or !keys.sameKey(b.keys[chord_len], name)) continue;
            if (b.keys.len == chord_len + 1) exact = b else longer = true;
        }
        if (exact) |b| {
            const was = chord_len;
            chord_len = 0;
            if (was > 0) chordChanged();
            v.runBinding(b);
            return true;
        }
        if (longer and chord_len < chord_keys.len) {
            const n = @min(name.len, chord_keys[0].len);
            @memcpy(chord_keys[chord_len][0..n], name[0..n]);
            chord_lens[chord_len] = n;
            chord_len += 1;
            chordChanged();
            return true;
        }
        if (chord_len > 0) {
            chord_len = 0;
            chordChanged();
        }
        return false;
    }

    fn runBinding(v: *TermView, b: *const Binding) void {
        if (std.mem.eql(u8, b.action, "client.key.forward")) return;
        v.runAction(b.action, b.args, b.lua);
    }

    /// Runs what a key is bound to. Lua functions and block actions run on the server; pane and
    /// client actions are this app's, as are the session ones Rex leaves to each app.
    fn runAction(v: *TermView, action: []const u8, args: ?[]const u8, lua: bool) void {
        const local = !lua and for ([_][]const u8{ "pane.", "client.", "session." }) |prefix| {
            if (std.mem.startsWith(u8, action, prefix)) break true;
        } else false;
        if (!local) return v.server.runAction(v.session_id, v.block_id, action, args);
        if (!v.server.performLocal(v.session_id, action, args)) v.server.notifyMessage("Renux can't do that action yet");
    }

    fn modeKey(v: *TermView, keyval: c_uint, mods: u4) void {
        var buf: [40]u8 = undefined;
        const name = keys.rexName(&buf, keyval, gdk.keyvalToUnicode(keyval), mods) orelse return;
        for (v.server.mode_bindings) |b| {
            if (!std.mem.eql(u8, b.mode, keyMode()) or !std.mem.eql(u8, b.keys, name)) continue;
            if (std.mem.eql(u8, b.action, "client.mode.exit")) return setKeyMode("");
            return v.runAction(b.action, b.args, false);
        }
        // Escape always leaves a mode, even one without a binding for it.
        if (keyval == 0xff1b) setKeyMode("");
    }

    fn textureFor(v: *TermView, t: *term_mod.Term, im: term_mod.Image) ?*gdk.Texture {
        const key = imageKey(im);
        for (v.textures.items) |e| if (e.key == key) return e.texture;
        const px = t.imagePixels(im.id) orelse return null;
        const tex = makeTexture(px) orelse return null;
        // Textures no image on screen uses any more go, so old frames don't pile up.
        var i: usize = 0;
        while (i < v.textures.items.len) {
            const e = v.textures.items[i];
            const used = for (t.images.items) |o| {
                if (imageKey(o) == e.key) break true;
            } else false;
            if (used) i += 1 else {
                e.texture.as(gobject.Object).unref();
                _ = v.textures.swapRemove(i);
            }
        }
        v.textures.append(gpa, .{ .key = key, .texture = tex }) catch {};
        return tex;
    }

    pub fn selectAll(v: *TermView) void {
        const t = v.term() orelse return;
        t.selectAll();
        v.selectionMade();
        v.widget().queueDraw();
    }

    /// Jumps between shell prompts, which the shell has to mark.
    pub fn jumpPrompt(v: *TermView, delta: isize) void {
        const t = v.term() orelse return;
        t.scrollPrompt(delta);
        _ = t.render(true);
        // Match the smooth-scroll position to where the jump landed.
        v.scroll_px = @as(f64, @floatFromInt(t.frame.rowsUp())) * v.cell_h;
        v.scroll_target = v.scroll_px;
        v.widget().queueDraw();
    }

    /// Moves the terminal's viewport to where the smooth scroll is, and says how many whole rows
    /// up into history that is.
    fn syncScroll(v: *TermView, t: *term_mod.Term) f64 {
        const rows_up = @floor(v.scroll_px / v.cell_h);
        const current_up: f64 = @floatFromInt(t.frame.rowsUp());
        if (current_up != rows_up) {
            t.scroll(@intFromFloat(current_up - rows_up));
            _ = t.render(true);
        }
        return rows_up;
    }

    /// For the development script: text as if the input method committed it.
    pub fn commitText(v: *TermView, text: [:0]const u8) void {
        onCommit(v.im.as(gtk.IMContext), text.ptr, v);
    }

    /// The input method's unfinished text changed, or composing ended.
    fn onPreedit(im: *gtk.IMContext, v: *TermView) callconv(.c) void {
        var str: [*:0]u8 = undefined;
        im.getPreeditString(&str, null, null);
        defer glib.free(str);
        const text = std.mem.span(str);
        if (v.preedit) |old| gpa.free(old);
        v.preedit = if (text.len == 0) null else gpa.dupeSentinel(u8, text, 0) catch null;
        v.widget().queueDraw();
    }

    /// Text from the input method: plain typing, a composed é, or a word from an input method.
    fn onCommit(_: *gtk.IMContext, text: [*:0]const u8, v: *TermView) callconv(.c) void {
        const t = std.mem.span(text);
        if (key_mode_len > 0) {
            // Letters in a key mode run its bindings, like `l` in resize mode.
            const view = std.unicode.Utf8View.init(t) catch return;
            var cps = view.iterator();
            while (cps.nextCodepoint()) |cp| v.modeKey(cp, 0);
            return;
        }
        // Plain keys arrive here as text, not as key presses, so a sequence waiting after a
        // prefix such as ctrl+a looks at them first.
        var rest = t;
        while (chord_len > 0 and rest.len > 0) {
            const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch break;
            if (n > rest.len) break;
            const cp = std.unicode.utf8Decode(rest[0..n]) catch break;
            var name_buf: [40]u8 = undefined;
            const keyval = gdk.unicodeToKeyval(cp);
            const name = keys.rexName(&name_buf, keyval, cp, 0) orelse break;
            if (!v.chord(name)) break;
            rest = rest[n..];
        }
        if (rest.len == 0) return;
        v.scrollToBottom();
        if (v.term()) |tm| tm.clearSelection();
        const view = std.unicode.Utf8View.init(rest) catch return v.server.paste(v.session_id, v.block_id, rest);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| v.server.sendKey(v.session_id, v.block_id, keys.forChar(cp, 0));
    }

    fn onDrop(_: *gtk.DropTarget, value: *const gobject.Value, _: f64, _: f64, v: *TermView) callconv(.c) c_int {
        const obj = value.getObject() orelse return 0;
        const file: *gio.File = @ptrCast(obj);
        const path = file.getPath() orelse return 0;
        defer glib.free(path);
        const quoted = glib.shellQuote(path);
        defer glib.free(quoted);
        const text = std.fmt.allocPrint(gpa, "{s} ", .{std.mem.span(quoted)}) catch return 0;
        defer gpa.free(text);
        v.server.paste(v.session_id, v.block_id, text);
        _ = v.widget().grabFocus();
        return 1;
    }

    /// Lights the pane up briefly, for the bell.
    pub fn flash(v: *TermView) void {
        if (!settings.current.visual_bell) return;
        v.flash_until = glib.getMonotonicTime() + 180_000;
        v.widget().queueDraw();
        if (v.flash_timer != 0) _ = glib.Source.remove(v.flash_timer);
        v.flash_timer = glib.timeoutAdd(190, &unflash, v);
    }

    fn unflash(data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        v.flash_timer = 0;
        v.widget().queueDraw();
        return 0;
    }

    pub fn pasteClipboard(v: *TermView) void {
        v.pasteFrom(v.widget().getClipboard());
    }

    /// Pastes a clipboard's text into this pane, once the text arrives.
    fn pasteFrom(v: *TermView, clipboard: *gdk.Clipboard) void {
        // The view could be gone when the text arrives, so carry the ids instead.
        const ids = gpa.create(PasteTarget) catch return;
        const session_id = gpa.dupe(u8, v.session_id) catch return gpa.destroy(ids);
        const block_id = gpa.dupe(u8, v.block_id) catch {
            gpa.free(session_id);
            return gpa.destroy(ids);
        };
        ids.* = .{ .server = v.server, .session_id = session_id, .block_id = block_id };
        clipboard.readTextAsync(null, &pasted, ids);
    }

    const PasteTarget = struct { server: *Server, session_id: []u8, block_id: []u8 };

    const PendingPaste = struct { server: *Server, session_id: []u8, block_id: []u8, text: []u8 };

    fn confirmPaste(server: *Server, session_id: []const u8, block_id: []const u8, text: []const u8, lines: usize) void {
        const app = gio.Application.getDefault() orelse return;
        const win = @as(*gtk.Application, @ptrCast(app)).getActiveWindow() orelse return;
        var buf: [96]u8 = undefined;
        const heading = std.fmt.bufPrintSentinel(&buf, "Paste {d} lines?", .{lines}, 0) catch return;
        const dialog = adw.AlertDialog.new(heading.ptr, "This program doesn't know it's a paste, so each line may run as a command.");
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("paste", "Paste");
        dialog.setResponseAppearance("paste", .destructive);
        dialog.setDefaultResponse("cancel");
        const pending = gpa.create(PendingPaste) catch return;
        pending.* = .{
            .server = server,
            .session_id = gpa.dupe(u8, session_id) catch return,
            .block_id = gpa.dupe(u8, block_id) catch return,
            .text = gpa.dupe(u8, text) catch return,
        };
        _ = adw.AlertDialog.signals.response.connect(dialog, *PendingPaste, &pasteAnswered, pending, .{});
        dialog.as(adw.Dialog).present(win.as(gtk.Widget));
    }

    fn pasteAnswered(_: *adw.AlertDialog, response: [*:0]const u8, p: *PendingPaste) callconv(.c) void {
        if (std.mem.eql(u8, std.mem.span(response), "paste") and p.server.isLive()) p.server.paste(p.session_id, p.block_id, p.text);
        gpa.free(p.session_id);
        gpa.free(p.block_id);
        gpa.free(p.text);
        gpa.destroy(p);
    }

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
        const body = std.mem.span(text);
        // The host may have been removed while the clipboard was being read.
        if (!t.server.isLive()) return;
        // Without bracketed paste, each pasted line runs as typed, so several lines ask first.
        const lines = std.mem.count(u8, std.mem.trimEnd(u8, body, "\n"), "\n") + 1;
        const bracketed = if (t.server.streams.get(t.block_id)) |st| if (st.term) |tm| tm.frame.bracketed_paste else false else false;
        if (lines > 1 and !bracketed and settings.current.paste_warning) return confirmPaste(t.server, t.session_id, t.block_id, body, lines);
        t.server.paste(t.session_id, t.block_id, body);
    }

    fn onScroll(ctl: *gtk.EventControllerScroll, _: f64, dy: f64, v: *TermView) callconv(.c) c_int {
        const st = v.stream() orelse return 0;
        const t = st.term orelse return 0;
        // Ctrl and the wheel size the text.
        const bits: u32 = @bitCast(ctl.as(gtk.EventController).getCurrentEventState());
        const mods = keys.modsFromGdk(bits);
        if (mods & keys.ctrl != 0) {
            if (dy != 0) v.zoomBy(if (dy < 0) 1 else -1);
            return 1;
        }
        // Programs that take the mouse, or use the whole screen, scroll themselves: by lines,
        // at the cell under the pointer. A touchpad reports pixels, which become lines here.
        if (t.frame.mouse or t.frame.alt_screen) {
            v.scroll_rest += if (ctl.getUnit() == .surface) dy * settings.current.scroll_speed / v.cell_h else dy;
            const lines = @trunc(v.scroll_rest);
            if (lines == 0) return 1;
            v.scroll_rest -= lines;
            const cell = v.cellAt(v.pointer[0], v.pointer[1]);
            v.server.sendWheel(v.session_id, v.block_id, lines, @min(cell[0], t.frame.cols -| 1), @min(cell[1], t.frame.rows -| 1), keys.modsString(mods));
            return 1;
        }
        v.scroll_velocity = 0;
        if (ctl.getUnit() == .surface) {
            // A touchpad reports pixels. Terminals on a Mac move text about twice as far as
            // the fingers do, which is the speed people expect; the setting scales it.
            v.scroll_px -= dy * settings.current.scroll_speed;
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

    fn onMotion(_: *gtk.EventControllerMotion, x: f64, y: f64, v: *TermView) callconv(.c) void {
        v.pointer = .{ x, y };
    }

    /// A touchpad flick carries on, slowing down.
    fn onDecelerate(_: *gtk.EventControllerScroll, _: f64, vy: f64, v: *TermView) callconv(.c) void {
        const t = v.term() orelse return;
        if (t.frame.mouse or t.frame.alt_screen) return;
        v.scroll_velocity = -vy * settings.current.scroll_speed;
        v.startScrollTick();
    }

    fn maxScroll(v: *TermView) f64 {
        const t = v.term() orelse return 0;
        return @as(f64, @floatFromInt(t.frame.scroll_total -| t.frame.scroll_len)) * v.cell_h;
    }

    fn clampScroll(v: *TermView) void {
        const max = v.maxScroll();
        v.scroll_target = std.math.clamp(v.scroll_target, 0, max);
        // A flick that reaches either end has nowhere left to go; carrying its speed on would
        // only keep the pane redrawing.
        if (v.scroll_px <= 0 or v.scroll_px >= max) v.scroll_velocity = 0;
        v.scroll_px = std.math.clamp(v.scroll_px, 0, max);
    }

    fn startScrollTick(v: *TermView) void {
        if (v.scroll_tick != 0) return;
        v.last_frame_us = 0;
        v.scroll_tick = v.widget().addTickCallback(&scrollTick, v, null);
        scroll_ticking += 1;
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
            scroll_ticking -= 1;
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
        const col = @max(0, @floor((x - pad_x) / v.cell_w));
        const row = @max(0, @floor((y - pad_y - v.draw_frac) / v.cell_h));
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
            v.server.sendMouse(v.session_id, v.block_id, "press", v.held_button, cell[0], cell[1], keys.modsString(mods));
            return;
        }
        if (button == 2) return v.pastePrimary();
        if (button == 3) return v.openMenu(x, y);
        if (button != 1) return;
        if (mods & keys.shift != 0 and n_press == 1) {
            if (t.extendSelection(cell[0], cell[1])) {
                v.selectionMade();
                v.selecting = true;
                v.widget().queueDraw();
            }
            return;
        }
        if (n_press == 2) {
            t.selectWord(cell[0], cell[1]);
            v.selectionMade();
            v.widget().queueDraw();
        } else if (n_press == 3) {
            t.selectRange(0, cell[1], t.frame.cols -| 1, cell[1]);
            v.selectionMade();
            v.widget().queueDraw();
        }
    }

    fn onReleased(gesture: *gtk.GestureClick, n_press: c_int, x: f64, y: f64, v: *TermView) callconv(.c) void {
        const t = v.term() orelse return;
        const mods = modsNow(gesture);
        const cell = v.cellAt(x, y);
        if (v.programHasMouse(mods)) {
            v.server.sendMouse(v.session_id, v.block_id, "release", buttonName(gesture), cell[0], cell[1], keys.modsString(mods));
            return;
        }
        if (gesture.as(gtk.GestureSingle).getCurrentButton() != 1 or n_press != 1 or v.selecting) return;
        // Ctrl+click opens a link; a plain click drops the selection.
        if (mods & keys.ctrl != 0) {
            if (v.linkAt(t, cell[0], cell[1])) |url| {
                defer gpa.free(url);
                v.openLink(url);
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
            rows.append(gpa, r) catch {
                gpa.free(r);
                return null;
            };
        }
        const casted: []const []const u21 = @ptrCast(rows.items);
        var link = (links.at(gpa, casted, f.wraps.items, col, row) catch return null) orelse return null;
        defer link.deinit(gpa);
        return gpa.dupeSentinel(u8, link.url, 0) catch null;
    }

    fn onDragBegin(gesture: *gtk.GestureDrag, x: f64, y: f64, v: *TermView) callconv(.c) void {
        v.selecting = false;
        // The right edge is the scrollbar while there's history to scroll.
        v.dragging_bar = x > @as(f64, @floatFromInt(v.widget().getWidth())) - 12 and v.maxScroll() > 0;
        if (v.dragging_bar) {
            v.drag_origin = .{ x, y };
            v.barTo(y);
            return;
        }
        v.drag_to_program = v.programHasMouse(modsNow(gesture));
        v.drag_origin = .{ x, y };
        const cell = v.cellAt(x, y);
        v.anchor = .{ cell[0], cell[1] };
    }

    fn onDragUpdate(gesture: *gtk.GestureDrag, dx: f64, dy: f64, v: *TermView) callconv(.c) void {
        const x = v.drag_origin[0] + dx;
        const y = v.drag_origin[1] + dy;
        if (v.dragging_bar) return v.barTo(y);
        if (v.drag_to_program) {
            // Programs that take the mouse see the drag, one report per cell.
            const cell = v.cellAt(x, y);
            if (cell[0] == v.last_motion[0] and cell[1] == v.last_motion[1]) return;
            v.last_motion = cell;
            v.server.sendMouse(v.session_id, v.block_id, "motion", v.held_button, cell[0], cell[1], keys.modsString(modsNow(gesture)));
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

    /// Scrolls so the scrollbar sits under the pointer: the top is the oldest line.
    fn barTo(v: *TermView, y: f64) void {
        const h: f64 = @floatFromInt(v.widget().getHeight());
        const frac = std.math.clamp(y / @max(1, h), 0, 1);
        v.scroll_velocity = 0;
        v.scroll_px = (1 - frac) * v.maxScroll();
        v.scroll_target = v.scroll_px;
        v.widget().queueDraw();
    }

    fn extendTo(v: *TermView, t: *term_mod.Term, x: f64, y: f64, first: bool) void {
        const cell = v.cellAt(x, @max(pad_y, y));
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
        _ = v.syncScroll(t);
        const h: f64 = @floatFromInt(v.widget().getHeight());
        v.extendTo(t, v.edge_point[0], std.math.clamp(v.edge_point[1], 0, h - 1), false);
        return 1;
    }

    fn onDragEnd(_: *gtk.GestureDrag, _: f64, _: f64, v: *TermView) callconv(.c) void {
        v.edge_scroll = 0;
        v.dragging_bar = false;
        if (v.selecting) v.selectionMade();
        // The release that ends a drag also reaches the click gesture, which checks this.
        const Later = struct {
            fn run(data: ?*anyopaque) callconv(.c) c_int {
                const tv: *TermView = @ptrCast(@alignCast(data.?));
                tv.drag_idle = 0;
                tv.selecting = false;
                return 0;
            }
        };
        if (v.drag_idle == 0) v.drag_idle = glib.idleAdd(&Later.run, v);
    }

    /// The right-click menu: copy, paste, a link under the pointer, and this pane's layout.
    fn openMenu(v: *TermView, x: f64, y: f64) void {
        const t = v.term() orelse return;
        if (v.menu_link) |l| gpa.free(l);
        const cell = v.cellAt(x, y);
        v.menu_link = v.linkAt(t, cell[0], cell[1]);
        const sel = t.selectionText();
        defer if (sel) |s_| gpa.free(s_);
        const target = gpa.dupeSentinel(u8, v.block_id, 0) catch return;
        defer gpa.free(target);
        // Each object below is handed to an owner (the widget, the menu, the popover), which
        // keeps its own reference; ours is dropped so a right-click leaves nothing behind.
        if (v.menu == null) {
            const group = gio.SimpleActionGroup.new();
            defer group.unref();
            inline for (.{ .{ "copy", menuCopy }, .{ "paste", menuPaste }, .{ "open-link", menuOpenLink }, .{ "copy-link", menuCopyLink }, .{ "copy-output", menuCopyOutput } }) |e| {
                const action = gio.SimpleAction.new(e[0], null);
                defer action.unref();
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
        defer menu.unref();
        const edit = gio.Menu.new();
        defer edit.unref();
        if (sel != null) edit.append("Copy", "pane.copy");
        edit.append("Paste", "pane.paste");
        v.menu_cell = cell;
        edit.append("Copy Output", "pane.copy-output");
        menu.appendSection(null, edit.as(gio.MenuModel));
        if (v.menu_link != null) {
            const link = gio.Menu.new();
            defer link.unref();
            link.append("Open Link", "pane.open-link");
            link.append("Copy Link", "pane.copy-link");
            menu.appendSection(null, link.as(gio.MenuModel));
        }
        const layout = gio.Menu.new();
        defer layout.unref();
        inline for (.{ .{ "Split Right", "app.pane-split-right" }, .{ "Split Down", "app.pane-split-down" }, .{ "Float or Dock", "app.pane-float" }, .{ "Zoom", "app.pane-zoom" }, .{ "Close Pane", "app.pane-close" } }) |e| {
            const item = gio.MenuItem.new(e[0], null);
            defer item.unref();
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

    fn menuCopyOutput(v: *TermView) void {
        const t = v.term() orelse return;
        if (!t.selectOutputAt(v.menu_cell[0], v.menu_cell[1])) {
            v.server.notifyMessage("Your shell doesn't mark command output, so Renux can't find it");
            return;
        }
        v.copySelection(false);
        v.widget().queueDraw();
    }

    fn menuCopy(v: *TermView) void {
        v.copySelection(false);
    }

    fn menuPaste(v: *TermView) void {
        v.pasteClipboard();
    }

    fn menuOpenLink(v: *TermView) void {
        const l = v.menu_link orelse return;
        v.openLink(l);
    }

    /// Opens a link. Web, mail and file links open at once; one that opens an app, such as
    /// vscode:, asks first unless its scheme was trusted with Always Open.
    fn openLink(v: *TermView, url: [:0]const u8) void {
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return;
        const scheme = url[0..colon];
        const plain = for ([_][]const u8{ "http", "https", "mailto", "file" }) |w| {
            if (std.ascii.eqlIgnoreCase(scheme, w)) break true;
        } else false;
        const trusted = for (settings.current.trusted_schemes.items) |t| {
            if (std.ascii.eqlIgnoreCase(t, scheme)) break true;
        } else false;
        const root: ?*gtk.Window = @ptrCast(@alignCast(v.widget().getRoot()));
        if (plain or trusted) return launchUri(url.ptr, root);
        const body = std.fmt.allocPrintSentinel(gpa, "{s}", .{url}, 0) catch return;
        defer gpa.free(body);
        const heading = std.fmt.allocPrintSentinel(gpa, "Open a {s} link?", .{scheme}, 0) catch return;
        defer gpa.free(heading);
        const dialog = adw.AlertDialog.new(heading.ptr, body.ptr);
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("always", "Always Open");
        dialog.addResponse("open", "Open");
        dialog.setResponseAppearance("open", .suggested);
        dialog.setDefaultResponse("open");
        const keep = gpa.dupeSentinel(u8, url, 0) catch return;
        const Done = struct {
            fn run(d: *adw.AlertDialog, response: [*:0]const u8, link: [*:0]u8) callconv(.c) void {
                defer gpa.free(std.mem.span(link));
                const r = std.mem.span(response);
                if (std.mem.eql(u8, r, "cancel")) return;
                const l = std.mem.span(link);
                if (std.mem.eql(u8, r, "always")) {
                    const st = settings;
                    const sch = l[0 .. std.mem.indexOfScalar(u8, l, ':') orelse return];
                    st.current.trusted_schemes.append(gpa, gpa.dupe(u8, sch) catch return) catch return;
                    st.save();
                }
                const w: ?*gtk.Window = @ptrCast(@alignCast(d.as(gtk.Widget).getRoot()));
                launchUri(link, w);
            }
        };
        _ = adw.AlertDialog.signals.response.connect(dialog, [*:0]u8, &Done.run, keep.ptr, .{});
        dialog.as(adw.Dialog).present(v.widget());
    }

    /// Hands a link to the desktop. The launch holds the launcher until it's done.
    fn launchUri(uri: [*:0]const u8, parent: ?*gtk.Window) void {
        const launcher = gtk.UriLauncher.new(uri);
        defer launcher.unref();
        launcher.launch(parent, null, null, null);
    }

    fn menuCopyLink(v: *TermView) void {
        const l = v.menu_link orelse return;
        v.widget().getClipboard().setText(l.ptr);
    }

    /// A selection was finished: it becomes the primary selection, and with Copy on select also
    /// the clipboard.
    fn selectionMade(v: *TermView) void {
        v.copySelection(true);
        if (settings.current.copy_on_select) v.copySelection(false);
    }

    /// Copies the selection to the clipboard, or to the primary selection that middle-click pastes.
    pub fn copySelection(v: *TermView, primary: bool) void {
        const t = v.term() orelse return;
        const text = t.selectionText() orelse return;
        defer gpa.free(text);
        const clipboard = if (primary) v.widget().getPrimaryClipboard() else v.widget().getClipboard();
        clipboard.setText(text.ptr);
        if (!primary and text.len > 0) if (v.on_copied) |cb| cb.f(cb.ctx, v.block_id);
    }

    fn pastePrimary(v: *TermView) void {
        v.pasteFrom(v.widget().getPrimaryClipboard());
    }

    fn onFocusIn(_: *gtk.EventControllerFocus, v: *TermView) callconv(.c) void {
        v.im.as(gtk.IMContext).focusIn();
        v.server.sendFocus(v.session_id, v.block_id, true);
        v.widget().queueDraw();
    }

    fn onFocusOut(_: *gtk.EventControllerFocus, v: *TermView) callconv(.c) void {
        // Composing doesn't carry over to another pane: what was unfinished is dropped.
        v.im.as(gtk.IMContext).reset();
        v.im.as(gtk.IMContext).focusOut();
        if (v.preedit) |p| gpa.free(p);
        v.preedit = null;
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


fn rgba(color: u32, alpha: f64) gdk.RGBA {
    return .{
        .f_red = @floatCast(@as(f64, @floatFromInt((color >> 16) & 0xff)) / 255),
        .f_green = @floatCast(@as(f64, @floatFromInt((color >> 8) & 0xff)) / 255),
        .f_blue = @floatCast(@as(f64, @floatFromInt(color & 0xff)) / 255),
        .f_alpha = @floatCast(alpha),
    };
}

// Kitty graphics images.

/// Draws the images on one side of the text: under it, or over it. Each image's texture is
/// made once per image and generation, which changes when a program sends new pixels.
fn drawImages(v: *TermView, sn: *gtk.Snapshot, t: *term_mod.Term, above: bool, frac: f64) void {
    for (t.images.items) |im| {
        if (im.above_text != above or im.sw == 0 or im.sh == 0 or im.width == 0 or im.height == 0) continue;
        const tex = v.textureFor(t, im) orelse continue;
        const x = pad_x + @as(f64, @floatFromInt(im.col)) * v.cell_w + @as(f64, @floatFromInt(im.off_x));
        const y = pad_y + frac + @as(f64, @floatFromInt(im.row)) * v.cell_h + @as(f64, @floatFromInt(im.off_y));
        const dw: f64 = @floatFromInt(im.width);
        const dh: f64 = @floatFromInt(im.height);
        // The source rectangle fills the destination, so the whole image is scaled to match.
        const scale_x = dw / @as(f64, @floatFromInt(im.sw));
        const scale_y = dh / @as(f64, @floatFromInt(im.sh));
        const full_w = @as(f64, @floatFromInt(tex.getWidth())) * scale_x;
        const full_h = @as(f64, @floatFromInt(tex.getHeight())) * scale_y;
        sn.pushClip(&.{ .f_origin = .{ .f_x = @floatCast(x), .f_y = @floatCast(y) }, .f_size = .{ .f_width = @floatCast(dw), .f_height = @floatCast(dh) } });
        sn.appendTexture(tex, &.{
            .f_origin = .{ .f_x = @floatCast(x - @as(f64, @floatFromInt(im.sx)) * scale_x), .f_y = @floatCast(y - @as(f64, @floatFromInt(im.sy)) * scale_y) },
            .f_size = .{ .f_width = @floatCast(full_w), .f_height = @floatCast(full_h) },
        });
        sn.pop();
    }
}

const TextureEntry = struct { key: u64, texture: *gdk.Texture };

fn imageKey(im: term_mod.Image) u64 {
    return (@as(u64, im.id) << 32) ^ im.generation;
}

/// Turns an image's pixels into a texture: RGBA as it is, the other formats into RGBA first.
fn makeTexture(px: term_mod.Term.Pixels) ?*gdk.Texture {
    const n: usize = @as(usize, px.width) * px.height;
    const pixels = gpa.alloc(u8, n * 4) catch return null;
    defer gpa.free(pixels);
    switch (px.format) {
        1, 2 => if (px.data.len >= n * 4) @memcpy(pixels, px.data[0 .. n * 4]) else return null, // RGBA, or a decoded PNG
        0 => { // RGB
            if (px.data.len < n * 3) return null;
            for (0..n) |i| {
                pixels[i * 4] = px.data[i * 3];
                pixels[i * 4 + 1] = px.data[i * 3 + 1];
                pixels[i * 4 + 2] = px.data[i * 3 + 2];
                pixels[i * 4 + 3] = 255;
            }
        },
        3 => { // gray with alpha
            if (px.data.len < n * 2) return null;
            for (0..n) |i| {
                @memset(pixels[i * 4 .. i * 4 + 3], px.data[i * 2]);
                pixels[i * 4 + 3] = px.data[i * 2 + 1];
            }
        },
        4 => { // gray
            if (px.data.len < n) return null;
            for (0..n) |i| {
                @memset(pixels[i * 4 .. i * 4 + 3], px.data[i]);
                pixels[i * 4 + 3] = 255;
            }
        },
        else => return null,
    }
    const bytes = glib.Bytes.new(pixels.ptr, pixels.len);
    defer bytes.unref();
    return gdk.MemoryTexture.new(@intCast(px.width), @intCast(px.height), .r8g8b8a8, bytes, @as(usize, px.width) * 4).as(gdk.Texture);
}

/// A PNG that a program sends, decoded with GDK into the RGBA the terminal stores.
fn decodePng(_: ?*anyopaque, allocator: [*c]const term_mod.Term.Allocator, data: [*c]const u8, len: usize, out: [*c]term_mod.Term.SysImage) callconv(.c) bool {
    const bytes = glib.Bytes.new(data, len);
    defer bytes.unref();
    const tex = gdk.Texture.newFromBytes(bytes, null) orelse return false;
    defer tex.as(gobject.Object).unref();
    const w: usize = @intCast(tex.getWidth());
    const h: usize = @intCast(tex.getHeight());
    const buf = term_mod.Term.ghosttyAlloc(allocator, w * h * 4);
    if (buf == null) return false;
    const dl = gdk.TextureDownloader.new(tex);
    defer dl.free();
    dl.setFormat(.r8g8b8a8);
    dl.downloadInto(@ptrCast(buf), w * 4);
    out.*.width = @intCast(w);
    out.*.height = @intCast(h);
    out.*.data = buf;
    out.*.data_len = w * h * 4;
    return true;
}

var png_decoder_set = false;

fn fillRect(sn: *gtk.Snapshot, color: u32, alpha: f64, x: f64, y: f64, w: f64, h: f64) void {
    const c = rgba(color, alpha);
    sn.appendColor(&c, &.{ .f_origin = .{ .f_x = @floatCast(x), .f_y = @floatCast(y) }, .f_size = .{ .f_width = @floatCast(w), .f_height = @floatCast(h) } });
}

/// Spreads characters apart by `px` (or closer, when negative), so runs of text stay on a grid
/// of the wider cells: Pango leaves the space off a run's first and last character.
fn setSpacing(layout: *pango.Layout, px: f64) void {
    const prefs = &settings.current;
    // Font smoothing off draws glyphs without antialiasing, for crisp pixel fonts.
    {
        const ctx = layout.getContext();
        const opts = cairo.FontOptions.create();
        defer opts.destroy();
        opts.setAntialias(if (prefs.font_smoothing) .default else .none);
        pangocairo.contextSetFontOptions(ctx, opts);
        layout.contextChanged();
    }
    if (px == 0 and prefs.ligatures) return layout.setAttributes(null);
    const list = pango.AttrList.new();
    defer list.unref();
    if (px != 0) list.insert(pango.attrLetterSpacingNew(@intFromFloat(@round(px * pango.SCALE))));
    if (!prefs.ligatures) list.insert(pango.AttrFontFeatures.new("liga 0, clig 0, calt 0, dlig 0"));
    layout.setAttributes(list);
}

/// Places a layout with its baseline at `baseline`. Fallback fonts have other ascents, so
/// placing by the top would put their glyphs at the wrong height.
fn layoutOnBaseline(sn: *gtk.Snapshot, layout: *pango.Layout, color: gdk.RGBA, x: f64, baseline: f64) void {
    const own = @as(f64, @floatFromInt(layout.getBaseline())) / pango.SCALE;
    sn.save();
    sn.translate(&.{ .f_x = @floatCast(x), .f_y = @floatCast(baseline - own) });
    sn.appendLayout(layout, &color);
    sn.restore();
}

var perf_total: i64 = 0;
var perf_count: i64 = 0;
var perf_log = false;
/// With RENUX_PERF: when the last key was pressed and when the server's answer arrived.
var key_at: i64 = 0;
var echo_at: i64 = 0;

/// The view's own layout, made from the widget's Pango context, the one the cell size was
/// measured with, so runs of text advance exactly one cell per character.
fn layoutOf(v: *TermView) *pango.Layout {
    if (v.layout) |l| return l;
    const l = v.widget().createPangoLayout(null);
    setSpacing(l, v.spacing);
    v.layout = l;
    return l;
}

/// A pane with no terminal to show yet, or any more: the theme's background, so a pane that
/// is still connecting doesn't flash dark in a light theme, and a line saying which it is.
fn snapshotEmpty(v: *TermView, sn: *gtk.Snapshot, w: f64, h: f64, message: [:0]const u8) void {
    const bg: u32 = if (theme_bg != 0) theme_bg else 0x1a1a1f;
    fillRect(sn, bg, term_opacity, 0, 0, w, h);
    const ink: u32 = if (luminance(bg) > 0.4) 0x000000 else 0xffffff;
    const f = font orelse return;
    const layout = layoutOf(v);
    layout.setFontDescription(f.regular);
    layout.setText(message.ptr, @intCast(message.len));
    var lw: c_int = 0;
    var lh: c_int = 0;
    layout.getPixelSize(&lw, &lh);
    sn.save();
    sn.translate(&.{ .f_x = @floatCast((w - @as(f64, @floatFromInt(lw))) / 2), .f_y = @floatCast((h - @as(f64, @floatFromInt(lh))) / 2) });
    sn.appendLayout(layout, &rgba(ink, 0.5));
    sn.restore();
}

/// A fingerprint of everything that decides how a row looks.
fn rowHash(v: *TermView, f: *const term_mod.Frame, y: usize, f_font: Font) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const prefs = &settings.current;
    // The font by what it is, not where it lives: a freed font's address can be given out again.
    hasher.update(std.mem.asBytes(&[_]u64{ f_font.id, @bitCast(v.cell_w), @bitCast(v.cell_h), f.fg, f.bg, f.cols, @intFromBool(prefs.improve_contrast), @intFromBool(prefs.rounded_selection), @bitCast(pad_x), @intFromBool(prefs.ligatures), @intFromEnum(prefs.bold_italic), prefs.selection_bg, prefs.selection_fg, @intFromBool(prefs.font_smoothing) }));
    var x: usize = 0;
    while (x < f.cols) : (x += 1) {
        const cl = f.cell(x, y);
        hasher.update(std.mem.asBytes(&[_]u32{ cl.cp, cl.fg, cl.bg, @as(u16, @bitCast(cl.flags)) }));
        if (cl.extra_len > 1) for (f.grapheme(cl)) |cp| hasher.update(std.mem.asBytes(&cp));
    }
    return hasher.final();
}

/// The drawing of one row, from the cache when the row hasn't changed.
fn rowNode(v: *TermView, slot: usize, f: *const term_mod.Frame, y: usize, f_font: Font) ?*gsk.RenderNode {
    while (v.rows_cache.items.len <= slot) v.rows_cache.append(gpa, .{}) catch return null;
    const entry = &v.rows_cache.items[slot];
    const hash = rowHash(v, f, y, f_font);
    if (entry.hash == hash and entry.hash != 0) return entry.node;
    if (entry.node) |n| n.unref();
    // A row's drawing starts at its own top, so it serves wherever the same row is shown: look
    // where it was last frame first, then at every other line.
    const prev = v.rows_prev.items;
    const found: ?*const RowCache = if (hash == 0) null else if (slot < prev.len and prev[slot].hash == hash) &prev[slot] else for (prev) |*p| {
        if (p.hash == hash) break p;
    } else null;
    entry.* = .{ .hash = hash, .node = if (found) |p| (if (p.node) |n| n.ref() else null) else buildRow(v, f, y, f_font) };
    return entry.node;
}

fn buildRow(v: *TermView, f: *const term_mod.Frame, y: usize, f_font: Font) ?*gsk.RenderNode {
    const sn = gtk.Snapshot.new();
    const layout = layoutOf(v);
    // Backgrounds first, so wide glyphs can overhang into the next cell.
    const rounded = settings.current.rounded_selection;
    var x: usize = 0;
    while (x < f.cols) : (x += 1) {
        const cl = f.cell(x, y);
        if (rounded and cl.flags.selected) continue;
        const colors = cellColors(f, cl);
        if (colors.bg == f.bg) continue;
        const span: f64 = if (cl.flags.wide) 2 else 1;
        fillRect(sn, colors.bg, 1, pad_x + @as(f64, @floatFromInt(x)) * v.cell_w, 0, v.cell_w * span + 0.5, v.cell_h);
    }
    // A selection reads as one soft-cornered shape for each run of selected cells.
    if (rounded) {
        x = 0;
        while (x < f.cols) {
            if (!f.cell(x, y).flags.selected) {
                x += 1;
                continue;
            }
            const start = x;
            const color = cellColors(f, f.cell(x, y)).bg;
            while (x < f.cols and f.cell(x, y).flags.selected) x += 1;
            const rect: graphene.Rect = .{ .f_origin = .{ .f_x = @floatCast(pad_x + @as(f64, @floatFromInt(start)) * v.cell_w), .f_y = 0 }, .f_size = .{ .f_width = @floatCast(@as(f64, @floatFromInt(x - start)) * v.cell_w), .f_height = @floatCast(v.cell_h) } };
            var rr: gsk.RoundedRect = undefined;
            _ = rr.initFromRect(&rect, @floatCast(@min(4, v.cell_h / 4)));
            sn.pushRoundedClip(&rr);
            const c = rgba(color, 1);
            sn.appendColor(&c, &rect);
            sn.pop();
        }
    }
    // Then text, in runs of one style. Anything outside ASCII is placed on its own cell, since
    // fallback fonts don't keep to the grid.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    x = 0;
    while (x < f.cols) {
        const cl = f.cell(x, y);
        if (cl.cp == 0 or cl.cp == ' ' or cl.flags.spacer or cl.flags.invisible) {
            x += 1;
            continue;
        }
        if (boxdraw.handles(cl.cp)) {
            const left = pad_x + @as(f64, @floatFromInt(x)) * v.cell_w;
            const cr = sn.appendCairo(&.{ .f_origin = .{ .f_x = @floatCast(left - 1), .f_y = 0 }, .f_size = .{ .f_width = @floatCast(v.cell_w + 2), .f_height = @floatCast(v.cell_h) } });
            setColor(cr, cellColors(f, cl).fg, if (cl.flags.faint) 0.6 else 1);
            boxdraw.draw(cr, cl.cp, left, 0, v.cell_w, v.cell_h);
            cr.destroy();
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
            appendCell(&text, f, n);
            x += if (n.flags.wide) 2 else 1;
            if (n.cp >= 0x80) break;
        }
        const left = pad_x + @as(f64, @floatFromInt(start)) * v.cell_w;
        layout.setFontDescription(f_font.pick(cl.flags));
        text.append(gpa, 0) catch break;
        layout.setText(@ptrCast(text.items.ptr), @intCast(text.items.len - 1));
        const alpha: f64 = if (cl.flags.faint) 0.6 else 1;
        layoutOnBaseline(sn, layout, rgba(colors.fg, alpha), left, v.baseline);
        const run_w = @as(f64, @floatFromInt(x - start)) * v.cell_w;
        if (cl.flags.underline or cl.flags.link) fillRect(sn, colors.fg, alpha, left, v.baseline + 1.5, run_w, 1);
        if (cl.flags.strike) fillRect(sn, colors.fg, alpha, left, v.cell_h / 2, run_w, 1);
    }
    return sn.freeToNode();
}

fn placeRow(sn: *gtk.Snapshot, node: ?*gsk.RenderNode, top: f64) void {
    const n = node orelse return;
    sn.save();
    sn.translate(&.{ .f_x = 0, .f_y = @floatCast(top) });
    sn.appendNode(n);
    sn.restore();
}

pub fn snapshotTermImpl(v: *TermView, sn: *gtk.Snapshot) void {
    if (perf_log and echo_at != 0) {
        const now = glib.getMonotonicTime();
        std.log.info("key: server answered in {d:.1} ms, drawn at {d:.1} ms", .{
            @as(f64, @floatFromInt(echo_at - key_at)) / 1000,
            @as(f64, @floatFromInt(now - key_at)) / 1000,
        });
        key_at = 0;
        echo_at = 0;
    }
    const started = glib.getMonotonicTime();
    defer if (perf_log) {
        perf_total += glib.getMonotonicTime() - started;
        perf_count += 1;
        if (perf_count == 60) {
            std.log.info("draw: {d} us on average", .{@divTrunc(perf_total, 60)});
            perf_total = 0;
            perf_count = 0;
        }
    };
    const w: f64 = @floatFromInt(v.widget().getWidth());
    const h: f64 = @floatFromInt(v.widget().getHeight());
    const st = v.stream() orelse return snapshotEmpty(v, sn, w, h, "Closed");
    const t = st.term orelse return snapshotEmpty(v, sn, w, h, switch (st.state) {
        .closed => "This pane has closed",
        // A pane is nearly always on screen a moment later, so nothing is written meanwhile.
        else => "",
    });
    _ = t.render(true);
    const f = &t.frame;
    const f_font = v.fontOf() orelse return;
    v.shader_look.bg = f.bg;
    v.shader_look.fg = f.fg;
    v.shader_look.cursor_visible = f.cursor_visible;

    const bg_alpha: f64 = term_opacity;
    if (settings.current.padding_color == .theme and theme_bg != 0) {
        fillRect(sn, theme_bg, bg_alpha, 0, 0, w, h);
        fillRect(sn, f.bg, bg_alpha, pad_x, pad_y, @max(0, @as(f64, @floatFromInt(f.cols)) * v.cell_w), @max(0, @as(f64, @floatFromInt(f.rows)) * v.cell_h));
    } else fillRect(sn, f.bg, bg_alpha, 0, 0, w, h);
    sn.pushClip(&.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = @floatCast(w), .f_height = @floatCast(h) } });
    defer sn.pop();

    // Smooth scrolling: the view sits a fraction of a row lower than the viewport while partway
    // into history, and the row above the viewport fills the gap at the top.
    const max_up: f64 = @floatFromInt(f.scroll_total -| f.scroll_len);
    v.followOutput(f.scroll_total);
    v.scroll_px = std.math.clamp(v.scroll_px, 0, max_up * v.cell_h);
    const rows_up = v.syncScroll(t);
    const frac = v.scroll_px - rows_up * v.cell_h;
    v.draw_frac = frac;
    // Last frame's drawings stay at hand for this one: a row that scrolled to another line, or
    // the row that just left the top, is drawn from them instead of being laid out again.
    std.mem.swap(std.ArrayList(RowCache), &v.rows_cache, &v.rows_prev);
    defer {
        for (v.rows_prev.items) |e| if (e.node) |n| n.unref();
        v.rows_prev.clearRetainingCapacity();
    }
    if (frac > 0.01 and rows_up < max_up) {
        t.scroll(-1);
        _ = t.render(true);
        placeRow(sn, rowNode(v, t.frame.rows, &t.frame, 0, f_font), pad_y + frac - v.cell_h);
        t.scroll(1);
        _ = t.render(true);
    }
    drawImages(v, sn, t, false, frac);
    var y: usize = 0;
    while (y < f.rows) : (y += 1) {
        const top = pad_y + frac + @as(f64, @floatFromInt(y)) * v.cell_h;
        if (top > h) break;
        placeRow(sn, rowNode(v, y, f, y, f_font), top);
    }
    drawImages(v, sn, t, true, frac);

    // Search matches, over the text.
    if (t.finding()) {
        var found: [128]term_mod.Match = undefined;
        const n = t.matches(&found);
        for (found[0..n]) |m| {
            var row = m.y0;
            while (row <= m.y1 and row < f.rows) : (row += 1) {
                const from: usize = if (m.y0 == row) m.x0 else 0;
                const to: usize = if (m.y1 == row) m.x1 else f.cols -| 1;
                const top = pad_y + frac + @as(f64, @floatFromInt(row)) * v.cell_h;
                // In the theme's accent, the match the search is on stronger than the rest.
                const tint = if (cursor_accent != 0) cursor_accent else f.fg;
                fillRect(sn, tint, if (m.selected) 0.5 else 0.22, pad_x + @as(f64, @floatFromInt(from)) * v.cell_w, top, @as(f64, @floatFromInt((to -| from) + 1)) * v.cell_w, v.cell_h);
            }
        }
    }

    // Input methods place their candidate popup by the cursor.
    {
        var r: gdk.Rectangle = .{
            .f_x = @intFromFloat(pad_x + @as(f64, @floatFromInt(f.cursor_x)) * v.cell_w),
            .f_y = @intFromFloat(pad_y + v.draw_frac + @as(f64, @floatFromInt(f.cursor_y)) * v.cell_h),
            .f_width = @intFromFloat(v.cell_w),
            .f_height = @intFromFloat(v.cell_h),
        };
        v.im.as(gtk.IMContext).setCursorLocation(&r);
    }

    // The cursor, hollow when the pane doesn't have the keyboard.
    if (f.cursor_visible and f.cursor_y < f.rows and f.cursor_x < f.cols and f.scroll_offset + f.scroll_len >= f.scroll_total) {
        const cx = pad_x + @as(f64, @floatFromInt(f.cursor_x)) * v.cell_w;
        const cy = pad_y + @as(f64, @floatFromInt(f.cursor_y)) * v.cell_h;
        // A program's own cursor color wins; otherwise the theme's accent, like Rex.
        const color = if (f.cursor_color != 0 and f.cursor_color != f.fg) f.cursor_color else if (cursor_accent != 0) cursor_accent else f.fg;
        const focused = v.widget().hasFocus() != 0;
        const prefs = &settings.current;
        const style: c_int = switch (prefs.cursor_style) {
            .program => f.cursor_style,
            .bar => 0,
            .block => 1,
            .underline => 2,
        };
        const blinks = prefs.cursor_blink and focused;
        if (blinks) blinkWanted(v);
        const under = f.cell(f.cursor_x, f.cursor_y);
        const cw = v.cell_w * @as(f64, if (under.flags.wide) 2 else 1);
        // What a custom shader is told of the cursor: its box and shape, as Ghostty numbers
        // them, whichever half of a blink this is.
        const hollow = !focused or style == 3;
        const box: [4]f64 = if (hollow or style == 1) .{ cx, cy, cw, v.cell_h } else if (style == 0) .{ cx, cy, prefs.cursor_width, v.cell_h } else .{ cx, cy + v.cell_h - prefs.cursor_width, cw, prefs.cursor_width };
        for (box, 0..) |x, i| v.shader_look.cursor[i] = @floatCast(x);
        v.shader_look.cursor_style = if (hollow) 1 else if (style == 0) 2 else if (style == 2) 3 else 0;
        v.shader_look.cursor_color = color;
        if (blinks and !blink_on) {
            // The hidden half of a blink.
        } else if (!focused or style == 3) {
            fillRect(sn, color, 1, cx, cy, cw, 1);
            fillRect(sn, color, 1, cx, cy + v.cell_h - 1, cw, 1);
            fillRect(sn, color, 1, cx, cy, 1, v.cell_h);
            fillRect(sn, color, 1, cx + cw - 1, cy, 1, v.cell_h);
        } else switch (style) {
            0 => fillRect(sn, color, 1, cx, cy, prefs.cursor_width, v.cell_h),
            2 => fillRect(sn, color, 1, cx, cy + v.cell_h - prefs.cursor_width, cw, prefs.cursor_width),
            else => {
                fillRect(sn, color, 1, cx, cy, cw, v.cell_h);
                // The character under a block cursor, in the background color.
                if (under.cp != 0 and under.cp != ' ') {
                    var text: std.ArrayList(u8) = .empty;
                    defer text.deinit(gpa);
                    appendCell(&text, f, under);
                    text.append(gpa, 0) catch return;
                    const layout = layoutOf(v);
                    layout.setFontDescription(f_font.pick(under.flags));
                    layout.setText(@ptrCast(text.items.ptr), @intCast(text.items.len - 1));
                    const under_color = if (prefs.cursor_text_color != 0) prefs.cursor_text_color else f.bg;
                    layoutOnBaseline(sn, layout, rgba(under_color, 1), cx, cy + v.baseline);
                }
            },
        }
    }

    // What an input method is still composing: at the cursor, underlined, until it's committed.
    if (v.preedit) |pre| if (f.cursor_y < f.rows and f.cursor_x < f.cols) {
        const layout = layoutOf(v);
        layout.setFontDescription(f_font.regular);
        layout.setText(pre.ptr, @intCast(pre.len));
        var pw: c_int = 0;
        var ph: c_int = 0;
        layout.getPixelSize(&pw, &ph);
        const width: f64 = @floatFromInt(pw);
        // Near the right edge it moves left to stay inside the pane.
        const px = @max(pad_x, @min(pad_x + @as(f64, @floatFromInt(f.cursor_x)) * v.cell_w, w - pad_x - width));
        const py = pad_y + @as(f64, @floatFromInt(f.cursor_y)) * v.cell_h;
        fillRect(sn, f.bg, 1, px, py, width, v.cell_h);
        layoutOnBaseline(sn, layout, rgba(f.fg, 1), px, py + v.baseline);
        fillRect(sn, f.fg, 1, px, py + v.cell_h - 1, width, 1);
    };

    // Panes without the keyboard, or every pane while the window isn't active, fade back.
    {
        const prefs = &settings.current;
        const window_active = if (v.widget().getRoot()) |r| gtk.Window.isActive(@ptrCast(@alignCast(r))) != 0 else true;
        var fade: f64 = 0;
        if (!v.active_pane) fade = prefs.fade_inactive;
        if (prefs.fade_inactive_window and !window_active) fade = @max(fade, if (prefs.fade_inactive > 0) prefs.fade_inactive else 0.35);
        if (fade > 0) fillRect(sn, f.bg, fade, 0, 0, w, h);
    }
    if (f.bg != v.last_bg) {
        v.last_bg = f.bg;
        if (v.on_bg) |cb| cb.f(cb.ctx, v.block_id, f.bg);
    }

    // The bell's flash, fading over its last moments.
    const flash_left = v.flash_until - glib.getMonotonicTime();
    if (flash_left > 0) fillRect(sn, f.fg, 0.14 * @as(f64, @floatFromInt(flash_left)) / 180_000, 0, 0, w, h);

    // A thin scroll position marker while looking back through history.
    if (f.scroll_total > f.scroll_len and f.scroll_offset + f.scroll_len < f.scroll_total) {
        const total: f64 = @floatFromInt(f.scroll_total);
        const bar_h = @max(24, h * @as(f64, @floatFromInt(f.scroll_len)) / total);
        const bar_y = (h - bar_h) * @as(f64, @floatFromInt(f.scroll_offset)) / @max(1, total - @as(f64, @floatFromInt(f.scroll_len)));
        fillRect(sn, f.fg, 0.35, w - 5, bar_y, 3, bar_h);
    }
}

const Colors = struct { fg: u32, bg: u32 };

fn cellColors(f: *const term_mod.Frame, cl: term_mod.Cell) Colors {
    var fg = if (cl.fg != 0) cl.fg else f.fg;
    var bg = if (cl.bg != 0) cl.bg else f.bg;
    if (cl.flags.inverse) std.mem.swap(u32, &fg, &bg);
    if (cl.flags.selected) {
        const prefs = &settings.current;
        if (prefs.selection_bg != 0) {
            bg = prefs.selection_bg;
            if (prefs.selection_fg != 0) fg = prefs.selection_fg;
        } else {
            std.mem.swap(u32, &fg, &bg);
            if (prefs.selection_fg != 0) fg = prefs.selection_fg;
        }
    }
    if (settings.current.improve_contrast) fg = readable(fg, bg);
    return .{ .fg = fg, .bg = bg };
}

fn luminance(c: u32) f64 {
    const lin = struct {
        fn f(v: u32) f64 {
            const x = @as(f64, @floatFromInt(v & 0xff)) / 255;
            return if (x <= 0.03928) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
        }
    }.f;
    return 0.2126 * lin(c >> 16) + 0.7152 * lin(c >> 8) + 0.0722 * lin(c);
}

/// Text colors too close to their background move toward black or white until they read.
fn readable(fg: u32, bg: u32) u32 {
    const lb = luminance(bg);
    const contrast = struct {
        fn f(a: f64, b: f64) f64 {
            return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
        }
    }.f;
    if (contrast(luminance(fg), lb) >= 3) return fg;
    const target: u32 = if (lb > 0.4) 0x000000 else 0xffffff;
    var t: f64 = 0.2;
    while (t <= 1.0) : (t += 0.2) {
        const c = mix(fg, target, t);
        if (contrast(luminance(c), lb) >= 3) return c;
    }
    return target;
}

fn mix(a: u32, b: u32, t: f64) u32 {
    var out: u32 = 0xFF000000;
    inline for (.{ 16, 8, 0 }) |sh| {
        const x: f64 = @floatFromInt((a >> sh) & 0xff);
        const y: f64 = @floatFromInt((b >> sh) & 0xff);
        out |= @as(u32, @intFromFloat(@round(x + (y - x) * t))) << sh;
    }
    return out;
}

fn sameStyle(a: term_mod.Cell, b: term_mod.Cell) bool {
    return a.flags.bold == b.flags.bold and a.flags.italic == b.flags.italic and a.flags.faint == b.flags.faint and
        a.flags.underline == b.flags.underline and a.flags.strike == b.flags.strike and a.flags.link == b.flags.link;
}

fn appendCell(text: *std.ArrayList(u8), f: *const term_mod.Frame, cl: term_mod.Cell) void {
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
