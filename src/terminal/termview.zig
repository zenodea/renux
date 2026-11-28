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
const paths = @import("paths.zig");
const programs = @import("../icons/programs.zig");
const settings = @import("../settings/settings.zig");
const shader = @import("shader.zig");
const fonts = @import("fonts.zig");
const upload_ui = @import("../ui/upload.zig");
const peek = @import("../ui/peek.zig");
pub const ScreenLink = struct { url: [:0]u8, cell: [2]u16 };
const glide_mod = @import("glide.zig");
const copyview = @import("copyview.zig");

const gpa = std.heap.c_allocator;

const ClipboardKind = enum { files, image, text };

fn clipboardKind(formats: *const gdk.ContentFormats) ClipboardKind {
    if (formats.containGtype(gdk.FileList.getGObjectType()) != 0 or formats.containMimeType("text/uri-list") != 0) return .files;
    if (formats.containGtype(gdk.Texture.getGObjectType()) != 0) return .image;
    var count: usize = 0;
    if (formats.getMimeTypes(&count)) |mimes| for (mimes[0..count]) |mime| {
        if (std.mem.startsWith(u8, std.mem.span(mime orelse continue), "image/")) return .image;
    };
    return .text;
}

fn saveClipboardImage(texture: *gdk.Texture) !*gio.File {
    var io: *gio.FileIOStream = undefined;
    const file = gio.File.newTmp("renux-clipboard-XXXXXX.png", &io, null) orelse return error.TempFileFailed;
    errdefer {
        _ = file.delete(null, null);
        file.unref();
    }
    defer io.unref();
    const stream = io.as(gio.IOStream);
    defer _ = stream.close(null, null);
    const png = texture.saveToPngBytes();
    defer png.unref();
    var size: usize = 0;
    const bytes = png.getData(&size) orelse return error.NoImageData;
    if (stream.getOutputStream().writeAll(@constCast(bytes), size, null, null, null) == 0 or stream.close(null, null) == 0) return error.WriteFailed;
    return file;
}

/// The files a copied or dropped list holds, in its order. The list still owns them; the
/// caller frees the slice.
fn listedFiles(value: *const gobject.Value) ![]*gio.File {
    const list: *gdk.FileList = @ptrCast(@alignCast(value.getBoxed() orelse return error.NoFiles));
    var files: std.ArrayList(*gio.File) = .empty;
    errdefer files.deinit(gpa);
    // The chain of links is ours to free; what it links is not.
    const head: ?*glib.SList = list.getFiles();
    defer if (head) |h| h.free();
    var node = head;
    while (node) |n| : (node = n.f_next) try files.append(gpa, @ptrCast(@alignCast(n.f_data orelse continue)));
    if (files.items.len == 0) return error.NoFiles;
    return files.toOwnedSlice(gpa);
}

test "clipboard handles files and images without treating plain text as an attachment" {
    const typed = gdk.ContentFormats.newForGtype(gdk.FileList.getGObjectType());
    defer typed.unref();
    try std.testing.expectEqual(ClipboardKind.files, clipboardKind(typed));
    const texture = gdk.ContentFormats.newForGtype(gdk.Texture.getGObjectType());
    defer texture.unref();
    try std.testing.expectEqual(ClipboardKind.image, clipboardKind(texture));
    for ([_][*:0]const u8{ "text/uri-list", "text/plain", "image/png", "image/jpeg", "image/webp" }, [_]ClipboardKind{ .files, .text, .image, .image, .image }) |mime, expected| {
        var mimes = [_][*:0]const u8{mime};
        const formats = gdk.ContentFormats.new(&mimes, 1);
        defer formats.unref();
        try std.testing.expectEqual(expected, clipboardKind(formats));
    }
    var mimes = [_][*:0]const u8{ "image/png", "text/plain", "text/uri-list" };
    const mixed = gdk.ContentFormats.new(&mimes, mimes.len);
    defer mixed.unref();
    try std.testing.expectEqual(ClipboardKind.files, clipboardKind(mixed));
}

test "every copied file is taken from the clipboard, in order" {
    var files = [_]*gio.File{ gio.File.newForPath("/tmp/copied 'file'.png"), gio.File.newForPath("/tmp/second.txt") };
    defer for (files) |file| file.as(gobject.Object).unref();
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gdk.FileList.getGObjectType());
    defer value.unset();
    value.takeBoxed(gdk.FileList.newFromArray(&files, 1));
    const one = try listedFiles(&value);
    defer gpa.free(one);
    try std.testing.expectEqualSlices(*gio.File, files[0..1], one);
    value.takeBoxed(gdk.FileList.newFromArray(&files, 2));
    const two = try listedFiles(&value);
    defer gpa.free(two);
    try std.testing.expectEqualSlices(*gio.File, &files, two);
    value.setBoxed(null);
    try std.testing.expectError(error.NoFiles, listedFiles(&value));
}

test "clipboard image becomes a private PNG with the same pixels" {
    const pixels = [_]u8{ 255, 100, 0, 255, 10, 20, 30, 128, 0, 0, 0, 0 };
    const bytes = glib.Bytes.new(&pixels, pixels.len);
    defer bytes.unref();
    const memory = gdk.MemoryTexture.new(3, 1, .r8g8b8a8, bytes, pixels.len);
    defer memory.as(gobject.Object).unref();
    const texture = memory.as(gdk.Texture);
    const file = try saveClipboardImage(texture);
    defer file.unref();
    defer _ = file.delete(null, null);
    const info = file.queryInfo("unix::mode", .{}, null, null) orelse return error.MissingFileInfo;
    defer info.unref();
    try std.testing.expectEqual(@as(u32, 0o600), info.getAttributeUint32("unix::mode") & 0o777);
    const decoded = gdk.Texture.newFromFile(file, null) orelse return error.InvalidPng;
    defer decoded.as(gobject.Object).unref();
    try std.testing.expectEqual(@as(c_int, 3), decoded.getWidth());
    try std.testing.expectEqual(@as(c_int, 1), decoded.getHeight());
    var expected: [12]u8 = undefined;
    var actual: [12]u8 = undefined;
    texture.download(&expected, expected.len);
    decoded.download(&actual, actual.len);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "clipboard upload integration" {
    const mode = std.mem.span(std.c.getenv("RENUX_CLIPBOARD_TEST_MODE") orelse return error.SkipZigTest);
    const url = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_URL") orelse return error.MissingTestUrl);
    const sid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_SESSION") orelse return error.MissingTestSession);
    const bid = std.mem.span(std.c.getenv("RENUX_UPLOAD_TEST_BLOCK") orelse return error.MissingTestBlock);
    const path = std.c.getenv("RENUX_UPLOAD_TEST_FILE") orelse return error.MissingTestFile;
    const record = std.c.getenv("RENUX_CLIPBOARD_TEST_RECORD") orelse return error.MissingTestRecord;
    adw.init();
    settings.load();
    const server = try Server.create(url, "clipboard integration");
    var host_live = true;
    defer if (host_live) server.destroy();
    const context = glib.MainContext.default();
    const deadline = glib.getMonotonicTime() + 10_000_000;
    while (server.state != .online and glib.getMonotonicTime() < deadline) {
        _ = context.iteration(0);
        glib.usleep(1000);
    }
    try std.testing.expectEqual(@import("../rex/server.zig").State.online, server.state);
    _ = server.terminal(sid, bid) orelse return error.NoTestTerminal;
    while (!server.attached.contains(sid) and glib.getMonotonicTime() < deadline) {
        _ = context.iteration(0);
        glib.usleep(1000);
    }
    try std.testing.expect(server.attached.contains(sid));
    if (!server.blocks.contains(bid)) try server.blocks.put(gpa, try gpa.dupe(u8, bid), .{});
    const info = server.blockInfo(bid).?;
    if (info.program) |old| gpa.free(old);
    info.program = try gpa.dupe(u8, if (std.mem.eql(u8, mode, "shell-ctrlv")) "bash" else "claude");
    const overlay = adw.ToastOverlay.new();
    _ = overlay.as(gobject.Object).refSink();
    defer overlay.as(gobject.Object).unref();
    const v = try TermView.create(server, sid, bid);
    overlay.setChild(v.widget());
    const clipboard = v.widget().getClipboard();
    var value = std.mem.zeroes(gobject.Value);
    defer value.unset();
    const file_mode = std.mem.endsWith(u8, mode, "file");
    const text_mode = std.mem.endsWith(u8, mode, "text");
    if (file_mode) {
        const file = gio.File.newForPath(path);
        defer file.unref();
        if (std.mem.eql(u8, mode, "uri-file")) {
            const uri = file.getUri();
            defer glib.free(uri);
            const bytes = glib.Bytes.new(uri, std.mem.len(uri));
            defer bytes.unref();
            const provider = gdk.ContentProvider.newForBytes("text/uri-list", bytes);
            defer provider.unref();
            try std.testing.expect(clipboard.setContent(provider) != 0);
            _ = value.init(gobject.ext.types.string);
        } else {
            _ = value.init(gdk.FileList.getGObjectType());
            var files = [_]*gio.File{ file, file };
            value.takeBoxed(gdk.FileList.newFromArray(&files, if (std.mem.eql(u8, mode, "multiple-file")) 2 else 1));
        }
    } else if (text_mode) {
        _ = value.init(gobject.ext.types.string);
        value.setString("ordinary clipboard text");
    } else {
        const texture = gdk.Texture.newFromFilename(path, null) orelse return error.InvalidImageFixture;
        defer texture.as(gobject.Object).unref();
        // The expected upload is the normalized PNG, not necessarily the source encoding.
        const expected = std.c.getenv("RENUX_CLIPBOARD_TEST_EXPECTED") orelse return error.MissingExpectedFile;
        try std.testing.expect(texture.saveToPng(expected) != 0);
        if (std.mem.eql(u8, mode, "texture")) {
            _ = value.init(gdk.Texture.getGObjectType());
            value.setObject(texture.as(gobject.Object));
        } else {
            const bytes = if (std.mem.eql(u8, mode, "invalid-image")) glib.Bytes.new("not a PNG", 9) else texture.saveToPngBytes();
            defer bytes.unref();
            const provider = gdk.ContentProvider.newForBytes("image/png", bytes);
            defer provider.unref();
            try std.testing.expect(clipboard.setContent(provider) != 0);
            _ = value.init(gobject.ext.types.string);
        }
    }
    if (!std.mem.eql(u8, mode, "uri-file") and (file_mode or text_mode or std.mem.eql(u8, mode, "texture"))) {
        const provider = gdk.ContentProvider.newForValue(&value);
        defer provider.unref();
        try std.testing.expect(clipboard.setContent(provider) != 0);
    }
    server.message.clearRetainingCapacity();
    const ctrl_v = std.mem.startsWith(u8, mode, "ctrlv-") or std.mem.eql(u8, mode, "shell-ctrlv");
    try std.testing.expectEqual(@as(c_int, 1), v.handleKey('v', if (ctrl_v) keys.ctrl else keys.ctrl | keys.shift));
    const destroying = std.mem.startsWith(u8, mode, "destroy-");
    const failed = std.mem.eql(u8, mode, "invalid-image") or std.mem.eql(u8, mode, "save-failure");
    if (destroying) {
        overlay.setChild(null);
        if (std.mem.eql(u8, mode, "destroy-host")) {
            server.destroy();
            host_live = false;
        }
    }
    var got_input = false;
    const until = glib.getMonotonicTime() + if (destroying or failed) @as(i64, 500_000) else @as(i64, 10_000_000);
    while (glib.getMonotonicTime() < until) {
        _ = context.iteration(0);
        var contents: [*]u8 = undefined;
        var length: usize = 0;
        if (glib.fileGetContents(record, &contents, &length, null) != 0) {
            glib.free(contents);
            if (length > 0) {
                got_input = true;
                break;
            }
        }
        glib.usleep(1000);
    }
    try std.testing.expectEqual(!destroying and !failed, got_input);
    if (failed) try std.testing.expect(server.message.items.len > 0);
    const settled = glib.getMonotonicTime() + 200_000;
    while (glib.getMonotonicTime() < settled) {
        _ = context.iteration(0);
        glib.usleep(1000);
    }
    _ = clipboard.setContent(null);
}

test "file hover targets preserve web and OSC8 links without reading files" {
    const t = term_mod.Term.create(80, 4) orelse return error.NoTerminal;
    defer t.destroy();
    t.write("./result.png https://example.com/a.png\r\n\x1b]8;;file:///tmp/picture%20one.png\x1b\\picture\x1b]8;;\x1b\\:42");
    try std.testing.expect(t.render(true));
    var path = TermView.textLinkAt(t, 3, 0) orelse return error.NoPath;
    defer path.deinit(gpa);
    try std.testing.expectEqualStrings("renux-file:./result.png", path.url);
    var url = TermView.textLinkAt(t, 20, 0) orelse return error.NoUrl;
    defer url.deinit(gpa);
    try std.testing.expectEqualStrings("https://example.com/a.png", url.url);
    const osc = t.hyperlinkAt(2, 1) orelse return error.NoHyperlink;
    defer gpa.free(osc);
    try std.testing.expect(TermView.isFileLink(osc));
    try std.testing.expect(!TermView.isFileLink(url.url));
    const targets = try TermView.screenLinksIn(t);
    defer {
        for (targets) |l| gpa.free(l.url);
        gpa.free(targets);
    }
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    try std.testing.expectEqualStrings("renux-file:./result.png", targets[0].url);
    try std.testing.expectEqualStrings("https://example.com/a.png", targets[1].url);
    try std.testing.expectEqualStrings("renux-file:/tmp/picture one.png:42", targets[2].url);
}

/// The space around the text, from the settings.
pub var pad_x: f64 = 8;
pub var pad_y: f64 = 8;
/// The theme's own background, for padding drawn in the theme's color.
pub var theme_bg: u32 = 0;
const size_debounce_ms = 200;
const glide_armed_us = 400_000;
const glide_unanswered_us = 250_000;
const glide_fingers_gone_us = 300_000;
const coast_fade_per_second = 0.05;
const most_rows_a_step = 8.0;
const coast_slowest_px_per_second = 15.0;

/// The four faces text is drawn in.
pub const Face = enum(u2) { regular, bold, italic, bold_italic };

pub const Font = struct {
    regular: *pango.FontDescription,
    bold: *pango.FontDescription,
    italic: *pango.FontDescription,
    bold_italic: *pango.FontDescription,
    /// What the font is (families, size, styles, features), for telling drawings made with
    /// another font apart.
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
        const st = &settings.current;
        const own = st.custom_style_fonts;
        const bold = styled(regular, if (own) st.font_bold else "", true, false);
        const italic = styled(regular, if (own) st.font_italic else "", false, true);
        const bold_italic = styled(regular, if (own) st.font_bold_italic else "", true, true);
        var hasher = std.hash.Wyhash.init(0);
        for ([_]*pango.FontDescription{ regular, bold, italic, bold_italic }) |d| hasher.update(std.mem.asBytes(&d.hash()));
        hasher.update(st.font_features);
        return .{ .regular = regular, .bold = bold, .italic = italic, .bold_italic = bold_italic, .id = hasher.final() };
    }

    /// The regular face made bold, italic or both, in `family` when one is named.
    fn styled(regular: *pango.FontDescription, family: []const u8, bold: bool, italic: bool) *pango.FontDescription {
        const d = regular.copy().?;
        if (bold) d.setWeight(.bold);
        if (italic) d.setStyle(.italic);
        const name = std.mem.trim(u8, family, " ");
        // The font's own families stay behind the named one, for what that one doesn't have.
        if (name.len > 0) if (regular.getFamily()) |rest| {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrintSentinel(&buf, "{s},{s}", .{ name, std.mem.span(rest) }, 0)) |both| d.setFamily(both.ptr) else |_| {}
        };
        return d;
    }

    /// Frees the four descriptions. Layouts copy what they're given, so nothing else holds them.
    pub fn deinit(f: *Font) void {
        f.regular.free();
        f.bold.free();
        f.italic.free();
        f.bold_italic.free();
        f.* = undefined;
    }

    fn faceOf(flags: term_mod.Flags) Face {
        if (settings.current.bold_italic == .plain) return .regular;
        if (flags.bold and flags.italic) return .bold_italic;
        if (flags.bold) return .bold;
        if (flags.italic) return .italic;
        return .regular;
    }

    fn of(f: Font, face: Face) *pango.FontDescription {
        return switch (face) {
            .regular => f.regular,
            .bold => f.bold,
            .italic => f.italic,
            .bold_italic => f.bold_italic,
        };
    }
};

pub var font: ?Font = null;
/// The theme's accent as 0xRRGGBB, which the cursor takes unless a program sets its own.
pub var cursor_accent: u32 = 0;
/// The theme's green as 0xRRGGBB, which the name of a file being sent turns as it goes.
pub var theme_green: u32 = 0;
/// How opaque a terminal's own background is.
pub var term_opacity: f64 = 1;
/// Told each time a pane has drawn, so the window's cursor layer can follow its cursor.
pub var on_drawn: ?*const fn (v: *TermView) void = null;
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
        // The window's cursor layer follows the cursor this drew, if this pane has it.
        defer if (on_drawn) |f| f(v);
        snapshotTermImpl(v, sn);
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

/// What a card holds, its header above its terminal, laid out top to bottom. While a pane shader
/// is on, this is the shader's picture: it draws its children aside, into the picture, and the
/// shader's view over it shows what the shader makes of them, header and all. It only draws when
/// what it holds has changed, so a shader moving with time doesn't take a new picture each frame.
pub const ShaderSource = extern struct {
    parent_instance: Parent,
    view: ?*TermView,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "RenuxShaderSource",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn children(w: *gtk.Widget, sn: *gtk.Snapshot) void {
        var c = w.getFirstChild();
        while (c) |child| : (c = child.getNextSibling()) w.snapshotChild(child, sn);
    }

    fn snapshot(self: *Self, sn: *gtk.Snapshot) callconv(.c) void {
        const w = self.as(gtk.Widget);
        const v = self.view orelse return children(w, sn);
        // The shader's view shows what this drew, so it draws again after this does.
        defer if (v.shader_view) |sv| sv.as(gtk.Widget).queueDraw();
        if (!shader.pane.active()) {
            v.shader_drawn = false;
            return children(w, sn);
        }
        const own = gtk.Snapshot.new();
        children(w, own);
        const node = own.freeToNode() orelse {
            v.shader_drawn = false;
            return;
        };
        defer node.unref();
        // The cursor is in the terminal's points; the header puts it lower in this picture.
        var at: graphene.Point = undefined;
        if (v.widget().computePoint(w, &.{ .f_x = 0, .f_y = 0 }, &at) != 0) v.shader_origin = .{ at.f_x, at.f_y };
        v.shader_drawn = shader.updateInput(&v.shader_pane, w, node);
        if (!v.shader_drawn) sn.appendNode(node);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const w = self.as(gtk.Widget);
        while (w.getFirstChild()) |child| child.unparent();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
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
        if (!v.shader_drawn or !shader.pane.active()) return;
        const focused = v.widget().hasFocus() != 0;
        var look = v.shader_look;
        look.cursor[0] += v.shader_origin[0];
        look.cursor[1] += v.shader_origin[1];
        _ = shader.drawOutput(&v.shader_pane, &look, focused, sn);
        // A shader that moves with time draws the pane with the keyboard again every frame, as
        // Ghostty does; the others keep their last frame until the pane changes.
        if (focused and v.shader_tick == 0 and shader.pane.wantsFrames(&v.shader_pane)) v.shader_tick = self.as(gtk.Widget).addTickCallback(&shaderTick, v, null);
    }

    fn shaderTick(widget: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        widget.queueDraw();
        if (v.widget().hasFocus() != 0 and shader.pane.wantsFrames(&v.shader_pane)) return 1;
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

/// The keys before one that ends a sequence bound to a Lua function, which the next key
/// press carries to the server as its prefix.
var forward_keys: [4][40]u8 = undefined;
var forward_lens: [4]usize = .{ 0, 0, 0, 0 };
var forward_len: usize = 0;

/// Whether the first keys of a binding have been pressed and the rest are awaited.
pub fn chordPending() bool {
    return chord_len > 0;
}
/// Whether a key is the first of one of these bindings: a prefix, or a key bound by itself.
pub fn beginsBinding(binds: []const Binding, name: []const u8) bool {
    for (binds) |b| if (b.keys.len > 0 and keys.sameKey(b.keys[0], name)) return true;
    return false;
}

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
    /// The letter spacing each face is drawn with. A bold or italic face from another family
    /// can be wider or narrower than a cell, and this makes up the difference.
    face_spacing: [4]f64 = @splat(0),
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
    glide: glide_mod.Glide = .{},
    glide_armed_until: i64 = 0,
    glide_direction: glide_mod.Direction = .either,
    glide_tick: c_uint = 0,
    glide_frame_us: i64 = 0,
    glide_unanswered: f64 = 0,
    glide_steps_unanswered: f64 = 0,
    glide_rows_a_step: f64 = 1,
    glide_asked_us: i64 = 0,
    glide_wheel_us: i64 = 0,
    coast_rows_per_second: f64 = 0,
    /// The pane's textures for a custom shader, and the tick that redraws it while the shader
    /// moves with time.
    shader_pane: shader.Pane = .{},
    shader_tick: c_uint = 0,
    /// The widget over the terminal that shows the shader's picture, and whether the last
    /// drawing went through the shader at all.
    shader_view: ?*ShaderView = null,
    shader_drawn: bool = false,
    /// Where the terminal starts in the card's picture, below the header.
    shader_origin: [2]f32 = .{ 0, 0 },
    shader_source: ?*ShaderSource = null,
    /// What the last drawing knew of the cursor and colors, for the shader.
    shader_look: shader.Look = .{},
    last_frame_us: i64 = 0,
    last_total: u64 = 0,
    draw_frac: f64 = 0,
    /// Where the pane's top left corner is in its window and how many screen pixels a unit of
    /// its own is, as of the frame being drawn: what `pixelX` and `pixelY` go by.
    pixel_origin: [2]f64 = .{ 0, 0 },
    pixel_scale: f64 = 1,
    /// Where the pointer is over the pane, so the wheel scrolls what's under it.
    pointer: [2]f64 = .{ 0, 0 },
    /// The keys held down whose presses went to the program, by the keyboard's own number for
    /// each. A press of one already here is the keyboard repeating it, and its release is
    /// sent when it comes up: programs that time held keys, as games do, need both.
    held: [12]HeldKey = undefined,
    held_len: usize = 0,
    /// The keyboard's number for the key being handled, while a key press is.
    event_keycode: c_uint = 0,
    key_ctl: ?*gtk.EventControllerKey = null,
    /// Ctrl is held with the pointer over the pane, which is when a click opens a link: the
    /// link under the pointer is underlined, and the pointer becomes a hand over it.
    link_armed: bool = false,
    link_hand: bool = false,
    pointer_in: bool = false,
    /// Text an input method is still composing, shown at the cursor until it's committed.
    preedit: ?[:0]u8 = null,
    /// The text that stands for a file being sent: where it and its cancel button were last
    /// drawn, whether the pointer is over each, and whether the press under way landed on the
    /// button. The button shows while the pointer is over the text.
    upload_area: ?[4]f64 = null,
    upload_cancel: ?[4]f64 = null,
    upload_hover: bool = false,
    upload_hand: bool = false,
    upload_press: bool = false,
    /// How much of the file the text shows as sent, which eases toward how much has been, and
    /// the tick that moves it.
    upload_shown: f64 = 0,
    upload_tick: c_uint = 0,
    upload_frame_us: i64 = 0,
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
    copy_mode: ?copyview.Session = null,
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
    /// The cell of the link being opened, which a file's peek is shown by.
    link_cell: [2]u16 = .{ 0, 0 },
    /// Dragging the scroll position marker.
    dragging_bar: bool = false,
    /// When a bell flash fades out, in monotonic microseconds.
    flash_until: i64 = 0,
    /// Called when this pane is clicked, so the workspace can mark it focused.
    on_focus: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, block_id: []const u8) void } = null,
    /// Told when this pane's selection reaches the clipboard, to show that it did.
    /// The copy's moment: the pane as it was at the copy, selection and all, the selected runs
    /// of cells, where the first row sat, when it began, and the tick that draws it.
    copy_node: ?*gsk.RenderNode = null,
    copy_spans: std.ArrayList(CopySpan) = .empty,
    copy_top: f64 = 0,
    /// Where the text sat when it was copied; see `textAnchor`.
    copy_anchor: f64 = 0,
    copy_started: i64 = 0,
    copy_tick: c_uint = 0,

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
        v.key_ctl = key;
        _ = gtk.EventControllerKey.signals.key_pressed.connect(key, *TermView, &onKey, v, .{});
        _ = gtk.EventControllerKey.signals.key_released.connect(key, *TermView, &onKeyReleased, v, .{});
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
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *TermView, &onLeave, v, .{});
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

        // Local drops insert a path; remote drops send the file before Rex inserts its path.
        // A drop of several files comes as a list; some apps offer only a single file.
        const drop = gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true });
        var kinds = [_]usize{ gdk.FileList.getGObjectType(), gio.File.getGObjectType() };
        drop.setGtypes(&kinds, kinds.len);
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

    /// The custom shader's picture of the pane, laid over the card's content.
    pub fn shaderWidget(v: *TermView) *gtk.Widget {
        return v.shader_view.?.as(gtk.Widget);
    }

    /// A container for the card's header and terminal, top to bottom, which a pane shader takes
    /// its picture from.
    pub fn shaderSource(v: *TermView) *gtk.Widget {
        const s = gobject.ext.newInstance(ShaderSource, .{});
        s.view = v;
        const w = s.as(gtk.Widget);
        w.setLayoutManager(gtk.BoxLayout.new(.vertical).as(gtk.LayoutManager));
        v.shader_source = s;
        return w;
    }

    pub fn widget(v: *TermView) *gtk.Widget {
        return v.canvas.as(gtk.Widget);
    }

    fn stream(v: *TermView) ?*Stream {
        return v.server.streams.get(v.block_id);
    }

    pub fn term(v: *TermView) ?*term_mod.Term {
        if (v.copy_mode) |s| return s.term;
        const st = v.stream() orelse return null;
        return st.term;
    }

    fn changed(ctx: *anyopaque) void {
        const v: *TermView = @ptrCast(@alignCast(ctx));
        if (perf_log and key_at != 0 and echo_at == 0) echo_at = glib.getMonotonicTime();
        if (v.copy_mode == null) v.widget().queueDraw();
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
        if (v.copy_mode) |s| s.term.destroy();
        upload_ui.unwatch(v);
        peek.closeFor(v.widget());
        if (v.upload_tick != 0) v.widget().removeTickCallback(v.upload_tick);
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
        if (v.glide_tick != 0) v.widget().removeTickCallback(v.glide_tick);
        v.glide.forget();
        if (v.shader_view) |sv| {
            if (v.shader_tick != 0) sv.as(gtk.Widget).removeTickCallback(v.shader_tick);
            sv.view = null;
        }
        if (v.shader_source) |s| s.view = null;
        v.shader_pane.deinit();
        if (v.copy_tick != 0) v.widget().removeTickCallback(v.copy_tick);
        v.endCopyAnimation();
        v.copy_spans.deinit(gpa);
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
        v.face_spacing = @splat(v.spacing);
        if (prefs.custom_style_fonts) for ([_]Face{ .bold, .italic, .bold_italic }) |face| {
            layout.setFontDescription(f.of(face));
            var face_w: c_int = 0;
            layout.getSize(&face_w, null);
            const apart = @as(f64, @floatFromInt(w - face_w)) / pango.SCALE / 40.0;
            if (@abs(apart) > 0.005) v.face_spacing[@backingInt(face)] = v.spacing + apart;
        };
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
        if (perf_log) std.log.info("size: {s} is {d}x{d}", .{ v.block_id[v.block_id.len -| 6..], v.want_cols, v.want_rows });
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
        if (isCtrlKey(keyval)) v.armLink(true);
        v.event_keycode = keycode;
        defer v.event_keycode = 0;
        return v.handleKey(v.latinKey(keyval, keycode, mods), mods);
    }

    fn onKeyReleased(_: *gtk.EventControllerKey, keyval: c_uint, keycode: c_uint, _: gdk.ModifierType, v: *TermView) callconv(.c) void {
        if (isCtrlKey(keyval)) v.armLink(false);
        v.releaseKey(keycode);
    }

    /// Sends a key press to the program, remembering which key on the keyboard it came from
    /// (0 when unknown). A key already held is sent as a repeat.
    pub fn sendPress(v: *TermView, key: keys.Key, keycode: c_uint) void {
        var out = key;
        if (keycode != 0) {
            if (v.heldIndex(keycode)) |i| {
                out.action = .repeat;
                v.held[i].key = key;
            } else if (v.held_len < v.held.len) {
                v.held[v.held_len] = .{ .keycode = keycode, .key = key };
                v.held_len += 1;
            }
        }
        if (forward_len > 0) {
            var prefix: [4][]const u8 = undefined;
            for (0..forward_len) |i| prefix[i] = forward_keys[i][0..forward_lens[i]];
            const n = forward_len;
            forward_len = 0;
            return v.server.sendSequenceKey(v.session_id, v.block_id, out, prefix[0..n]);
        }
        v.server.sendKey(v.session_id, v.block_id, out);
    }

    /// A key came up: if its press went to the program, so does its release.
    pub fn releaseKey(v: *TermView, keycode: c_uint) void {
        const i = v.heldIndex(keycode) orelse return;
        var key = v.held[i].key;
        v.held[i] = v.held[v.held_len - 1];
        v.held_len -= 1;
        // A release types nothing.
        key.action = .release;
        key.text_len = 0;
        v.server.sendKey(v.session_id, v.block_id, key);
    }

    fn heldIndex(v: *const TermView, keycode: c_uint) ?usize {
        for (v.held[0..v.held_len], 0..) |h, i| if (h.keycode == keycode) return i;
        return null;
    }

    /// The keyboard's number for the key whose press is being handled right now, or 0: text
    /// typed by an input method on its own time has no one key behind it.
    fn pressedKeycode(v: *const TermView) c_uint {
        const ctl = v.key_ctl orelse return 0;
        const event = ctl.as(gtk.EventController).getCurrentEvent() orelse return 0;
        if (event.getEventType() != .key_press) return 0;
        const key_event: *gdk.KeyEvent = @ptrCast(event);
        return key_event.getKeycode();
    }

    /// Left or right Ctrl. The key's own press doesn't yet count it among the modifiers held.
    fn isCtrlKey(keyval: c_uint) bool {
        return keyval == 0xffe3 or keyval == 0xffe4;
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
        if (v.copy_mode != null) {
            copyview.key(v, keyval, mods);
            return 1;
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
        // Agents use Ctrl+V for attachments; shells still need it for literal-next.
        if (mods == keys.ctrl and (keyval == 'v' or keyval == 'V')) if (v.server.blockInfo(v.block_id)) |info| {
            if (programs.isAgent(info.program) or programs.isAgent(info.status_app)) {
                const clipboard = v.widget().getClipboard();
                if (clipboardKind(clipboard.getFormats()) != .text) {
                    v.pasteFrom(clipboard);
                    return 1;
                }
            }
        };
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
        v.sendPress(key, v.event_keycode);
        return 1;
    }

    /// Follows a key through the config's bindings. True when it's taken: a binding ran, or the
    /// key starts or continues a sequence. A sequence that comes to nothing lets its last key
    /// through, as Rex does.
    fn chord(v: *TermView, name: []const u8) bool {
        const binds = v.server.keyBindings();
        forward_len = 0;
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
            // A Lua function binding: the key goes on with client.key, and the server runs it.
            if (std.mem.eql(u8, b.action, "client.key.forward")) {
                forward_keys = chord_keys;
                forward_lens = chord_lens;
                forward_len = was;
                return false;
            }
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
    pub fn runAction(v: *TermView, action: []const u8, args: ?[]const u8, lua: bool) void {
        const local = !lua and for ([_][]const u8{ "pane.", "client.", "session." }) |prefix| {
            if (std.mem.startsWith(u8, action, prefix)) break true;
        } else false;
        if (!local) return v.server.runAction(v.session_id, v.block_id, action, args);
        if (!v.server.performLocal(v.session_id, action, args)) v.server.notifyMessage("Renux can't do that action yet");
    }

    fn modeKey(v: *TermView, keyval: c_uint, mods: u4) void {
        var buf: [40]u8 = undefined;
        const name = keys.rexName(&buf, keyval, gdk.keyvalToUnicode(keyval), mods) orelse return;
        for (v.server.modeBindings()) |b| {
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

    /// The terminal moved its own view, as a find does to show the match it picked: the smooth
    /// scroll glides there. Without this the next frame would put the view back where the
    /// smooth scroll was, leaving the match out of sight.
    pub fn followViewport(v: *TermView) void {
        const t = v.term() orelse return;
        _ = t.render(true);
        v.scroll_target = @as(f64, @floatFromInt(t.frame.rowsUp())) * v.cell_h;
        v.scroll_velocity = 0;
        v.clampScroll();
        v.startScrollTick();
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
        if (v.copy_mode != null) {
            const view = std.unicode.Utf8View.init(t) catch return;
            var cps = view.iterator();
            while (cps.nextCodepoint()) |cp| {
                if (v.copy_mode == null) break;
                copyview.key(v, gdk.unicodeToKeyval(cp), 0);
            }
            return;
        }
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
        // One character typed by one key press is that key's press: it can repeat and be
        // released. Anything else (a composed character, a word from an input method) is text.
        const keycode: c_uint = if ((std.unicode.utf8CountCodepoints(rest) catch 0) == 1) v.pressedKeycode() else 0;
        while (it.nextCodepoint()) |cp| v.sendPress(keys.forChar(cp, 0), keycode);
    }

    fn onDrop(_: *gtk.DropTarget, value: *const gobject.Value, _: f64, _: f64, v: *TermView) callconv(.c) c_int {
        if (value.f_g_type == gdk.FileList.getGObjectType()) {
            const files = listedFiles(value) catch return 0;
            defer gpa.free(files);
            if (!v.insertFiles(files, false)) return 0;
        } else {
            const file: *gio.File = @ptrCast(value.getObject() orelse return 0);
            if (!v.insertFiles(&.{file}, false)) return 0;
        }
        _ = v.widget().grabFocus();
        return 1;
    }

    /// Gives the program the files: on another host by sending them, after which Rex pastes
    /// where they landed; on this computer by pasting their paths, which it can already read.
    fn insertFiles(v: *TermView, files: []const *gio.File, temporary: bool) bool {
        if (v.onRemoteHost()) return v.upload(files, temporary);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (files) |file| {
            const path = file.getPath() orelse return false;
            defer glib.free(path);
            const quoted = glib.shellQuote(path);
            defer glib.free(quoted);
            text.appendSlice(gpa, std.mem.span(quoted)) catch return false;
            text.append(gpa, ' ') catch return false;
        }
        v.server.paste(v.session_id, v.block_id, text.items);
        return true;
    }

    /// Sends files to the pane's machine, where Rex pastes their paths once all have arrived.
    /// A temporary file is deleted afterwards.
    pub fn upload(v: *TermView, files: []const *gio.File, temporary: bool) bool {
        v.upload_shown = 0;
        return upload_ui.start(v.widget(), v.server, v.session_id, v.block_id, files, temporary, .{ .ctx = v, .changed = uploadChanged });
    }

    /// The file being sent to this pane got further, or is done: its text is drawn again.
    fn uploadChanged(ctx: *anyopaque) void {
        const v: *TermView = @ptrCast(@alignCast(ctx));
        v.widget().queueDraw();
        if (v.upload_tick != 0) return;
        v.upload_frame_us = 0;
        v.upload_tick = v.widget().addTickCallback(&uploadTick, v, null);
    }

    /// The green moves along the name smoothly, however unevenly the file itself goes.
    fn uploadTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        const target = if (upload_ui.find(v.server, v.block_id)) |up| up.fraction() else v.upload_shown;
        const now = clock.getFrameTime();
        const dt: f64 = if (v.upload_frame_us == 0) 1.0 / 60.0 else @min(0.05, @as(f64, @floatFromInt(now - v.upload_frame_us)) / 1e6);
        v.upload_frame_us = now;
        v.upload_shown += (target - v.upload_shown) * (1 - std.math.pow(f64, 0.02, dt));
        if (@abs(target - v.upload_shown) < 0.002) v.upload_shown = target;
        v.widget().queueDraw();
        // It rests until the file gets further, which starts it again.
        if (v.upload_shown != target) return 1;
        v.upload_tick = 0;
        return 0;
    }

    fn pointerIn(v: *const TermView, area: ?[4]f64) bool {
        const r = area orelse return false;
        return v.pointer_in and v.pointer[0] >= r[0] and v.pointer[0] < r[0] + r[2] and v.pointer[1] >= r[1] and v.pointer[1] < r[1] + r[3];
    }

    /// Works out whether the pointer is over the upload's text, which shows its cancel button,
    /// and over the button, where it is a hand. Returns whether either just changed.
    fn syncUploadHover(v: *TermView) bool {
        const hover = v.pointerIn(v.upload_area);
        const hand = v.pointerIn(v.upload_cancel);
        if (hover == v.upload_hover and hand == v.upload_hand) return false;
        v.upload_hover = hover;
        if (hand != v.upload_hand) {
            v.upload_hand = hand;
            v.widget().setCursorFromName(if (hand or v.link_hand) "pointer" else "text");
        }
        return true;
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

    /// Files and images become paths; ordinary text keeps the usual paste safeguards.
    fn pasteFrom(v: *TermView, clipboard: *gdk.Clipboard) void {
        // The view or host could be gone when the clipboard read finishes.
        const ids = gpa.create(PasteTarget) catch return;
        const session_id = gpa.dupe(u8, v.session_id) catch return gpa.destroy(ids);
        const block_id = gpa.dupe(u8, v.block_id) catch {
            gpa.free(session_id);
            return gpa.destroy(ids);
        };
        ids.* = .{ .server = v.server, .session_id = session_id, .block_id = block_id, .widget = undefined };
        ids.widget.init(v.widget().as(gobject.Object));
        switch (clipboardKind(clipboard.getFormats())) {
            .files => clipboard.readValueAsync(gdk.FileList.getGObjectType(), 0, null, &pastedFiles, ids),
            .image => clipboard.readTextureAsync(null, &pastedImage, ids),
            .text => clipboard.readTextAsync(null, &pasted, ids),
        }
    }

    const PasteTarget = struct {
        server: *Server,
        session_id: []u8,
        block_id: []u8,
        widget: gobject.WeakRef,

        fn destroy(t: *PasteTarget) void {
            t.widget.clear();
            gpa.free(t.session_id);
            gpa.free(t.block_id);
            gpa.destroy(t);
        }
    };

    fn pastedFiles(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const t: *PasteTarget = @ptrCast(@alignCast(data.?));
        defer t.destroy();
        const clipboard: *gdk.Clipboard = @ptrCast(source orelse return);
        const value = clipboard.readValueFinish(result, null);
        if (!t.server.isLive()) return;
        const obj = t.widget.get() orelse return;
        defer obj.unref();
        const canvas: *Canvas = @ptrCast(@alignCast(obj));
        const v = canvas.view orelse return;
        const files = listedFiles(value orelse {
            t.server.notifyMessage("Couldn't read the copied file from the clipboard");
            return;
        }) catch {
            t.server.notifyMessage("The clipboard doesn't contain a file");
            return;
        };
        defer gpa.free(files);
        _ = v.insertFiles(files, false);
    }

    fn pastedImage(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const t: *PasteTarget = @ptrCast(@alignCast(data.?));
        const clipboard: *gdk.Clipboard = @ptrCast(source.?);
        const texture = clipboard.readTextureFinish(result, null) orelse {
            if (t.server.isLive()) t.server.notifyMessage("Couldn't read the clipboard image");
            t.destroy();
            return;
        };
        defer texture.as(gobject.Object).unref();
        // PNG encoding and disk IO must not block typing or rendering.
        const task = gio.Task.new(texture.as(gobject.Object), null, &imageSaved, t);
        task.runInThread(&encodeImage);
        task.unref();
    }

    fn encodeImage(task: *gio.Task, source: *gobject.Object, _: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const file = saveClipboardImage(@ptrCast(source)) catch {
            task.returnPointer(null, null);
            return;
        };
        task.returnPointer(file, &discardImage);
    }

    fn discardImage(data: ?*anyopaque) callconv(.c) void {
        const file: *gio.File = @ptrCast(@alignCast(data.?));
        file.deleteAsync(glib.PRIORITY_DEFAULT, null, null, null);
        file.unref();
    }

    fn imageSaved(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const t: *PasteTarget = @ptrCast(@alignCast(data.?));
        defer t.destroy();
        const task: *gio.Task = @ptrCast(result);
        const file: ?*gio.File = @ptrCast(task.propagatePointer(null));
        var inserted = false;
        defer if (file) |f| {
            if (!inserted) f.deleteAsync(glib.PRIORITY_DEFAULT, null, null, null);
            f.unref();
        };
        if (!t.server.isLive()) return;
        const obj = t.widget.get() orelse return;
        defer obj.unref();
        const canvas: *Canvas = @ptrCast(@alignCast(obj));
        const v = canvas.view orelse return;
        const image = file orelse {
            t.server.notifyMessage("Couldn't save the clipboard image as a file");
            return;
        };
        // Local paths must remain readable after paste; remote uploads remove their source.
        inserted = v.insertFiles(&.{image}, true);
    }

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
        defer t.destroy();
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
            v.coast_rows_per_second = 0;
            v.wheelToProgram(t, if (ctl.getUnit() == .surface) dy * settings.current.scroll_speed / v.cell_h else dy, mods);
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

    fn onMotion(motion: *gtk.EventControllerMotion, x: f64, y: f64, v: *TermView) callconv(.c) void {
        v.pointer = .{ x, y };
        v.pointer_in = true;
        if (v.syncUploadHover()) v.widget().queueDraw();
        const held = modsNow(motion) & keys.ctrl != 0;
        if (held or v.link_armed) v.armLink(held);
    }

    fn onLeave(_: *gtk.EventControllerMotion, v: *TermView) callconv(.c) void {
        v.pointer_in = false;
        if (v.syncUploadHover()) v.widget().queueDraw();
        if (v.link_armed) v.armLink(false);
    }

    /// Called when Ctrl goes down or up, and as the pointer moves with it held. Ctrl+click
    /// opens the link under the pointer, so while Ctrl is held that link is shown as one.
    fn armLink(v: *TermView, ctrl: bool) void {
        var armed = ctrl and v.pointer_in;
        var hand = false;
        if (armed) {
            if (v.term()) |t| {
                const cell = v.cellAt(v.pointer[0], v.pointer[1]);
                if (v.linkAt(t, cell[0], cell[1])) |url| {
                    defer gpa.free(url);
                    armed = !t.frame.mouse or v.linksOpenHere() or isFileLink(url);
                    hand = armed;
                }
            } else armed = false;
        }
        if (hand != v.link_hand) {
            v.link_hand = hand;
            v.widget().setCursorFromName(if (hand or v.upload_hand) "pointer" else "text");
        }
        if (armed or v.link_armed) v.widget().queueDraw();
        v.link_armed = armed;
    }

    /// A touchpad flick carries on, slowing down.
    fn onDecelerate(_: *gtk.EventControllerScroll, _: f64, vy: f64, v: *TermView) callconv(.c) void {
        const t = v.term() orelse return;
        if (followsFingers(t)) {
            v.coast_rows_per_second = vy * settings.current.scroll_speed / v.cell_h;
            v.startGlideTick();
            return;
        }
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

    fn followsFingers(t: *const term_mod.Term) bool {
        return settings.current.program_scroll_glide and t.frame.alt_screen;
    }

    fn wheelToProgram(v: *TermView, t: *term_mod.Term, rows: f64, mods: u4) void {
        const following = followsFingers(t);
        const a_step: f64 = if (following) v.glide_rows_a_step else 1;
        v.scroll_rest += rows;
        const whole = v.scroll_rest / a_step;
        const steps = if (!following) @trunc(whole) else if (rows > 0) @ceil(whole) else if (rows < 0) @floor(whole) else 0;
        if (steps != 0) {
            v.scroll_rest -= steps * a_step;
            const cell = v.cellAt(v.pointer[0], v.pointer[1]);
            const col = @min(cell[0], t.frame.cols -| 1);
            const row = @min(cell[1], t.frame.rows -| 1);
            if (following) {
                var left = @abs(steps);
                while (left >= 1) : (left -= 1) v.server.sendWheel(v.session_id, v.block_id, std.math.sign(steps), col, row, keys.modsString(mods));
            } else v.server.sendWheel(v.session_id, v.block_id, steps, col, row, keys.modsString(mods));
        }
        if (!following) return;
        const now = glib.getMonotonicTime();
        v.glide_wheel_us = now;
        if (steps != 0) {
            v.glide_armed_until = now + glide_armed_us;
            v.glide_direction = if (steps > 0) .up else .down;
            v.glide_steps_unanswered += steps;
            v.glide_unanswered += steps * a_step;
            v.glide_asked_us = now;
        }
        v.aimGlide();
        v.startGlideTick();
    }

    fn aimGlide(v: *TermView) void {
        v.glide.target = -(v.scroll_rest + v.glide_unanswered) * v.cell_h;
    }

    fn answered(v: *TermView, rows: isize) void {
        const moved: f64 = @floatFromInt(rows);
        if (v.glide_unanswered * moved <= 0) return;
        const way = std.math.sign(moved);
        const waiting = @max(1, @abs(v.glide_steps_unanswered));
        const steps = std.math.clamp(@round(@abs(moved) / v.glide_rows_a_step), 1, waiting);
        v.scroll_rest -= moved - steps * v.glide_rows_a_step * way;
        v.glide_steps_unanswered -= steps * way;
        if (waiting == 1) {
            const a_step = std.math.clamp(@abs(moved), 1, most_rows_a_step);
            if (perf_log and a_step != v.glide_rows_a_step) std.log.info("glide: {d} rows a step", .{a_step});
            v.glide_rows_a_step = a_step;
        }
        v.glide_unanswered = v.glide_steps_unanswered * v.glide_rows_a_step;
        v.aimGlide();
    }

    pub fn picture(v: *TermView, scale: f32) ?*gsk.RenderNode {
        const own = gtk.Snapshot.new();
        own.scale(scale, scale);
        snapshotTermImpl(v, own);
        return own.freeToNode();
    }

    pub fn coastBy(v: *TermView, rows_per_second: f64) void {
        const t = v.term() orelse return;
        if (!followsFingers(t)) return;
        v.pointer = .{ @as(f64, @floatFromInt(v.widget().getWidth())) / 2, @as(f64, @floatFromInt(v.widget().getHeight())) / 2 };
        v.coast_rows_per_second = rows_per_second;
        v.startGlideTick();
    }

    pub fn wheelBy(v: *TermView, rows: f64) void {
        const t = v.term() orelse return;
        v.pointer = .{ @as(f64, @floatFromInt(v.widget().getWidth())) / 2, @as(f64, @floatFromInt(v.widget().getHeight())) / 2 };
        if (t.frame.mouse or t.frame.alt_screen) v.wheelToProgram(t, rows, 0);
    }

    fn startGlideTick(v: *TermView) void {
        if (v.glide_tick != 0) return;
        v.glide_frame_us = 0;
        v.glide_tick = v.widget().addTickCallback(&glideTick, v, null);
    }

    fn glideTick(_: *gtk.Widget, clock: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        const now = clock.getFrameTime();
        const seconds: f64 = if (v.glide_frame_us == 0) 1.0 / 60.0 else @min(0.05, @as(f64, @floatFromInt(now - v.glide_frame_us)) / 1e6);
        v.glide_frame_us = now;
        const clock_now = glib.getMonotonicTime();
        if (v.coast_rows_per_second != 0) {
            if (v.term()) |t| v.wheelToProgram(t, v.coast_rows_per_second * seconds, 0);
            v.coast_rows_per_second *= std.math.pow(f64, coast_fade_per_second, seconds);
            if (@abs(v.coast_rows_per_second) * v.cell_h < coast_slowest_px_per_second) v.coast_rows_per_second = 0;
        }
        if (v.glide_unanswered != 0 and clock_now - v.glide_asked_us > glide_unanswered_us) {
            v.glide_unanswered = 0;
            v.glide_steps_unanswered = 0;
        }
        if (v.coast_rows_per_second == 0 and clock_now - v.glide_wheel_us > glide_fingers_gone_us) v.scroll_rest = 0;
        v.aimGlide();
        const easing = v.glide.ease(seconds, v.cell_h);
        v.widget().queueDraw();
        if (easing or v.coast_rows_per_second != 0 or v.scroll_rest != 0 or v.glide_unanswered != 0) return 1;
        v.glide_tick = 0;
        return 0;
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
        const button = gesture.as(gtk.GestureSingle).getCurrentButton();
        // An upload's cancel button keeps its click from the program and from selecting.
        v.pointer = .{ x, y };
        v.pointer_in = true;
        _ = v.syncUploadHover();
        v.upload_press = button == 1 and v.upload_hand;
        if (v.upload_press) {
            if (upload_ui.find(v.server, v.block_id)) |up| up.cancel();
            return;
        }
        const t = v.term() orelse return;
        const mods = modsNow(gesture);
        const cell = v.cellAt(x, y);
        // The release opens the link here, so the program never hears of the click.
        if (button == 1 and v.keepsLinkClick(t, mods, cell)) return;
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
        if (v.upload_press) {
            v.upload_press = false;
            return;
        }
        const t = v.term() orelse return;
        const mods = modsNow(gesture);
        const cell = v.cellAt(x, y);
        if (gesture.as(gtk.GestureSingle).getCurrentButton() == 1 and v.keepsLinkClick(t, mods, cell)) {
            if (n_press != 1 or v.selecting) return;
            if (v.linkAt(t, cell[0], cell[1])) |url| {
                defer gpa.free(url);
                v.link_cell = cell;
                v.openLink(url);
            }
            return;
        }
        if (v.programHasMouse(mods)) {
            v.server.sendMouse(v.session_id, v.block_id, "release", buttonName(gesture), cell[0], cell[1], keys.modsString(mods));
            return;
        }
        if (gesture.as(gtk.GestureSingle).getCurrentButton() != 1 or n_press != 1 or v.selecting) return;
        // Ctrl+click opens a link; a plain click drops the selection.
        if (mods & keys.ctrl != 0) {
            if (v.linkAt(t, cell[0], cell[1])) |url| {
                defer gpa.free(url);
                v.link_cell = cell;
                v.openLink(url);
                return;
            }
        }
        t.clearSelection();
        v.widget().queueDraw();
    }

    /// Whether the pane shows another computer: anything not reached through a socket here.
    fn onRemoteHost(v: *const TermView) bool {
        return !std.mem.startsWith(u8, v.server.url, "unix://");
    }

    fn linksOpenHere(v: *const TermView) bool {
        return !v.onRemoteHost() or settings.current.remote_links_here;
    }

    /// Ctrl+click opens a recognized link even when the local program takes the mouse.
    /// Remote panes can opt out, but file previews still belong to Renux.
    fn keepsLinkClick(v: *TermView, t: *term_mod.Term, mods: u4, cell: struct { u16, u16 }) bool {
        if (mods & keys.ctrl == 0 or !v.programHasMouse(mods)) return false;
        const url = v.linkAt(t, cell[0], cell[1]) orelse return false;
        defer gpa.free(url);
        return isFileLink(url) or v.linksOpenHere();
    }

    fn hyperlinkTarget(t: *term_mod.Term, col: u16, row: u16) ?[:0]u8 {
        if (t.hyperlinkAt(col, row)) |u| {
            // Coding agents link the files they mention, often by a bare path such as
            // src/main.zig: that is a file on the pane's host, not an address to open.
            const file = (paths.fromHref(gpa, u) catch null) orelse return u;
            defer gpa.free(file);
            defer gpa.free(u);
            // The link seldom says which line; the text after it often does, as in the
            // src/main.zig:42-60 of a tool's own report, where only the path is the link.
            const named = std.mem.indexOfScalar(u8, file[paths.prefix.len..], ':') != null;
            const line: ?u32 = if (named) null else lineAfterLink(t, u, col, row);
            var buf: [16]u8 = undefined;
            const suffix = if (line) |n| std.fmt.bufPrint(&buf, ":{d}", .{n}) catch "" else "";
            return std.mem.concatWithSentinel(gpa, u8, &.{ file, suffix }, 0) catch null;
        }
        return null;
    }

    /// The link at a cell: an OSC 8 hyperlink, or a path or address written in the text.
    fn linkAt(v: *TermView, t: *term_mod.Term, col: u16, row: u16) ?[:0]u8 {
        _ = v;
        if (hyperlinkTarget(t, col, row)) |url| return url;
        var link = textLinkAt(t, col, row) orelse return null;
        defer link.deinit(gpa);
        return gpa.dupeSentinel(u8, link.url, 0) catch null;
    }

    /// The line number written straight after a program's link on its row, as `:42`.
    fn lineAfterLink(t: *term_mod.Term, uri: []const u8, col: u16, row: u16) ?u32 {
        const f = &t.frame;
        if (row >= f.rows) return null;
        // The link's last cell: the cells after `col` that point at the same place.
        var x: usize = col;
        while (x + 1 < f.cols) : (x += 1) {
            const next = t.hyperlinkAt(@intCast(x + 1), row) orelse break;
            defer gpa.free(next);
            if (!std.mem.eql(u8, next, uri)) break;
        }
        x += 1;
        if (x >= f.cols or f.cell(x, row).cp != ':') return null;
        var n: u32 = 0;
        var digits: usize = 0;
        while (x + 1 + digits < f.cols and digits < 7) : (digits += 1) {
            const cp = f.cell(x + 1 + digits, row).cp;
            if (cp < '0' or cp > '9') break;
            n = n * 10 + @as(u32, @intCast(cp - '0'));
        }
        return if (digits == 0 or n == 0) null else n;
    }

    /// The web address written in the text at a cell, with the cells it covers.
    fn textLinkAt(t: *term_mod.Term, col: u16, row: u16) ?links.Link {
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
        if (links.at(gpa, casted, f.wraps.items, col, row) catch null) |link| return link;
        return paths.at(gpa, casted, f.wraps.items, col, row) catch null;
    }

    /// Underlines the web address under the pointer while Ctrl is held. A hyperlink a program
    /// marked as one is underlined already.
    fn drawArmedLink(v: *TermView, sn: *gtk.Snapshot, t: *term_mod.Term, frac: f64) void {
        const f = &t.frame;
        const cell = v.cellAt(v.pointer[0], v.pointer[1]);
        if (cell[0] >= f.cols or cell[1] >= f.rows or f.cell(cell[0], cell[1]).flags.link) return;
        var link = textLinkAt(t, cell[0], cell[1]) orelse return;
        defer link.deinit(gpa);
        for (link.segments.items) |seg| {
            if (seg.row >= f.rows or seg.start >= f.cols) continue;
            const top = pad_y + frac + @as(f64, @floatFromInt(seg.row)) * v.cell_h;
            const color = cellColors(f, f.cell(seg.start, seg.row)).fg;
            fillRect(sn, color, 1, pad_x + @as(f64, @floatFromInt(seg.start)) * v.cell_w, top + v.baseline + 1.5, @as(f64, @floatFromInt(seg.end + 1 - seg.start)) * v.cell_w, 1);
        }
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
        const mods = modsNow(gesture);
        const hit = v.cellAt(x, y);
        v.drag_to_program = v.programHasMouse(mods) and !(if (v.term()) |t| v.keepsLinkClick(t, mods, hit) else false);
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
            inline for (.{ .{ "copy", menuCopy }, .{ "paste", menuPaste }, .{ "open-link", menuOpenLink }, .{ "copy-link", menuCopyLink }, .{ "copy-output", menuCopyOutput }, .{ "preview-selection", menuPreviewSelection } }) |e| {
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
        if (sel != null) {
            edit.append("Copy", "pane.copy");
            edit.append("Preview Selected Path", "pane.preview-selection");
        }
        edit.append("Paste", "pane.paste");
        v.menu_cell = cell;
        edit.append("Copy Output", "pane.copy-output");
        menu.appendSection(null, edit.as(gio.MenuModel));
        if (v.menu_link != null) {
            const link = gio.Menu.new();
            defer link.unref();
            link.append(if (isFileLink(v.menu_link.?)) "Preview File" else "Open Link", "pane.open-link");
            link.append(if (isFileLink(v.menu_link.?)) "Copy Path" else "Copy Link", "pane.copy-link");
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

    fn menuPreviewSelection(v: *TermView) void {
        const t = v.term() orelse return;
        const text = t.selectionText() orelse return;
        defer gpa.free(text);
        const path = std.mem.trim(u8, text, " \t\r\n\"'`");
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, '\n') != null) return;
        @import("../ui/preview.zig").show(v.widget(), v.server, v.session_id, v.block_id, path);
    }

    /// Shows a small look at a file by the link that names it. `target` may end in `:LINE`.
    fn peekFile(v: *TermView, target: []const u8) void {
        const at: gdk.Rectangle = .{
            .f_x = @intFromFloat(pad_x + @as(f64, @floatFromInt(v.link_cell[0])) * v.cell_w),
            .f_y = @intFromFloat(pad_y + v.draw_frac + @as(f64, @floatFromInt(v.link_cell[1])) * v.cell_h),
            .f_width = @intFromFloat(v.cell_w),
            .f_height = @intFromFloat(v.cell_h),
        };
        peek.show(v.widget(), at, v.server, v.session_id, v.block_id, target);
    }

    /// Files and links on the visible screen, without duplicates or a read of the filesystem.
    pub fn screenLinks(v: *TermView) ![]ScreenLink {
        return screenLinksIn(v.term() orelse return gpa.alloc(ScreenLink, 0));
    }

    fn screenLinksIn(t: *term_mod.Term) ![]ScreenLink {
        const f = &t.frame;
        var rows: std.ArrayList([]const u21) = .empty;
        defer {
            for (rows.items) |r| gpa.free(r);
            rows.deinit(gpa);
        }
        for (0..f.rows) |y| {
            const r = try gpa.alloc(u21, f.cols);
            errdefer gpa.free(r);
            for (0..f.cols) |x| r[x] = @intCast(@min(f.cell(x, y).cp, 0x10ffff));
            try rows.append(gpa, r);
        }
        var found: std.ArrayList(ScreenLink) = .empty;
        errdefer {
            for (found.items) |l| gpa.free(l.url);
            found.deinit(gpa);
        }
        for (0..f.rows) |y| {
            var x: usize = 0;
            while (x < f.cols) : (x += 1) {
                const cell = f.cell(x, y);
                if (cell.cp == 0 or cell.cp == ' ') continue;
                var url: ?[:0]u8 = null;
                if (cell.flags.link) {
                    url = hyperlinkTarget(t, @intCast(x), @intCast(y));
                } else {
                    var link = (try links.at(gpa, rows.items, f.wraps.items, x, y)) orelse
                        (try paths.at(gpa, rows.items, f.wraps.items, x, y)) orelse continue;
                    defer link.deinit(gpa);
                    url = try gpa.dupeSentinel(u8, link.url, 0);
                    for (link.segments.items) |seg| if (seg.row == y) {
                        x = @max(x, seg.end);
                    };
                }
                const target = url orelse continue;
                const duplicate = for (found.items) |l| {
                    if (std.mem.eql(u8, l.url, target)) break true;
                } else false;
                if (duplicate) {
                    gpa.free(target);
                    continue;
                }
                errdefer gpa.free(target);
                try found.append(gpa, .{ .url = target, .cell = .{ @intCast(x), @intCast(y) } });
            }
        }
        return found.toOwnedSlice(gpa);
    }

    pub fn previewLink(v: *TermView, url: [:0]const u8, cell: [2]u16) void {
        v.link_cell = cell;
        v.openLink(url);
    }

    /// Opens the link at a cell as Ctrl+click does; for the development script.
    pub fn openLinkAt(v: *TermView, col: u16, row: u16) void {
        const t = v.term() orelse return;
        const url = v.linkAt(t, col, row) orelse return;
        defer gpa.free(url);
        v.link_cell = .{ col, row };
        v.openLink(url);
    }

    fn isFileLink(url: []const u8) bool {
        return std.mem.startsWith(u8, url, paths.prefix) or std.mem.startsWith(u8, url, "file://");
    }

    fn menuOpenLink(v: *TermView) void {
        const l = v.menu_link orelse return;
        v.link_cell = v.menu_cell;
        v.openLink(l);
    }

    /// Opens a link. Web, mail and file links open at once; one that opens an app, such as
    /// vscode:, asks first unless its scheme was trusted with Always Open.
    fn openLink(v: *TermView, url: [:0]const u8) void {
        if (std.mem.startsWith(u8, url, paths.prefix)) return v.peekFile(url[paths.prefix.len..]);
        if (std.mem.startsWith(u8, url, "file://")) {
            // OSC 8 file links belong to this pane's host, not the desktop's filesystem.
            const start = std.mem.indexOfScalarPos(u8, url, 7, '/') orelse return;
            const encoded = gpa.dupeSentinel(u8, url[start..], 0) catch return;
            defer gpa.free(encoded);
            const path = glib.Uri.unescapeString(encoded.ptr, null) orelse return;
            defer glib.free(path);
            return v.peekFile(std.mem.span(path));
        }
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return;
        const scheme = url[0..colon];
        const plain = for ([_][]const u8{ "http", "https", "mailto", "file" }) |w| {
            if (std.ascii.eqlIgnoreCase(scheme, w)) break true;
        } else false;
        const trusted = for (settings.current.trusted_schemes.items) |t| {
            if (std.ascii.eqlIgnoreCase(t, scheme)) break true;
        } else false;
        const root: ?*gtk.Window = @ptrCast(@alignCast(v.widget().getRoot()));
        const forward = @import("../rex/forward.zig");
        if (forward.remoteLink(v.server.url, url)) return forward.open(v.server, v.session_id, url, root);
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
        v.widget().getClipboard().setText(if (std.mem.startsWith(u8, l, paths.prefix)) l[paths.prefix.len..].ptr else l.ptr);
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
        // Keyboard yanks restore another viewport immediately, so there is no text to lift there.
        if (v.copy_mode == null and !primary and text.len > 0 and settings.current.copy_animation) v.startCopyAnimation(t);
    }

    /// The copied text lifts off the pane and a glint runs across it to its far edge, as Rex
    /// does. The selection may be cleared the moment it's copied, so the pane as it is now,
    /// selection and all, is kept to draw it from.
    fn startCopyAnimation(v: *TermView, t: *term_mod.Term) void {
        // An earlier copy's lift isn't part of this one's picture.
        v.endCopyAnimation();
        // The frame is the pane as it was last drawn. A selection made since then isn't in it:
        // the third click of a triple-click selects the line and copies it at once, with the
        // frame still showing the word the second click selected. The terminal is read again,
        // so what lifts is what was copied.
        _ = t.render(true);
        const f = &t.frame;
        var row: usize = 0;
        while (row < f.rows) : (row += 1) {
            var x: usize = 0;
            while (x < f.cols) {
                if (!f.cell(x, row).flags.selected) {
                    x += 1;
                    continue;
                }
                const start = x;
                while (x < f.cols and f.cell(x, row).flags.selected) x += 1;
                v.copy_spans.append(gpa, .{ .row = @intCast(row), .x0 = @intCast(start), .x1 = @intCast(x) }) catch {};
            }
        }
        if (v.copy_spans.items.len == 0) return;
        // Taking the picture draws the pane, and a draw ends a lift whose text has moved: the
        // text counts as being where it is now, before the picture and again after it.
        v.copy_anchor = v.textAnchor();
        const own = gtk.Snapshot.new();
        snapshotTermImpl(v, own);
        v.copy_node = own.freeToNode() orelse return v.endCopyAnimation();
        v.copy_top = pad_y + v.draw_frac;
        v.copy_anchor = v.textAnchor();
        v.copy_started = glib.getMonotonicTime();
        if (v.copy_tick == 0) v.copy_tick = v.widget().addTickCallback(&copyTick, v, null);
        v.widget().queueDraw();
    }

    /// A number that stays the same for as long as the text on screen stays where it is: it
    /// changes when the pane is scrolled, and when new output pushes the text up. Output that
    /// arrives while looking back through history moves nothing, and doesn't change it.
    fn textAnchor(v: *TermView) f64 {
        return v.scroll_px - @as(f64, @floatFromInt(v.last_total)) * v.cell_h;
    }

    /// The lift is drawn from a picture of where the copied text was. Once the text has moved,
    /// the picture would hang over other text, so the lift ends there.
    fn dropMovedCopy(v: *TermView) void {
        // No picture yet means the copy is only now being taken, and nothing has moved.
        if (v.copy_node == null) return;
        if (@abs(v.textAnchor() - v.copy_anchor) > 0.5) v.endCopyAnimation();
    }

    pub fn endCopyAnimation(v: *TermView) void {
        if (v.copy_node) |n| n.unref();
        v.copy_node = null;
        v.copy_spans.clearRetainingCapacity();
    }

    fn copyTick(w: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const v: *TermView = @ptrCast(@alignCast(data.?));
        w.queueDraw();
        if (glib.getMonotonicTime() - v.copy_started < copy_duration_us) return 1;
        v.copy_tick = 0;
        v.endCopyAnimation();
        return 0;
    }

    fn pastePrimary(v: *TermView) void {
        v.pasteFrom(v.widget().getPrimaryClipboard());
    }

    fn onFocusIn(_: *gtk.EventControllerFocus, v: *TermView) callconv(.c) void {
        // The pane is being looked at, by a click, a key, its tab being picked or the window
        // coming to the front: whatever finished or rang in it has been seen.
        v.server.clearAttention(v.block_id);
        v.im.as(gtk.IMContext).focusIn();
        v.server.sendFocus(v.session_id, v.block_id, true);
        if (on_mode_changed) |f| f();
        v.widget().queueDraw();
    }

    fn onFocusOut(_: *gtk.EventControllerFocus, v: *TermView) callconv(.c) void {
        // Keys still down come up for the program now: their real release goes elsewhere.
        while (v.held_len > 0) v.releaseKey(v.held[0].keycode);
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
        // An image placed with placeholder characters comes as one strip per row of text. Each
        // strip's edges are moved onto the screen's pixels, so two strips share an edge exactly
        // and nothing shows through between them.
        const left = pad_x + @as(f64, @floatFromInt(im.col)) * v.cell_w + @as(f64, @floatFromInt(im.off_x));
        const top = pad_y + frac + @as(f64, @floatFromInt(im.row)) * v.cell_h + @as(f64, @floatFromInt(im.off_y));
        const x = pixelX(v, left);
        const y = pixelY(v, top);
        const dw = pixelX(v, left + @as(f64, @floatFromInt(im.width))) - x;
        const dh = pixelY(v, top + @as(f64, @floatFromInt(im.height))) - y;
        if (dw <= 0 or dh <= 0) continue;
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

const HeldKey = struct { keycode: c_uint, key: keys.Key };

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
    setTextAttrs(layout, px);
}

/// Gives a layout what the settings ask of every run of text: `px` between its characters,
/// and the font's features.
pub fn setTextAttrs(layout: *pango.Layout, px: f64) void {
    var buf: [512]u8 = undefined;
    const features = fontFeatures(&buf, settings.current.ligatures, settings.current.font_features);
    if (px == 0 and features == null) return layout.setAttributes(null);
    const list = pango.AttrList.new();
    defer list.unref();
    if (px != 0) list.insert(pango.attrLetterSpacingNew(@intFromFloat(@round(px * pango.SCALE))));
    if (features) |z| list.insert(pango.AttrFontFeatures.new(z.ptr));
    layout.setAttributes(list);
}

/// The OpenType features asked of the font: ligatures off when they are, then the ones named
/// in the settings, which come last and so win.
fn fontFeatures(buf: []u8, ligatures: bool, named_raw: []const u8) ?[:0]const u8 {
    const off = if (ligatures) "" else "liga 0, clig 0, calt 0, dlig 0";
    const named = std.mem.trim(u8, named_raw, " ,");
    if (off.len == 0 and named.len == 0) return null;
    return std.fmt.bufPrintSentinel(buf, "{s}{s}{s}", .{ off, if (off.len > 0 and named.len > 0) ", " else "", named }, 0) catch null;
}

test "font features join the ligature switch and the named ones" {
    var buf: [128]u8 = undefined;
    try std.testing.expect(fontFeatures(&buf, true, "") == null);
    try std.testing.expect(fontFeatures(&buf, true, " , ") == null);
    try std.testing.expectEqualStrings("ss01, zero", fontFeatures(&buf, true, " ss01, zero,").?);
    try std.testing.expectEqualStrings("liga 0, clig 0, calt 0, dlig 0", fontFeatures(&buf, false, "").?);
    try std.testing.expectEqualStrings("liga 0, clig 0, calt 0, dlig 0, ss01", fontFeatures(&buf, false, "ss01").?);
}

/// Sets a layout up to draw in `face`. `faceDone` puts it back after the drawing.
fn useFace(v: *TermView, layout: *pango.Layout, f_font: Font, face: Face) void {
    layout.setFontDescription(f_font.of(face));
    const px = v.face_spacing[@backingInt(face)];
    if (px != v.spacing) setTextAttrs(layout, px);
}

fn faceDone(v: *TermView, layout: *pango.Layout, face: Face) void {
    if (v.face_spacing[@backingInt(face)] != v.spacing) setTextAttrs(layout, v.spacing);
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

/// A file being sent to this pane's machine, as text that isn't typed yet: dim, in the cells
/// after the cursor, where Rex will paste the file's path. It ends with the file's name, as the
/// path will, and turns green from the left as the file goes. When the cursor isn't on screen
/// it sits in the bottom corner instead.
fn drawUploadGhost(v: *TermView, sn: *gtk.Snapshot, f: *const term_mod.Frame, f_font: Font, w: f64, h: f64) void {
    v.upload_area = null;
    v.upload_cancel = null;
    const up = upload_ui.find(v.server, v.block_id) orelse {
        _ = v.syncUploadHover();
        return;
    };
    // The pane that began the upload has gone, and this one shows the same terminal.
    if (up.watcher == null) {
        up.watcher = .{ .ctx = v, .changed = TermView.uploadChanged };
        v.upload_shown = up.fraction();
    }

    var status_buf: [8]u8 = undefined;
    const status: []const u8 = if (up.finishing) "" else if (up.percent) |pc| std.fmt.bufPrint(&status_buf, "{d}%", .{pc}) catch "" else "";
    var name_buf: [300]u8 = undefined;
    // Several files show as the first and how many more: their paths land one after another.
    var more: [16]u8 = undefined;
    const and_more = if (up.others() == 0) "" else std.fmt.bufPrint(&more, " +{d}", .{up.others()}) catch "";
    const label = std.fmt.bufPrint(&name_buf, "…/{s}{s}", .{ up.name(), and_more }) catch "…/file";
    // Cells after the name: a gap and the percentage, then a gap and the cancel button. Once
    // everything is sent there is no button: a cancel could no longer tell whether the file
    // arrived.
    const status_cells: f64 = if (status.len > 0) @floatFromInt(1 + status.len) else 0;
    const cancel_cells: f64 = if (up.finishing) 0 else 3;

    const at_cursor = f.cursor_visible and f.cursor_y < f.rows and f.cursor_x < f.cols and f.scroll_offset + f.scroll_len >= f.scroll_total;
    // A bar or an underline leaves its cell free for the text; a block or an outline fills it.
    const style: c_int = switch (settings.current.cursor_style) {
        .program => f.cursor_style,
        .bar => 0,
        .block => 1,
        .underline => 2,
    };
    const beside = (style != 0 and style != 2) or v.widget().hasFocus() == 0;
    var first: usize = @as(usize, f.cursor_x) + @intFromBool(beside);
    var row: usize = f.cursor_y;
    // Text with no room left on its line carries on at the start of the next, as typed text
    // does. Eight cells of the name is the least that still says which file it is, and the
    // room is reckoned for the longest percentage, so the text doesn't change lines halfway.
    const least = 8 + 5 + 3;
    if (at_cursor and @as(f64, @floatFromInt(@as(usize, f.cols) -| first)) < least and row + 1 < f.rows) {
        first = 0;
        row += 1;
    }
    const start = pad_x + @as(f64, @floatFromInt(first)) * v.cell_w;

    const layout = layoutOf(v);
    layout.setFontDescription(f_font.regular);
    // A long name is shortened in the middle, to what the rest of the line has room for, so its
    // start and its extension both show.
    const room = if (at_cursor) @as(f64, @floatFromInt(@as(usize, f.cols) -| first)) * v.cell_w else w - 2 * pad_x;
    const name_max = @max(v.cell_w * 8, @min(v.cell_w * 30, room - (status_cells + cancel_cells) * v.cell_w));
    layout.setText(@ptrCast(label.ptr), @intCast(label.len));
    layout.setWidth(@intFromFloat(name_max * pango.SCALE));
    layout.setEllipsize(.middle);
    var tw: c_int = 0;
    var th: c_int = 0;
    layout.getPixelSize(&tw, &th);
    const name_w: f64 = @floatFromInt(tw);
    // Everything after the name stays on the grid of cells.
    const name_cells = @ceil(name_w / v.cell_w);
    const cells = name_cells + status_cells + cancel_cells;
    const width = cells * v.cell_w;

    const right = w - pad_x - width;
    const x = @max(pad_x, if (at_cursor) @min(start, right) else right);
    const y = if (at_cursor) pad_y + @as(f64, @floatFromInt(row)) * v.cell_h else h - pad_y - v.cell_h;
    if (cancel_cells > 0) {
        v.upload_area = .{ x, y, width, v.cell_h };
        v.upload_cancel = .{ x + width - 2 * v.cell_w, y, 2 * v.cell_w, v.cell_h };
    }
    _ = v.syncUploadHover();

    // Over empty cells the text needs nothing behind it, which is what makes it part of the
    // line. Anywhere else it covers what it is drawn over.
    var covers = !at_cursor or x != start;
    if (!covers) {
        const until = @min(@as(usize, f.cols), first + @as(usize, @intFromFloat(cells)));
        for (first..until) |col| {
            const cp = f.cell(col, row).cp;
            if (cp != 0 and cp != ' ') covers = true;
        }
    }
    if (covers) fillRect(sn, f.bg, 1, x, y, width, v.cell_h);
    if (v.upload_hover) {
        const area: graphene.Rect = .{ .f_origin = .{ .f_x = @floatCast(x), .f_y = @floatCast(y) }, .f_size = .{ .f_width = @floatCast(width), .f_height = @floatCast(v.cell_h) } };
        var shape: gsk.RoundedRect = undefined;
        _ = shape.initFromRect(&area, 3);
        sn.pushRoundedClip(&shape);
        fillRect(sn, f.fg, 0.1, x, y, width, v.cell_h);
        if (v.upload_hand) fillRect(sn, f.fg, 0.14, x + width - 2 * v.cell_w, y, 2 * v.cell_w, v.cell_h);
        sn.pop();
    }

    const ink = rgba(f.fg, 1);
    const dim = rgba(f.fg, 0.42);
    // Green enough to read on this background when the theme has none of its own.
    const green: u32 = if (theme_green != 0) theme_green else if (luminance(f.bg) > 0.4) 0x1f7a34 else 0x8ae234;
    // Only the pane that is told of the file's progress eases toward it.
    const eased = if (up.watcher) |watcher| watcher.ctx == @as(*anyopaque, @ptrCast(v)) else false;
    const done = std.math.clamp(if (eased) v.upload_shown else up.fraction(), 0, 1);
    layoutOnBaseline(sn, layout, dim, x, y + v.baseline);
    // The green part ends softly, over a cell and a half, in strips that each show less of it.
    const edge = name_w * done;
    const soft = @min(v.cell_w * 1.5, edge);
    const strips = 6;
    for (0..strips + 1) |i| {
        const from = if (i == 0) 0 else edge - soft + soft * @as(f64, @floatFromInt(i - 1)) / strips;
        const to = if (i == 0) edge - soft else edge - soft + soft * @as(f64, @floatFromInt(i)) / strips;
        if (to <= from) continue;
        const alpha = if (i == 0) 1 else 1 - @as(f64, @floatFromInt(i)) / (strips + 1);
        sn.pushClip(&.{ .f_origin = .{ .f_x = @floatCast(x + from), .f_y = @floatCast(y) }, .f_size = .{ .f_width = @floatCast(to - from), .f_height = @floatCast(v.cell_h) } });
        layoutOnBaseline(sn, layout, rgba(green, alpha), x, y + v.baseline);
        sn.pop();
    }
    // The layout is shared with everything else the pane draws, which is never shortened.
    layout.setWidth(-1);
    layout.setEllipsize(.none);
    if (status.len > 0) {
        layout.setText(@ptrCast(status.ptr), @intCast(status.len));
        layoutOnBaseline(sn, layout, dim, x + (name_cells + 1) * v.cell_w, y + v.baseline);
    }
    if (v.upload_hover) {
        layout.setText("×", -1);
        layout.getPixelSize(&tw, &th);
        layoutOnBaseline(sn, layout, ink, x + width - v.cell_w - @as(f64, @floatFromInt(tw)) / 2, y + v.baseline);
    }
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
    hasher.update(std.mem.asBytes(&[_]u64{ f_font.id, @bitCast(v.cell_w), @bitCast(v.cell_h), f.fg, f.bg, f.cols, @intFromBool(prefs.improve_contrast), @intFromBool(prefs.rounded_selection), @bitCast(pad_x), @intFromBool(prefs.ligatures), @backingInt(prefs.bold_italic), prefs.selection_bg, prefs.selection_fg, @intFromBool(prefs.font_smoothing) }));
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
    // Cell backgrounds are drawn for all rows at once, under these (`drawBackgrounds`).
    var x: usize = 0;
    // Text, in runs of one style. Anything outside ASCII is placed on its own cell, since
    // fallback fonts don't keep to the grid.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    x = 0;
    while (x < f.cols) {
        const cl = f.cell(x, y);
        if (cl.cp == 0 or cl.cp == ' ' or cl.cp == term_mod.image_placeholder or cl.flags.spacer or cl.flags.invisible) {
            x += 1;
            continue;
        }
        // Block characters are filled each frame by `drawBlocks`, not kept with the row.
        if (boxdraw.isBlock(cl.cp)) {
            x += 1;
            continue;
        }
        if (boxdraw.handles(cl.cp)) {
            const left = pad_x + @as(f64, @floatFromInt(x)) * v.cell_w;
            const color = cellColors(f, cl).fg;
            const alpha: f64 = if (cl.flags.faint) 0.6 else 1;
            // A run of one horizontal line is drawn as one stroke.
            var run: usize = 1;
            if (boxdraw.isHorizontal(cl.cp)) {
                while (x + run < f.cols) : (run += 1) {
                    const n = f.cell(x + run, y);
                    if (n.cp != cl.cp or n.flags.faint != cl.flags.faint or n.flags.invisible or cellColors(f, n).fg != color) break;
                }
            }
            const width = @as(f64, @floatFromInt(run)) * v.cell_w;
            // Straight lines and corners end at the same snapped pixel edge so they meet.
            const snap_left = pixelX(v, left);
            const snap_right = pixelX(v, left + width);
            var rects: [8]boxdraw.Rect = undefined;
            if (boxdraw.lineRects(cl.cp, left, 0, width, v.cell_h, &rects)) |strokes| {
                for (strokes) |r| {
                    const x0 = if (r.x0 == left) snap_left else r.x0;
                    const x1 = if (r.x1 == left + width) snap_right else r.x1;
                    fillRect(sn, color, alpha, x0, r.y0, x1 - x0, r.y1 - r.y0);
                }
            } else if (boxdraw.roundedPath(cl.cp, left, width, v.cell_h, .{ snap_left, snap_right })) |path| {
                defer path.unref();
                const stroke = gsk.Stroke.new(@floatCast(boxdraw.lineThickness(v.cell_h)));
                defer stroke.free();
                sn.appendStroke(path, stroke, &rgba(color, alpha));
            } else {
                const cr = sn.appendCairo(&.{ .f_origin = .{ .f_x = @floatCast(left - 1), .f_y = 0 }, .f_size = .{ .f_width = @floatCast(v.cell_w + 2), .f_height = @floatCast(v.cell_h) } });
                setColor(cr, color, alpha);
                boxdraw.draw(cr, cl.cp, left, 0, v.cell_w, v.cell_h);
                cr.destroy();
            }
            x += run;
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
        text.append(gpa, 0) catch break;
        const face = Font.faceOf(cl.flags);
        useFace(v, layout, f_font, face);
        layout.setText(@ptrCast(text.items.ptr), @intCast(text.items.len - 1));
        const alpha: f64 = if (cl.flags.faint) 0.6 else 1;
        layoutOnBaseline(sn, layout, rgba(colors.fg, alpha), left, v.baseline);
        faceDone(v, layout, face);
        const run_w = @as(f64, @floatFromInt(x - start)) * v.cell_w;
        if (cl.flags.underline or cl.flags.link) fillRect(sn, colors.fg, alpha, left, v.baseline + 1.5, run_w, 1);
        if (cl.flags.strike) fillRect(sn, colors.fg, alpha, left, v.cell_h / 2, run_w, 1);
    }
    return sn.freeToNode();
}

/// The background of each cell that has one of its own, for `rows` rows from the one at `top`,
/// drawn together. Each color is one shape made of its runs of cells, each a hair taller than a
/// row so they overlap, filled at once: rows that meet show no seam, as they did when each row
/// painted its own at a fractional height and both edges came out half drawn. With rounded
/// selection on, a selection rounds only the corners with nothing selected beyond them, so the
/// whole selection is rounded on its outside rather than each line of it.
/// Finds where the pane sits on the screen's pixels, for `pixelX` and `pixelY`.
fn findPixels(v: *TermView) void {
    v.pixel_origin = .{ 0, 0 };
    v.pixel_scale = 1;
    const w = v.widget();
    const native = w.getNative() orelse return;
    if (native.getSurface()) |surface| v.pixel_scale = surface.getScale();
    if (shotScale()) |scale| v.pixel_scale = scale;
    var at: graphene.Point = undefined;
    if (w.computePoint(native.as(gtk.Widget), &.{ .f_x = 0, .f_y = 0 }, &at) == 0) return;
    var dx: f64 = 0;
    var dy: f64 = 0;
    native.getSurfaceTransform(&dx, &dy);
    v.pixel_origin = .{ at.f_x + dx, at.f_y + dy };
}

/// The scale a development screenshot is drawn at, when one is asked for: the hidden display
/// it is taken on has a scale of its own, usually 1, and what is lined up with pixels has to
/// be lined up with the screenshot's to be judged in it. Null outside development builds.
pub fn shotScale() ?f64 {
    if (!@import("build_options").dev) return null;
    const text = std.c.getenv("RENUX_SHOT_SCALE") orelse return null;
    const scale = std.fmt.parseFloat(f64, std.mem.span(text)) catch return null;
    return std.math.clamp(scale, 1, 4);
}

/// A horizontal place in the pane, moved to the nearest edge between two screen pixels.
/// Cells are rarely a whole number of pixels wide or tall, least of all on a screen scaled by
/// a fraction. A filled cell whose edge falls inside a pixel covers that pixel only in part,
/// and so does its neighbour: what is behind shows through, as a faint line between two
/// blocks that should touch. With every edge on the pixel grid, neighbours share an edge
/// exactly.
fn pixelX(v: *const TermView, x: f64) f64 {
    return @round((x + v.pixel_origin[0]) * v.pixel_scale) / v.pixel_scale - v.pixel_origin[0];
}

fn pixelY(v: *const TermView, y: f64) f64 {
    return @round((y + v.pixel_origin[1]) * v.pixel_scale) / v.pixel_scale - v.pixel_origin[1];
}

/// Fills the block characters of some rows: halves, eighths, shades, quadrants and sextants,
/// in the cell's text color. They are filled here, each frame, and not with the row's text,
/// which is laid out once and kept: where a block's edges fall on the screen's pixels depends
/// on where its row is now. A run of the same block in the same color is filled as one piece.
fn drawBlocks(v: *TermView, sn: *gtk.Snapshot, f: *const term_mod.Frame, top: f64, from: usize, rows: usize, h: f64) void {
    var parts_buf: [6]boxdraw.Part = undefined;
    var y: usize = from;
    while (y < @min(rows, f.rows)) : (y += 1) {
        const row_top = top + @as(f64, @floatFromInt(y)) * v.cell_h;
        if (row_top > h) break;
        if (row_top + v.cell_h < 0) continue;
        var x: usize = 0;
        while (x < f.cols) {
            const cl = f.cell(x, y);
            if (!boxdraw.isBlock(cl.cp) or cl.flags.invisible) {
                x += 1;
                continue;
            }
            const color = cellColors(f, cl).fg;
            const start = x;
            x += 1;
            while (x < f.cols) : (x += 1) {
                const n = f.cell(x, y);
                if (n.cp != cl.cp or n.flags.invisible or n.flags.faint != cl.flags.faint or cellColors(f, n).fg != color) break;
            }
            const strength: f64 = if (cl.flags.faint) 0.6 else 1;
            for (boxdraw.blockParts(cl.cp, &parts_buf)) |part| {
                const y0 = pixelY(v, row_top + part.y0 * v.cell_h);
                const y1 = pixelY(v, row_top + part.y1 * v.cell_h);
                // A part as wide as its cell joins its neighbours' into one strip; a narrower
                // one is filled cell by cell.
                const whole = part.x0 == 0 and part.x1 == 1;
                var col = start;
                while (col < x) : (col += 1) {
                    const last = if (whole) x - 1 else col;
                    const x0 = pixelX(v, pad_x + (@as(f64, @floatFromInt(col)) + part.x0) * v.cell_w);
                    const x1 = pixelX(v, pad_x + (@as(f64, @floatFromInt(last)) + part.x1) * v.cell_w);
                    fillRect(sn, color, strength * part.alpha, x0, y0, x1 - x0, y1 - y0);
                    col = last;
                }
            }
        }
    }
}

fn drawBackgrounds(v: *TermView, sn: *gtk.Snapshot, f: *const term_mod.Frame, top: f64, from: usize, rows: usize, h: f64) void {
    const Shape = struct { color: u32, builder: *gsk.PathBuilder };
    var shapes: [24]Shape = undefined;
    var n_shapes: usize = 0;
    const rounded = settings.current.rounded_selection;
    const radius: f64 = @min(settings.current.selection_radius, v.cell_h / 2);
    const S = struct {
        fn selected(fr: *const term_mod.Frame, col: usize, row: isize) bool {
            if (row < 0 or row >= fr.rows) return false;
            return fr.cell(col, @intCast(row)).flags.selected;
        }
    };
    var y: usize = from;
    while (y < @min(rows, f.rows)) : (y += 1) {
        const row_top = top + @as(f64, @floatFromInt(y)) * v.cell_h;
        if (row_top > h) break;
        if (row_top + v.cell_h < 0) continue;
        var x: usize = 0;
        while (x < f.cols) {
            const first = f.cell(x, y);
            const color = cellBg(f, first);
            const sel = first.flags.selected;
            const start = x;
            x += 1;
            while (x < f.cols and cellBg(f, f.cell(x, y)) == color and f.cell(x, y).flags.selected == sel) x += 1;
            if (color == f.bg and !sel) continue;
            // The run's edges, on the screen's pixels so it meets its neighbours exactly.
            const run_x0 = pixelX(v, pad_x + @as(f64, @floatFromInt(start)) * v.cell_w);
            const run_x1 = pixelX(v, pad_x + @as(f64, @floatFromInt(x)) * v.cell_w);
            const run_y0 = pixelY(v, row_top);
            const run_y1 = pixelY(v, row_top + v.cell_h);
            // Its color's shape, made the first time the color comes up.
            const shape = for (shapes[0..n_shapes]) |*sh| {
                if (sh.color == color) break sh;
            } else blk: {
                if (n_shapes == shapes.len) {
                    // So many colors that a shape each would cost more than it saves.
                    fillRect(sn, color, 1, run_x0, run_y0, run_x1 - run_x0, run_y1 - run_y0);
                    continue;
                }
                shapes[n_shapes] = .{ .color = color, .builder = gsk.PathBuilder.new() };
                n_shapes += 1;
                break :blk &shapes[n_shapes - 1];
            };
            const rect: graphene.Rect = .{
                .f_origin = .{ .f_x = @floatCast(run_x0), .f_y = @floatCast(run_y0) },
                .f_size = .{ .f_width = @floatCast(run_x1 - run_x0), .f_height = @floatCast(run_y1 - run_y0) },
            };
            if (!(rounded and sel)) {
                shape.builder.addRect(&rect);
                continue;
            }
            // Rounded where nothing selected lies beyond that corner: above or below it, or
            // beside it on the same line, where the selection only changes color.
            const row: isize = @intCast(y);
            const left = start > 0 and f.cell(start - 1, y).flags.selected;
            const right = x < f.cols and f.cell(x, y).flags.selected;
            const r: f32 = @floatCast(@min(radius, @as(f64, @floatFromInt(x - start)) * v.cell_w / 2));
            const round: graphene.Size = .{ .f_width = r, .f_height = r };
            const square: graphene.Size = .{ .f_width = 0, .f_height = 0 };
            var rr: gsk.RoundedRect = undefined;
            _ = rr.init(
                &rect,
                if (left or S.selected(f, start, row - 1)) &square else &round,
                if (right or S.selected(f, x - 1, row - 1)) &square else &round,
                if (right or S.selected(f, x - 1, row + 1)) &square else &round,
                if (left or S.selected(f, start, row + 1)) &square else &round,
            );
            shape.builder.addRoundedRect(&rr);
        }
    }
    for (shapes[0..n_shapes]) |sh| {
        const path = sh.builder.freeToPath();
        defer path.unref();
        const c = rgba(sh.color, 1);
        sn.appendFill(path, .winding, &c);
    }
    if (!rounded) return;
    // The corners inside the selection's outline, where one line of it reaches further than
    // the next, are rounded too: each gets a small curved fill in the corner, so every corner
    // of the shape is round.
    var row: usize = 0;
    while (row + 1 < @min(rows, f.rows)) : (row += 1) {
        const a = selectedSpan(f, row) orelse continue;
        const b = selectedSpan(f, row + 1) orelse continue;
        // Lines whose selections don't touch have no corner between them.
        if (a[1] <= b[0] or b[1] <= a[0]) continue;
        const py = top + @as(f64, @floatFromInt(row + 1)) * v.cell_h;
        if (py - v.cell_h > h) break;
        if (a[0] != b[0]) {
            // The line that starts later leaves a corner beside it, above or below.
            const col = @max(a[0], b[0]);
            const upper_later = a[0] > b[0];
            const r = @min(radius, @as(f64, @floatFromInt(@max(a[0], b[0]) - @min(a[0], b[0]))) * v.cell_w / 2);
            const color = cellBg(f, f.cell(col - 1, if (upper_later) row + 1 else row));
            fillet(sn, pad_x + @as(f64, @floatFromInt(col)) * v.cell_w, py, -1, if (upper_later) -1 else 1, r, color);
        }
        if (a[1] != b[1]) {
            // The line that ends sooner leaves a corner past its end, above or below.
            const col = @min(a[1], b[1]);
            const lower_longer = b[1] > a[1];
            const r = @min(radius, @as(f64, @floatFromInt(@max(a[1], b[1]) - @min(a[1], b[1]))) * v.cell_w / 2);
            const color = cellBg(f, f.cell(col, if (lower_longer) row + 1 else row));
            fillet(sn, pad_x + @as(f64, @floatFromInt(col)) * v.cell_w, py, 1, if (lower_longer) -1 else 1, r, color);
        }
    }
}

/// The one run of selected cells on a row, start and end, or null if it has none or several.
fn selectedSpan(f: *const term_mod.Frame, row: usize) ?[2]usize {
    var start: ?usize = null;
    var end: usize = 0;
    var x: usize = 0;
    while (x < f.cols) : (x += 1) {
        if (!f.cell(x, row).flags.selected) continue;
        if (start != null and x != end) return null;
        if (start == null) start = x;
        end = x + 1;
    }
    return if (start) |s| .{ s, end } else null;
}

/// Rounds an inside corner of a shape at (px, py): fills the corner of the empty quarter that
/// lies `dx`, `dy` from it (each 1 or -1) up to a quarter circle of radius `r`, reaching a
/// little into the shape so no seam shows where they meet.
fn fillet(sn: *gtk.Snapshot, px: f64, py: f64, dx: f64, dy: f64, r: f64, color: u32) void {
    if (r < 0.5) return;
    const e = 0.5;
    const b = gsk.PathBuilder.new();
    b.moveTo(@floatCast(px - dx * e), @floatCast(py - dy * e));
    b.lineTo(@floatCast(px + dx * r), @floatCast(py - dy * e));
    b.lineTo(@floatCast(px + dx * r), @floatCast(py));
    // A quarter circle, bowing in toward the corner.
    b.conicTo(@floatCast(px), @floatCast(py), @floatCast(px), @floatCast(py + dy * r), std.math.sqrt1_2);
    b.lineTo(@floatCast(px - dx * e), @floatCast(py + dy * r));
    b.close();
    const path = b.freeToPath();
    defer path.unref();
    const c = rgba(color, 1);
    sn.appendFill(path, .winding, &c);
}

const CopySpan = struct { row: u16, x0: u16, x1: u16 };

/// How long a copy's animation lasts; how much of it the lift takes to rise, and when it starts
/// to settle back.
const copy_duration_us = 560 * std.time.us_per_ms;
const copy_rise = 0.36;
const copy_settle = 0.55;

/// The copied text, lifted: the pane as it was at the copy, cut to the copied cells' shape,
/// raised a few points with a soft shadow under it, then settling back, while a glint runs
/// across it from its start to its far edge.
fn drawCopy(v: *TermView, sn: *gtk.Snapshot) void {
    const node = v.copy_node orelse return;
    const elapsed: f64 = @floatFromInt(glib.getMonotonicTime() - v.copy_started);
    const t = elapsed / @as(f64, @floatFromInt(copy_duration_us));
    if (t >= 1) return;
    const spans = v.copy_spans.items;
    // The copied shape, and the box around it.
    var x0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    var y0: f64 = std.math.inf(f64);
    var y1: f64 = -std.math.inf(f64);
    const builder = gsk.PathBuilder.new();
    const radius: f64 = if (settings.current.rounded_selection) @min(settings.current.selection_radius, v.cell_h / 2) else 0;
    for (spans) |s| {
        const left = pad_x + @as(f64, @floatFromInt(s.x0)) * v.cell_w;
        const right = pad_x + @as(f64, @floatFromInt(s.x1)) * v.cell_w;
        const top = v.copy_top + @as(f64, @floatFromInt(s.row)) * v.cell_h;
        x0 = @min(x0, left);
        x1 = @max(x1, right);
        y0 = @min(y0, top);
        y1 = @max(y1, top + v.cell_h);
        const rect: graphene.Rect = .{ .f_origin = .{ .f_x = @floatCast(left), .f_y = @floatCast(top) }, .f_size = .{ .f_width = @floatCast(right - left), .f_height = @floatCast(v.cell_h + 0.05) } };
        const r: f32 = @floatCast(@min(radius, (right - left) / 2));
        const round: graphene.Size = .{ .f_width = r, .f_height = r };
        const square: graphene.Size = .{ .f_width = 0, .f_height = 0 };
        var rr: gsk.RoundedRect = undefined;
        _ = rr.init(
            &rect,
            if (copied(spans, s.row, -1, s.x0)) &square else &round,
            if (copied(spans, s.row, -1, s.x1 - 1)) &square else &round,
            if (copied(spans, s.row, 1, s.x1 - 1)) &square else &round,
            if (copied(spans, s.row, 1, s.x0)) &square else &round,
        );
        builder.addRoundedRect(&rr);
    }
    const shape = builder.freeToPath();
    defer shape.unref();
    const w = x1 - x0;
    const h = y1 - y0;
    if (w <= 0 or h <= 0) return;

    // Up, easing in and out so it doesn't jump, a moment held at the top, then slowly down; a
    // few points either way, however big the selection.
    const Ease = struct {
        fn inOut(x: f64) f64 {
            return 0.5 - 0.5 * @cos(std.math.pi * std.math.clamp(x, 0, 1));
        }
    };
    const lift = if (t < copy_rise)
        Ease.inOut(t / copy_rise)
    else if (t < copy_settle)
        1
    else
        1 - Ease.inOut((t - copy_settle) / (1 - copy_settle));
    const grow = @min(0.045, 8 / @max(w, h));
    const s: f32 = @floatCast(1 + lift * grow);
    const cx: f32 = @floatCast(x0 + w / 2);
    const cy: f32 = @floatCast(y0 + h / 2);
    sn.save();
    sn.translate(&.{ .f_x = cx, .f_y = cy - @as(f32, @floatCast(1.5 * lift)) });
    sn.scale(s, s);
    sn.translate(&.{ .f_x = -cx, .f_y = -cy });
    const shadow: gsk.Shadow = .{ .f_color = .{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = @floatCast(0.32 * lift) }, .f_dx = 0, .f_dy = @floatCast(3 * lift), .f_radius = @floatCast(14 * lift) };
    sn.pushShadow(@ptrCast(&shadow), 1);
    // The copied shape, as the selection draws it: its rows, and its inside corners rounded
    // where one row reaches further than the next.
    sn.pushMask(.alpha);
    const solid: gdk.RGBA = .{ .f_red = 1, .f_green = 1, .f_blue = 1, .f_alpha = 1 };
    sn.appendFill(shape, .winding, &solid);
    if (settings.current.rounded_selection) {
        for (spans) |above| {
            const a = rowSpan(spans, above.row) orelse continue;
            if (a.x0 != above.x0) continue;
            const b = rowSpan(spans, above.row + 1) orelse continue;
            if (a.x1 <= b.x0 or b.x1 <= a.x0) continue;
            const py = v.copy_top + @as(f64, @floatFromInt(above.row + 1)) * v.cell_h;
            if (a.x0 != b.x0) {
                const r = @min(radius, @as(f64, @floatFromInt(@max(a.x0, b.x0) - @min(a.x0, b.x0))) * v.cell_w / 2);
                fillet(sn, pad_x + @as(f64, @floatFromInt(@max(a.x0, b.x0))) * v.cell_w, py, -1, if (a.x0 > b.x0) -1 else 1, r, 0xffffff);
            }
            if (a.x1 != b.x1) {
                const r = @min(radius, @as(f64, @floatFromInt(@max(a.x1, b.x1) - @min(a.x1, b.x1))) * v.cell_w / 2);
                fillet(sn, pad_x + @as(f64, @floatFromInt(@min(a.x1, b.x1))) * v.cell_w, py, 1, if (b.x1 > a.x1) -1 else 1, r, 0xffffff);
            }
        }
    }
    sn.pop();
    sn.appendNode(node);
    // The glint: a band of light crossing from the start of the copied text to its far edge.
    const g = std.math.clamp((t - 0.12) / 0.7, 0, 1);
    const along = if (g < 0.5) 2 * g * g else 1 - std.math.pow(f64, -2 * g + 2, 2) / 2;
    const band = @max(v.cell_w * 5, w * 0.18);
    const bx = x0 - band + (w + 2 * band) * along;
    const bounds: graphene.Rect = .{ .f_origin = .{ .f_x = @floatCast(x0), .f_y = @floatCast(y0) }, .f_size = .{ .f_width = @floatCast(w), .f_height = @floatCast(h) } };
    const clear: gdk.RGBA = .{ .f_red = 1, .f_green = 1, .f_blue = 1, .f_alpha = 0 };
    const light: gdk.RGBA = .{ .f_red = 1, .f_green = 1, .f_blue = 1, .f_alpha = 0.34 };
    const stops = [_]gsk.ColorStop{ .{ .f_offset = 0, .f_color = clear }, .{ .f_offset = 0.5, .f_color = light }, .{ .f_offset = 1, .f_color = clear } };
    sn.appendLinearGradient(&bounds, &.{ .f_x = @floatCast(bx - band / 2), .f_y = @floatCast(y0) }, &.{ .f_x = @floatCast(bx + band / 2), .f_y = @floatCast(y1) }, &stops, stops.len);
    sn.pop();
    sn.pop();
    sn.restore();
}

/// The one run of copied cells on a row, or null if it has none or several, as `selectedSpan`.
fn rowSpan(spans: []const CopySpan, row: u16) ?CopySpan {
    var found: ?CopySpan = null;
    for (spans) |s| if (s.row == row) {
        if (found != null) return null;
        found = s;
    };
    return found;
}

/// Whether the copied cells reach the row `dir` (-1 above, 1 below) from `row`, at `col`.
fn copied(spans: []const CopySpan, row: u16, dir: i32, col: u16) bool {
    const want = @as(i32, row) + dir;
    if (want < 0) return false;
    for (spans) |s| if (s.row == want and s.x0 <= col and col < s.x1) return true;
    return false;
}

/// A cell's background as `cellColors` gives it, without working out its text color.
fn cellBg(f: *const term_mod.Frame, cl: term_mod.Cell) u32 {
    var fg = if (cl.fg != 0) cl.fg else f.fg;
    var bg = if (cl.bg != 0) cl.bg else f.bg;
    if (cl.flags.inverse) std.mem.swap(u32, &fg, &bg);
    if (cl.flags.selected) {
        const sel_bg = settings.current.selection_bg;
        bg = if (sel_bg != 0) sel_bg else fg;
    }
    return bg;
}

fn placeRow(sn: *gtk.Snapshot, node: ?*gsk.RenderNode, top: f64) void {
    const n = node orelse return;
    sn.save();
    sn.translate(&.{ .f_x = 0, .f_y = @floatCast(top) });
    sn.appendNode(n);
    sn.restore();
}

/// Reads the terminal into its frame for drawing. While copied text is lifted, the cursor is
/// hidden and the cells the text left are empty, so the terminal's own background shows behind it, not the text and its
/// selection. The cache of drawn rows keys on the cells, so it stays right.
fn renderFrame(v: *TermView, t: *term_mod.Term) void {
    t.honor_hold = settings.current.program_scroll_glide and t.frame.alt_screen;
    _ = t.render(true);
    if (v.copy_mode != null) t.frame.cursor_visible = false;
    // Where the text is now is known only once the terminal is read, so a lift whose text has
    // moved ends here, before its cells are emptied, not a frame late.
    v.followOutput(t.frame.scroll_total);
    v.dropMovedCopy();
    // From the copy's picture until the lifted text is back down, there's no cursor: not in
    // the picture, and not jumping about under or beside the text while it moves.
    if (v.copy_spans.items.len > 0) t.frame.cursor_visible = false;
    if (v.copy_node == null) return;
    const f = &t.frame;
    for (v.copy_spans.items) |s| {
        if (s.row >= f.rows) continue;
        var x = s.x0;
        while (x < s.x1 and x < f.cols) : (x += 1) f.cells.items[@as(usize, s.row) * f.cols + x] = .{};
    }
}

fn drawGrid(v: *TermView, sn: *gtk.Snapshot, t: *term_mod.Term, f: *const term_mod.Frame, f_font: Font, frac: f64, h: f64) void {
    drawBackgrounds(v, sn, f, pad_y + frac, 0, f.rows, h);
    drawImages(v, sn, t, false, frac);
    drawBlocks(v, sn, f, pad_y + frac, 0, f.rows, h);
    var y: usize = 0;
    while (y < f.rows) : (y += 1) {
        const top = pad_y + frac + @as(f64, @floatFromInt(y)) * v.cell_h;
        if (top > h) break;
        placeRow(sn, rowNode(v, y, f, y, f_font), top);
    }
    drawImages(v, sn, t, true, frac);
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
    const t = v.term() orelse return snapshotEmpty(v, sn, w, h, switch (st.state) {
        .closed => "This pane has closed",
        // A pane is nearly always on screen a moment later, so nothing is written meanwhile.
        else => "",
    });
    renderFrame(v, t);
    const f = &t.frame;
    const f_font = v.fontOf() orelse return;
    findPixels(v);
    v.shader_look.bg = f.bg;
    v.shader_look.bg_alpha = @floatCast(term_opacity);
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
    // While looking back through history, the lines just outside the rows are drawn too, as
    // much of each as shows: the one above in the gap at the top, and the one below in what is
    // left of the pane under the last row. A line leaves by sliding out past the edge, cut
    // where the pane ends, not by vanishing the moment it no longer fits whole.
    const in_history = v.scroll_px > 0.01;
    if (in_history and rows_up < max_up and pad_y + frac > 0.01) {
        t.scroll(-1);
        _ = t.render(true);
        drawBackgrounds(v, sn, &t.frame, pad_y + frac - v.cell_h, 0, 1, h);
        drawBlocks(v, sn, &t.frame, pad_y + frac - v.cell_h, 0, 1, h);
        placeRow(sn, rowNode(v, t.frame.rows, &t.frame, 0, f_font), pad_y + frac - v.cell_h);
        t.scroll(1);
        renderFrame(v, t);
    }
    const below_top = pad_y + frac + @as(f64, @floatFromInt(f.rows)) * v.cell_h;
    if (in_history and rows_up >= 1 and below_top < h and f.rows > 0) {
        // One row on, the line below is the last of the rows read.
        const rows = f.rows;
        t.scroll(1);
        _ = t.render(true);
        if (t.frame.rows == rows) {
            const first_top = below_top - @as(f64, @floatFromInt(rows - 1)) * v.cell_h;
            drawBackgrounds(v, sn, &t.frame, first_top, rows - 1, rows, h);
            drawBlocks(v, sn, &t.frame, first_top, rows - 1, rows, h);
            placeRow(sn, rowNode(v, rows + 1, &t.frame, rows - 1, f_font), below_top);
        }
        t.scroll(-1);
        renderFrame(v, t);
    }
    if (settings.current.program_scroll_glide and f.alt_screen) {
        if (v.glide.observe(f, if (glib.getMonotonicTime() < v.glide_armed_until) v.glide_direction else null, v.cell_h)) |shift| {
            v.answered(shift.rows);
            if (perf_log) std.log.info("glide: {d} rows in {d}..{d}", .{ shift.rows, shift.band.top, shift.band.bottom });
        }
        const own = gtk.Snapshot.new();
        drawGrid(v, own, t, f, f_font, frac, h);
        const grid = own.freeToNode();
        if (grid) |g| {
            if (v.glide.moving()) v.glide.draw(sn, g, .{ .w = w, .h = h, .pad_x = pad_x, .pad_y = pad_y, .cell_w = v.cell_w, .cell_h = v.cell_h, .px = .{ .origin = v.pixel_origin[1], .scale = v.pixel_scale }, .fill_alpha = term_opacity }) else sn.appendNode(g);
        }
        v.glide.keep(grid);
        if (v.glide.moving()) v.startGlideTick();
    } else {
        v.glide.forget();
        drawGrid(v, sn, t, f, f_font, frac, h);
    }
    if (v.link_armed) v.drawArmedLink(sn, t, frac);
    if (v.copy_mode) |s| {
        const p = s.mode.cursor;
        if (p.y >= f.scroll_offset and p.y < f.scroll_offset + f.rows) {
            const color = if (cursor_accent != 0) cursor_accent else f.fg;
            const x = pad_x + @as(f64, @floatFromInt(p.x)) * v.cell_w;
            const y = pad_y + frac + @as(f64, @floatFromInt(p.y - f.scroll_offset)) * v.cell_h;
            const width = v.cell_w * @as(f64, if (f.cell(p.x, p.y - @as(usize, @intCast(f.scroll_offset))).flags.wide) 2 else 1);
            fillRect(sn, color, 0.3, x, y, width, v.cell_h);
            fillRect(sn, color, 1, x, y + v.cell_h - 2, width, 2);
        }
    }

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
        const cy = pad_y + @as(f64, @floatFromInt(f.cursor_y)) * v.cell_h + v.glide.cursorShift(.{ .origin = v.pixel_origin[1], .scale = v.pixel_scale });
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
        } else if (!focused and !prefs.inactive_cursor) {
            // Panes without the keyboard can leave their cursor out altogether.
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
                    const face = Font.faceOf(under.flags);
                    useFace(v, layout, f_font, face);
                    layout.setText(@ptrCast(text.items.ptr), @intCast(text.items.len - 1));
                    const under_color = if (prefs.cursor_text_color != 0) prefs.cursor_text_color else f.bg;
                    layoutOnBaseline(sn, layout, rgba(under_color, 1), cx, cy + v.baseline);
                    faceDone(v, layout, face);
                }
            },
        }
    }

    drawUploadGhost(v, sn, f, f_font, w, h);

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

    drawCopy(v, sn);

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
