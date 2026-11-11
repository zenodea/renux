//! Custom shaders, as Ghostty has them: a Shadertoy-style GLSL file that every pane is drawn
//! through. The shader gets the pane's picture as iChannel0 and the same uniforms Ghostty
//! gives, and what it draws is shown in the pane's place, so Ghostty's shaders work here.
//!
//! GTK draws with its own renderer (Vulkan, usually) and no longer runs shaders itself, so a
//! pane takes a round trip: its drawing is rendered to a picture, the picture goes to OpenGL,
//! the shader draws into an OpenGL texture, and GTK shows that texture.
//!
//! OpenGL keeps its rows bottom up and GTK top down, so the picture goes in upside down and the
//! result comes back upside down: in between, the shader sees the pane the right way up, with
//! its origin at the bottom left as Shadertoy has it.
const std = @import("std");
const glib = @import("glib");
const gdk = @import("gdk");
const gsk = @import("gsk");
const gtk = @import("gtk");
const graphene = @import("graphene");
const gl = @import("gl");
const settings = @import("../settings/settings.zig");

const gpa = std.heap.c_allocator;
const log = std.log.scoped(.shader);

/// Told when the shader file can't be used, with why, so the person hears of it.
pub var on_error: ?*const fn (message: []const u8) void = null;

// The one OpenGL context all shaders draw in.
var context: ?*gdk.GLContext = null;
var context_failed = false;
var vao: c_uint = 0;
/// A see-through pixel, the cursor layer's iChannel0: it has no picture of its own.
var blank: c_uint = 0;
/// Time 0 for every shader, so a shader built again keeps the same clock.
var started_at: i64 = 0;

const recheck_us = 500 * std.time.us_per_ms;

/// How long after the cursor moves or focus comes a shader that only moves then, such as a
/// cursor trail, is given frames.
const settle_s = 1.5;

/// Which of the two shaders: the one each pane is drawn through, or the one drawn once over
/// the whole window at its one cursor, so a trail can run from one pane to the next.
pub const Kind = enum { pane, cursor };

/// A shader built from the file Settings names, built again when the file or its sliders change.
pub const Program = struct {
    kind: Kind,
    id: c_uint = 0,
    loc: Locations = .{},
    /// The setting it was built for and a hash of what it compiled, to see a change.
    seen: ?[:0]u8 = null,
    hash: u64 = 0,
    checked_at: i64 = 0,
    /// The source uses the time, so its surfaces draw every frame.
    uses_time: bool = false,
    /// Its time is only measured from the cursor's last move or from focus coming, so it settles.
    follows_changes: bool = false,

    pub fn setting(prog: *const Program) []const u8 {
        return switch (prog.kind) {
            .pane => settings.current.custom_shader,
            .cursor => settings.current.cursor_shader,
        };
    }

    /// Whether the shader is set and ready. Reads the file again now and then, and builds the
    /// program again when what it says, or a slider, has changed, so it can be edited live.
    pub fn active(prog: *Program) bool {
        const s = prog.setting();
        // Cursor shaders were once set as the panes' shader; they belong to the cursor now.
        if (prog.kind == .pane and isBundledName(s) and std.mem.startsWith(u8, s, "cursor-")) {
            settings.setString(&settings.current.cursor_shader, s);
            settings.setString(&settings.current.custom_shader, "");
            return false;
        }
        if (s.len == 0) {
            prog.unload();
            return false;
        }
        const now = glib.getMonotonicTime();
        const same = if (prog.seen) |x| std.mem.eql(u8, x, s) else false;
        if (same and now - prog.checked_at < recheck_us) return prog.id != 0;
        prog.checked_at = now;
        if (!same) {
            if (prog.seen) |x| gpa.free(x);
            prog.seen = gpa.dupeSentinel(u8, s, 0) catch null;
            prog.hash = 0;
        }
        const raw = readSource(s) orelse {
            if (prog.hash != 1) report("Couldn't read the shader file", s);
            prog.hash = 1;
            prog.unloadProgram();
            return false;
        };
        defer gpa.free(raw);
        const source = withOverrides(s, raw) orelse return prog.id != 0;
        defer gpa.free(source);
        const hash = std.hash.Wyhash.hash(0, source);
        if (hash == prog.hash) return prog.id != 0;
        prog.hash = hash;
        prog.unloadProgram();
        prog.build(source);
        return prog.id != 0;
    }

    /// Reads the file and its sliders again at the next drawing, rather than within half a second.
    pub fn reload(prog: *Program) void {
        prog.checked_at = 0;
    }

    /// Whether the shader draws differently as time passes.
    pub fn animated(prog: *const Program) bool {
        return prog.id != 0 and prog.uses_time;
    }

    /// Whether `p` should draw another frame now. A shader whose time is only measured from the
    /// cursor's last move or from focus coming only moves for a moment after one, so it stops
    /// asking for frames once that has passed rather than drawing the same picture again.
    pub fn wantsFrames(prog: *const Program, p: *const Pane) bool {
        if (!prog.animated()) return false;
        if (!prog.follows_changes) return true;
        return clock() - @max(p.cursor_changed_at, p.focused_at) < settle_s;
    }

    fn unload(prog: *Program) void {
        prog.unloadProgram();
        if (prog.seen) |x| gpa.free(x);
        prog.seen = null;
        prog.hash = 0;
    }

    fn unloadProgram(prog: *Program) void {
        if (prog.id == 0) return;
        const ctx = context orelse return;
        ctx.makeCurrent();
        gl.epoxy_glDeleteProgram.?(prog.id);
        prog.id = 0;
        gdk.GLContext.clearCurrent();
    }

    fn build(prog: *Program, source: []const u8) void {
        const ctx = ensureContext() orelse return;
        ctx.makeCurrent();
        defer gdk.GLContext.clearCurrent();
        var hb: [160]u8 = undefined;
        const head = header(&hb, ctx);
        const vs_text = std.mem.concat(gpa, u8, &.{ head, vertex_body }) catch return;
        defer gpa.free(vs_text);
        const fs_text = std.mem.concat(gpa, u8, &.{ head, prefix, source }) catch return;
        defer gpa.free(fs_text);
        const vs = compile(gl.GL_VERTEX_SHADER, vs_text) orelse return;
        defer gl.epoxy_glDeleteShader.?(vs);
        const fs = compile(gl.GL_FRAGMENT_SHADER, fs_text) orelse return;
        defer gl.epoxy_glDeleteShader.?(fs);
        const id = gl.epoxy_glCreateProgram.?();
        gl.epoxy_glAttachShader.?(id, vs);
        gl.epoxy_glAttachShader.?(id, fs);
        gl.epoxy_glLinkProgram.?(id);
        var ok: c_int = 0;
        gl.epoxy_glGetProgramiv.?(id, gl.GL_LINK_STATUS, &ok);
        if (ok == 0) {
            var info: [1024]u8 = undefined;
            var len: c_int = 0;
            gl.epoxy_glGetProgramInfoLog.?(id, info.len, &len, &info);
            report("The shader didn't link", firstLine(info[0..@intCast(@max(0, len))]));
            gl.epoxy_glDeleteProgram.?(id);
            return;
        }
        prog.id = id;
        if (vao == 0) gl.epoxy_glGenVertexArrays.?(1, &vao);
        inline for (comptime std.meta.fieldNames(Locations)) |field| {
            const name = comptime uniformName(field);
            @field(prog.loc, field) = gl.epoxy_glGetUniformLocation.?(id, name.ptr);
        }
        prog.uses_time = std.mem.indexOf(u8, source, "iTime") != null or std.mem.indexOf(u8, source, "iFrame") != null or std.mem.indexOf(u8, source, "iDate") != null;
        prog.follows_changes = std.mem.indexOf(u8, source, "iTimeCursorChange") != null or std.mem.indexOf(u8, source, "iTimeFocus") != null;
        log.info("{s} shader ready: {s}", .{ @tagName(prog.kind), prog.seen orelse "" });
    }
};

pub var pane: Program = .{ .kind = .pane };
pub var cursor: Program = .{ .kind = .cursor };

/// Seconds since the shaders' time 0.
fn clock() f32 {
    if (started_at == 0) started_at = glib.getMonotonicTime();
    return @floatCast(@as(f64, @floatFromInt(glib.getMonotonicTime() - started_at)) / std.time.us_per_s);
}

/// What a pane's drawing knows that a shader may use: where its cursor is, in the pane's own
/// points from its top left, and the colors.
pub const Look = struct {
    /// The cursor's box: x, y, width and height. Kept from the last time it was drawn.
    cursor: [4]f32 = @splat(0),
    cursor_color: u32 = 0,
    /// As Ghostty numbers them: block, hollow block, bar, underline.
    cursor_style: i32 = 0,
    /// Whether the program shows its cursor at all; a blink doesn't count.
    cursor_visible: bool = false,
    bg: u32 = 0,
    /// How opaque the pane's background is drawn, as the Terminals setting has it.
    bg_alpha: f32 = 1,
    fg: u32 = 0,
};

/// Each pane's own textures, kept between frames, and what its shader was last told. The
/// window's cursor layer keeps one of these too.
pub const Pane = struct {
    input: c_uint = 0,
    input_w: c_int = 0,
    input_h: c_int = 0,
    fbo: c_uint = 0,
    /// The picture's size in the pane's own points, and the screen's scale.
    width: f32 = 0,
    height: f32 = 0,
    scale: f32 = 1,
    frame: i32 = 0,
    last_us: i64 = 0,
    /// The cursor in the shader's terms, now and before it last moved or changed color, and
    /// when that was. Ghostty gives the same, which is what cursor trails are made of.
    current_cursor: [4]f32 = @splat(0),
    previous_cursor: [4]f32 = @splat(0),
    current_color: [4]f32 = @splat(0),
    previous_color: [4]f32 = @splat(0),
    current_style: i32 = 0,
    previous_style: i32 = 0,
    cursor_changed_at: f32 = 0,
    focused: bool = false,
    focused_at: f32 = 0,

    /// Frees the pane's textures, such as when it closes.
    pub fn deinit(p: *Pane) void {
        if (p.input == 0 and p.fbo == 0) return;
        const ctx = context orelse return;
        ctx.makeCurrent();
        if (p.input != 0) gl.epoxy_glDeleteTextures.?(1, &p.input);
        if (p.fbo != 0) gl.epoxy_glDeleteFramebuffers.?(1, &p.fbo);
        p.* = .{};
        gdk.GLContext.clearCurrent();
    }
};

const Locations = struct {
    resolution: c_int = -1,
    time: c_int = -1,
    time_delta: c_int = -1,
    frame_rate: c_int = -1,
    frame: c_int = -1,
    channel_resolution: c_int = -1,
    mouse: c_int = -1,
    date: c_int = -1,
    focus: c_int = -1,
    time_focus: c_int = -1,
    channel0: c_int = -1,
    current_cursor: c_int = -1,
    previous_cursor: c_int = -1,
    current_cursor_color: c_int = -1,
    previous_cursor_color: c_int = -1,
    current_cursor_style: c_int = -1,
    previous_cursor_style: c_int = -1,
    cursor_visible: c_int = -1,
    time_cursor_change: c_int = -1,
    background_color: c_int = -1,
    foreground_color: c_int = -1,
    cursor_color: c_int = -1,
    /// Renux's own: the background that fills what a shader leaves see-through, and where the
    /// drawn region starts in the whole picture.
    renux_background: c_int = -1,
    renux_origin: c_int = -1,
};

/// Where the shaders that come with Renux are: PREFIX/share/renux/shaders, beside the program.
pub fn bundledDir(buf: []u8) ?[:0]const u8 {
    var exe_buf: [4096]u8 = undefined;
    const n = std.process.executableDirPath(@import("../main.zig").io, &exe_buf) catch return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/../share/renux/shaders", .{exe_buf[0..n]}, 0) catch null;
}

// The binding says a name always comes back, but the end of the folder is NULL.
extern fn g_dir_read_name(dir: *glib.Dir) ?[*:0]const u8;

/// The names of the shaders that come with Renux, such as crt, sorted. Each is allocated.
pub fn bundledNames(al: std.mem.Allocator) []const []const u8 {
    var buf: [4200]u8 = undefined;
    const path = bundledDir(&buf) orelse return &.{};
    const dir = glib.Dir.open(path.ptr, 0, null) orelse return &.{};
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    while (g_dir_read_name(dir)) |raw| {
        const name = std.mem.span(raw);
        if (!std.mem.endsWith(u8, name, ".glsl")) continue;
        names.append(al, al.dupe(u8, name[0 .. name.len - ".glsl".len]) catch continue) catch {};
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

/// The setting is a bundled shader's name, such as crt, or a file's path.
pub fn isBundledName(setting: []const u8) bool {
    return std.mem.indexOfScalar(u8, setting, '/') == null and !std.mem.endsWith(u8, setting, ".glsl");
}

fn readSource(path: []const u8) ?[]u8 {
    var dir_buf: [4200]u8 = undefined;
    const full = if (isBundledName(path))
        std.fmt.allocPrintSentinel(gpa, "{s}/{s}.glsl", .{ bundledDir(&dir_buf) orelse return null, path }, 0) catch return null
    else if (std.mem.startsWith(u8, path, "~/"))
        // ~ is the home folder, as in a shell.
        std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ std.mem.span(glib.getHomeDir()), path[1..] }, 0) catch return null
    else
        gpa.dupeSentinel(u8, path, 0) catch return null;
    defer gpa.free(full);
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(full.ptr, &contents, &len, null) == 0) return null;
    defer glib.free(contents);
    return gpa.dupe(u8, contents[0..len]) catch null;
}

fn report(comptime what: []const u8, detail: []const u8) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, what ++ ": {s}", .{detail}) catch what;
    log.warn("{s}", .{text});
    if (on_error) |f| f(text);
}

/// The OpenGL context, made the first time it's needed.
fn ensureContext() ?*gdk.GLContext {
    if (context) |c| return c;
    if (context_failed) return null;
    var err: ?*glib.Error = null;
    const display = gdk.Display.getDefault() orelse return null;
    const ctx = display.createGlContext(&err) orelse return contextFailed(err);
    if (ctx.realize(&err) == 0) return contextFailed(err);
    context = ctx;
    return ctx;
}

fn contextFailed(err: ?*glib.Error) ?*gdk.GLContext {
    context_failed = true;
    const why: []const u8 = if (err) |e| std.mem.span(e.f_message orelse "") else "";
    report("Shaders need OpenGL, which isn't available", why);
    if (err) |e| e.free();
    return null;
}

// Building the program.

/// Ghostty's uniforms, under the names its shaders use. Ones Renux doesn't fill yet stay zero.
const prefix =
    \\uniform vec3  iResolution;
    \\uniform float iTime;
    \\uniform float iTimeDelta;
    \\uniform float iFrameRate;
    \\uniform int   iFrame;
    \\uniform float iChannelTime[4];
    \\uniform vec3  iChannelResolution[4];
    \\uniform vec4  iMouse;
    \\uniform vec4  iDate;
    \\uniform float iSampleRate;
    \\uniform vec4  iCurrentCursor;
    \\uniform vec4  iPreviousCursor;
    \\uniform vec4  iCurrentCursorColor;
    \\uniform vec4  iPreviousCursorColor;
    \\uniform int   iCurrentCursorStyle;
    \\uniform int   iPreviousCursorStyle;
    \\uniform int   iCursorVisible;
    \\uniform float iTimeCursorChange;
    \\uniform float iTimeFocus;
    \\uniform int   iFocus;
    \\uniform vec3  iPalette[256];
    \\uniform vec3  iBackgroundColor;
    \\uniform vec3  iForegroundColor;
    \\uniform vec3  iCursorColor;
    \\uniform vec3  iCursorText;
    \\uniform vec3  iSelectionForegroundColor;
    \\uniform vec3  iSelectionBackgroundColor;
    \\#define CURSORSTYLE_BLOCK        0
    \\#define CURSORSTYLE_BLOCK_HOLLOW 1
    \\#define CURSORSTYLE_BAR          2
    \\#define CURSORSTYLE_UNDERLINE    3
    \\#define CURSORSTYLE_LOCK         4
    \\uniform sampler2D iChannel0;
    \\out vec4 _fragColor;
    \\#define texture2D texture
    \\uniform vec4 _renuxBackground;
    \\uniform vec2 _renuxOrigin;
    \\void mainImage(out vec4 fragColor, in vec2 fragCoord);
    \\void main() {
    \\    vec4 c = vec4(0.0);
    \\    mainImage(c, gl_FragCoord.xy + _renuxOrigin);
    \\    if (c.a < _renuxBackground.a) c += _renuxBackground * ((_renuxBackground.a - c.a) / _renuxBackground.a);
    \\    _fragColor = c;
    \\}
    \\#line 1
    \\
;

/// A triangle that covers the whole picture, made from the vertex number alone.
const vertex_body =
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
    \\
;

/// The first lines of each shader: OpenGL ES (as GTK often gives on Linux) or desktop OpenGL.
fn header(buf: []u8, ctx: *gdk.GLContext) []const u8 {
    if (ctx.getUseEs() == 0) return "#version 330 core\n";
    var major: c_int = 3;
    var minor: c_int = 0;
    ctx.getVersion(&major, &minor);
    const v: c_int = if (major > 3 or (major == 3 and minor >= 2)) 320 else if (major == 3 and minor == 1) 310 else 300;
    return std.fmt.bufPrint(buf, "#version {d} es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n", .{v}) catch "#version 300 es\nprecision highp float;\n";
}

fn uniformName(comptime field: []const u8) [:0]const u8 {
    return comptime blk: {
        if (std.mem.eql(u8, field, "renux_background")) break :blk "_renuxBackground";
        if (std.mem.eql(u8, field, "renux_origin")) break :blk "_renuxOrigin";
        // resolution -> iResolution, time_delta -> iTimeDelta, channel0 -> iChannel0.
        var out: []const u8 = "i";
        var upper = true;
        for (field) |ch| {
            if (ch == '_') {
                upper = true;
                continue;
            }
            out = out ++ &[_]u8{if (upper) std.ascii.toUpper(ch) else ch};
            upper = false;
        }
        const z = out ++ "\x00";
        break :blk z[0..out.len :0];
    };
}

fn compile(kind: c_uint, text: []const u8) ?c_uint {
    const s = gl.epoxy_glCreateShader.?(kind);
    const ptr: [*c]const u8 = text.ptr;
    const len: c_int = @intCast(text.len);
    gl.epoxy_glShaderSource.?(s, 1, &ptr, &len);
    gl.epoxy_glCompileShader.?(s);
    var ok: c_int = 0;
    gl.epoxy_glGetShaderiv.?(s, gl.GL_COMPILE_STATUS, &ok);
    if (ok != 0) return s;
    var info: [1024]u8 = undefined;
    var info_len: c_int = 0;
    gl.epoxy_glGetShaderInfoLog.?(s, info.len, &info_len, &info);
    report("The shader didn't compile", firstLine(info[0..@intCast(@max(0, info_len))]));
    gl.epoxy_glDeleteShader.?(s);
    return null;
}

fn firstLine(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \n\r\t\x00");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

// Drawing.

/// The renderer the panes' pictures are drawn with on their way to the shader. Not the
/// window's: GTK's Vulkan renderer hands back dmabufs, and reading one back leaks the whole
/// picture in GTK 4.22, some 10 MB a frame, until the system runs out of memory. GTK's OpenGL
/// renderer doesn't.
var picture_renderer: ?*gsk.Renderer = null;
var picture_renderer_failed = false;

fn pictureRenderer() ?*gsk.Renderer {
    if (picture_renderer) |r| return r;
    if (picture_renderer_failed) return null;
    const r = gsk.GLRenderer.new().as(gsk.Renderer);
    var err: ?*glib.Error = null;
    if (r.realizeForDisplay(gdk.Display.getDefault() orelse return null, &err) == 0) {
        picture_renderer_failed = true;
        const why: []const u8 = if (err) |e| std.mem.span(e.f_message orelse "") else "";
        report("Shaders need GTK's OpenGL renderer, which didn't start", why);
        if (err) |e| e.free();
        return null;
    }
    picture_renderer = r;
    return r;
}

/// Takes in a pane's own drawing, `node`, as the shader's iChannel0. Only needed when what the
/// pane shows has changed: frames that only move the shader along keep the last picture.
/// False if it couldn't, and the pane draws itself as usual.
pub fn updateInput(p: *Pane, widget: *gtk.Widget, node: *gsk.RenderNode) bool {
    if (pane.id == 0) return false;
    const ctx = context orelse return false;
    const renderer = pictureRenderer() orelse return false;
    const w: f32 = @floatFromInt(widget.getWidth());
    const h: f32 = @floatFromInt(widget.getHeight());
    if (w < 1 or h < 1) return false;
    const native = widget.getNative() orelse return false;
    const scale: f32 = if (native.getSurface()) |s| @floatCast(s.getScale()) else 1;
    const pw: c_int = @intFromFloat(@round(w * scale));
    const ph: c_int = @intFromFloat(@round(h * scale));

    // The pane's picture, at the screen's pixel size, upside down for OpenGL.
    const flip = gtk.Snapshot.new();
    flip.translate(&.{ .f_x = 0, .f_y = @floatFromInt(ph) });
    flip.scale(scale, -scale);
    flip.appendNode(node);
    const flipped = flip.freeToNode() orelse return false;
    defer flipped.unref();
    var viewport: graphene.Rect = .{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = @floatFromInt(pw), .f_height = @floatFromInt(ph) } };
    const picture = renderer.renderTexture(flipped, &viewport);
    defer picture.unref();

    const downloader = gdk.TextureDownloader.new(picture);
    defer downloader.free();
    downloader.setFormat(.r8g8b8a8_premultiplied);
    var stride: usize = 0;
    const bytes = downloader.downloadBytes(&stride);
    defer bytes.unref();
    var size: usize = 0;
    const data = bytes.getData(&size) orelse return false;

    ctx.makeCurrent();
    defer gdk.GLContext.clearCurrent();
    if (p.input == 0) {
        gl.epoxy_glGenTextures.?(1, &p.input);
        gl.epoxy_glGenFramebuffers.?(1, &p.fbo);
    }
    gl.epoxy_glBindTexture.?(gl.GL_TEXTURE_2D, p.input);
    gl.epoxy_glPixelStorei.?(gl.GL_UNPACK_ROW_LENGTH, @intCast(stride / 4));
    if (p.input_w != pw or p.input_h != ph) {
        gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.epoxy_glTexImage2D.?(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, pw, ph, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, data);
        p.input_w = pw;
        p.input_h = ph;
    } else gl.epoxy_glTexSubImage2D.?(gl.GL_TEXTURE_2D, 0, 0, 0, pw, ph, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, data);
    gl.epoxy_glPixelStorei.?(gl.GL_UNPACK_ROW_LENGTH, 0);
    p.scale = scale;
    p.width = w;
    p.height = h;
    return true;
}

/// Runs the shader over the pane's last picture and draws what it makes into `sn`. Cheap: no
/// picture is drawn or read back, so a shader that moves with time costs little per frame.
pub fn drawOutput(p: *Pane, look: *const Look, focused: bool, sn: *gtk.Snapshot) bool {
    if (pane.id == 0 or p.input == 0) return false;
    const ctx = context orelse return false;
    const pw = p.input_w;
    const ph = p.input_h;
    ctx.makeCurrent();
    defer gdk.GLContext.clearCurrent();

    // The shader, into a texture of its own that GTK holds until it has shown it.
    var out: c_uint = 0;
    gl.epoxy_glGenTextures.?(1, &out);
    gl.epoxy_glBindTexture.?(gl.GL_TEXTURE_2D, out);
    gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.epoxy_glTexImage2D.?(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, pw, ph, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
    gl.epoxy_glBindFramebuffer.?(gl.GL_FRAMEBUFFER, p.fbo);
    gl.epoxy_glFramebufferTexture2D.?(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, out, 0);
    gl.epoxy_glViewport.?(0, 0, pw, ph);
    gl.epoxy_glDisable.?(gl.GL_BLEND);
    gl.epoxy_glUseProgram.?(pane.id);
    setUniforms(&pane, p, pw, ph, p.scale, look, focused);
    // What the shader leaves see-through gets the pane's own background, as the pane would
    // have had: a CRT's curve doesn't open a hole to the desktop.
    const bg = rgba(look.bg, 1);
    const a = look.bg_alpha;
    gl.epoxy_glUniform4f.?(pane.loc.renux_background, bg[0] * a, bg[1] * a, bg[2] * a, a);
    gl.epoxy_glUniform2f.?(pane.loc.renux_origin, 0, 0);
    gl.epoxy_glActiveTexture.?(gl.GL_TEXTURE0);
    gl.epoxy_glBindTexture.?(gl.GL_TEXTURE_2D, p.input);
    gl.epoxy_glBindVertexArray.?(vao);
    gl.epoxy_glDrawArrays.?(gl.GL_TRIANGLES, 0, 3);
    gl.epoxy_glBindVertexArray.?(0);
    gl.epoxy_glBindFramebuffer.?(gl.GL_FRAMEBUFFER, 0);
    const sync = gl.epoxy_glFenceSync.?(gl.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    gl.epoxy_glFlush.?();

    // Back to GTK, turned the right way up again.
    const held = gpa.create(Held) catch return false;
    held.* = .{ .texture = out, .sync = sync };
    const builder = gdk.GLTextureBuilder.new();
    defer builder.unref();
    builder.setContext(ctx);
    builder.setId(out);
    builder.setWidth(pw);
    builder.setHeight(ph);
    builder.setFormat(.r8g8b8a8_premultiplied);
    builder.setSync(sync);
    const result = builder.build(&Held.release, held);
    defer result.unref();
    sn.save();
    sn.translate(&.{ .f_x = 0, .f_y = p.height });
    sn.scale(1, -1);
    sn.appendTexture(result, &.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = p.width, .f_height = p.height } });
    sn.restore();
    p.frame +%= 1;
    return true;
}

/// An output texture and its fence, freed once GTK has shown it.
const Held = struct {
    texture: c_uint,
    sync: gl.GLsync,

    fn release(data: ?*anyopaque) callconv(.c) void {
        const held: *Held = @ptrCast(@alignCast(data.?));
        defer gpa.destroy(held);
        const ctx = context orelse return;
        ctx.makeCurrent();
        gl.epoxy_glDeleteSync.?(held.sync);
        gl.epoxy_glDeleteTextures.?(1, &held.texture);
        gdk.GLContext.clearCurrent();
    }
};

/// The window's one cursor, drawn by the cursor shader over everything. `look.cursor` is in
/// the layer's own points; `width` and `height` are the layer's size. Only the region around the
/// cursor, where it is and where it was, is drawn, so this costs little, and nothing at all once
/// a shader that follows the cursor's moves has settled.
pub fn drawCursor(s: *Pane, width: f32, height: f32, scale: f32, look: *const Look, sn: *gtk.Snapshot) void {
    if (cursor.id == 0) return;
    const ctx = context orelse return;
    const pw: c_int = @intFromFloat(@round(width * scale));
    const ph: c_int = @intFromFloat(@round(height * scale));
    if (pw < 1 or ph < 1) return;
    ctx.makeCurrent();
    defer gdk.GLContext.clearCurrent();
    if (s.fbo == 0) gl.epoxy_glGenFramebuffers.?(1, &s.fbo);
    if (blank == 0) {
        const clear = [4]u8{ 0, 0, 0, 0 };
        gl.epoxy_glGenTextures.?(1, &blank);
        gl.epoxy_glBindTexture.?(gl.GL_TEXTURE_2D, blank);
        gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.epoxy_glTexImage2D.?(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, 1, 1, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &clear);
    }
    gl.epoxy_glUseProgram.?(cursor.id);
    setUniforms(&cursor, s, pw, ph, scale, look, true);
    if (cursor.follows_changes and !cursor.wantsFrames(s)) return;

    // Where it is and where it was, with room around for what's drawn beside it.
    const cur = s.current_cursor;
    const prev = if (s.previous_cursor[3] > 0) s.previous_cursor else cur;
    const margin = 4 * @max(cur[3], prev[3]);
    const fw: f32 = @floatFromInt(pw);
    const fh: f32 = @floatFromInt(ph);
    const x0 = @floor(std.math.clamp(@min(cur[0], prev[0]) - margin, 0, fw));
    const x1 = @ceil(std.math.clamp(@max(cur[0] + cur[2], prev[0] + prev[2]) + margin, 0, fw));
    const y0 = @floor(std.math.clamp(@min(cur[1] - cur[3], prev[1] - prev[3]) - margin, 0, fh));
    const y1 = @ceil(std.math.clamp(@max(cur[1], prev[1]) + margin, 0, fh));
    const rw: c_int = @intFromFloat(x1 - x0);
    const rh: c_int = @intFromFloat(y1 - y0);
    if (rw < 1 or rh < 1) return;

    var out: c_uint = 0;
    gl.epoxy_glGenTextures.?(1, &out);
    gl.epoxy_glBindTexture.?(gl.GL_TEXTURE_2D, out);
    gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.epoxy_glTexParameteri.?(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.epoxy_glTexImage2D.?(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, rw, rh, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
    gl.epoxy_glBindFramebuffer.?(gl.GL_FRAMEBUFFER, s.fbo);
    gl.epoxy_glFramebufferTexture2D.?(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, out, 0);
    gl.epoxy_glViewport.?(0, 0, rw, rh);
    gl.epoxy_glDisable.?(gl.GL_BLEND);
    // Nothing of its own under it: the window shows through all but the effect.
    gl.epoxy_glUniform4f.?(cursor.loc.renux_background, 0, 0, 0, 0);
    gl.epoxy_glUniform2f.?(cursor.loc.renux_origin, x0, y0);
    gl.epoxy_glActiveTexture.?(gl.GL_TEXTURE0);
    gl.epoxy_glBindTexture.?(gl.GL_TEXTURE_2D, blank);
    gl.epoxy_glBindVertexArray.?(vao);
    gl.epoxy_glDrawArrays.?(gl.GL_TRIANGLES, 0, 3);
    gl.epoxy_glBindVertexArray.?(0);
    gl.epoxy_glBindFramebuffer.?(gl.GL_FRAMEBUFFER, 0);
    const sync = gl.epoxy_glFenceSync.?(gl.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    gl.epoxy_glFlush.?();

    const held = gpa.create(Held) catch return;
    held.* = .{ .texture = out, .sync = sync };
    const builder = gdk.GLTextureBuilder.new();
    defer builder.unref();
    builder.setContext(ctx);
    builder.setId(out);
    builder.setWidth(rw);
    builder.setHeight(rh);
    builder.setFormat(.r8g8b8a8_premultiplied);
    builder.setSync(sync);
    const result = builder.build(&Held.release, held);
    defer result.unref();
    // The region in the layer's points, top down, and turned the right way up.
    const x = x0 / scale;
    const top = (fh - y1) / scale;
    const w = (x1 - x0) / scale;
    const h = (y1 - y0) / scale;
    sn.save();
    sn.translate(&.{ .f_x = x, .f_y = top + h });
    sn.scale(1, -1);
    sn.appendTexture(result, &.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = w, .f_height = h } });
    sn.restore();
    s.frame +%= 1;
}

// The numbers a shader marks as adjustable, which Settings shows as sliders. A shader marks one
// with its range and what it does, after a constant, so the file still works as it is in
// Ghostty: `const float CURVE = 0.10; // 0 to 0.4: how much the glass bulges`.

pub const Param = struct {
    name: []const u8,
    value: f32,
    default: f32,
    min: f32,
    max: f32,
    about: []const u8,
};

fn parseParam(line: []const u8) ?Param {
    const t = std.mem.trim(u8, line, " \t\r");
    const lead = "const float ";
    if (!std.mem.startsWith(u8, t, lead)) return null;
    var rest = t[lead.len..];
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const name = std.mem.trim(u8, rest[0..eq], " \t");
    rest = rest[eq + 1 ..];
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
    const value = std.fmt.parseFloat(f32, std.mem.trim(u8, rest[0..semi], " \t")) catch return null;
    const slash = std.mem.indexOf(u8, rest[semi..], "//") orelse return null;
    var c = std.mem.trim(u8, rest[semi + slash + 2 ..], " \t");
    const to = std.mem.indexOf(u8, c, " to ") orelse return null;
    const min = std.fmt.parseFloat(f32, std.mem.trim(u8, c[0..to], " ")) catch return null;
    c = c[to + 4 ..];
    const colon = std.mem.indexOfScalar(u8, c, ':');
    const max = std.fmt.parseFloat(f32, std.mem.trim(u8, if (colon) |i| c[0..i] else c, " ")) catch return null;
    if (!(max > min)) return null;
    return .{ .name = name, .value = value, .default = value, .min = min, .max = max, .about = if (colon) |i| std.mem.trim(u8, c[i + 1 ..], " ") else "" };
}

/// The sliders' values are kept in settings.ini as `shader|NAME|value` entries, split by `;`.
fn overrideOf(setting: []const u8, name: []const u8) ?f32 {
    var it = std.mem.splitScalar(u8, settings.current.shader_params, ';');
    while (it.next()) |entry| {
        var parts = std.mem.splitScalar(u8, entry, '|');
        const s = parts.next() orelse continue;
        const n = parts.next() orelse continue;
        const v = parts.next() orelse continue;
        if (std.mem.eql(u8, s, setting) and std.mem.eql(u8, n, name)) return std.fmt.parseFloat(f32, v) catch null;
    }
    return null;
}

/// Sets a slider's value for a shader, or with null puts it back to the shader's own.
pub fn setOverride(setting: []const u8, name: []const u8, value: ?f32) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, settings.current.shader_params, ';');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        var parts = std.mem.splitScalar(u8, entry, '|');
        const s = parts.next() orelse continue;
        const n = parts.next() orelse continue;
        if (std.mem.eql(u8, s, setting) and std.mem.eql(u8, n, name)) continue;
        if (out.items.len > 0) out.append(gpa, ';') catch return;
        out.appendSlice(gpa, entry) catch return;
    }
    if (value) |v| {
        if (out.items.len > 0) out.append(gpa, ';') catch return;
        out.print(gpa, "{s}|{s}|{d:.4}", .{ setting, name, v }) catch return;
    }
    settings.setString(&settings.current.shader_params, out.items);
}

/// The adjustable numbers of the shader a setting names, with any slider values in place.
pub fn paramsOf(al: std.mem.Allocator, setting: []const u8) []Param {
    const source = readSource(setting) orelse return &.{};
    defer gpa.free(source);
    var list: std.ArrayList(Param) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        var param = parseParam(line) orelse continue;
        param.name = al.dupe(u8, param.name) catch continue;
        param.about = al.dupe(u8, param.about) catch continue;
        if (overrideOf(setting, param.name)) |v| param.value = std.math.clamp(v, param.min, param.max);
        list.append(al, param) catch {};
    }
    return list.items;
}

/// The source with the sliders' values written into its constants.
fn withOverrides(setting: []const u8, source: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) out.append(gpa, '\n') catch return null;
        first = false;
        const param = parseParam(line) orelse {
            out.appendSlice(gpa, line) catch return null;
            continue;
        };
        const v = overrideOf(setting, param.name) orelse {
            out.appendSlice(gpa, line) catch return null;
            continue;
        };
        // The constant's own line, its value replaced; GLSL wants a float written with a point.
        const semi = std.mem.indexOfScalar(u8, line, ';').?;
        out.print(gpa, "const float {s} = {d:.4}{s}", .{ param.name, std.math.clamp(v, param.min, param.max), line[semi..] }) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn setUniforms(prog: *const Program, p: *Pane, pw: c_int, ph: c_int, scale: f32, look: *const Look, focused: bool) void {
    const loc = &prog.loc;
    const now = glib.getMonotonicTime();
    const fw: f32 = @floatFromInt(pw);
    const fh: f32 = @floatFromInt(ph);
    const time = clock();
    const delta: f32 = if (p.last_us == 0) 0 else @floatCast(@as(f64, @floatFromInt(now - p.last_us)) / std.time.us_per_s);
    p.last_us = now;
    gl.epoxy_glUniform3f.?(loc.resolution, fw, fh, 1);
    gl.epoxy_glUniform1f.?(loc.time, time);
    gl.epoxy_glUniform1f.?(loc.time_delta, delta);
    gl.epoxy_glUniform1f.?(loc.frame_rate, if (delta > 0) 1 / delta else 60);
    gl.epoxy_glUniform1i.?(loc.frame, p.frame);
    gl.epoxy_glUniform3f.?(loc.channel_resolution, fw, fh, 1);
    gl.epoxy_glUniform4f.?(loc.mouse, 0, 0, 0, 0);
    gl.epoxy_glUniform1i.?(loc.channel0, 0);

    // Focus, and when it came.
    if (focused and !p.focused) p.focused_at = time;
    p.focused = focused;
    gl.epoxy_glUniform1i.?(loc.focus, @intFromBool(focused));
    gl.epoxy_glUniform1f.?(loc.time_focus, p.focused_at);

    // The cursor as Ghostty gives it: its left edge and its top edge counted up from the
    // bottom, then its size, in the picture's pixels. A move or a new color keeps the last
    // place as the previous one and notes the time, which is what trails are drawn from.
    const c = look.cursor;
    const box: [4]f32 = .{ c[0] * scale, fh - c[1] * scale, c[2] * scale, c[3] * scale };
    const color = rgba(look.cursor_color, 1);
    if (!std.meta.eql(box, p.current_cursor) or !std.meta.eql(color, p.current_color)) {
        p.previous_cursor = p.current_cursor;
        p.previous_color = p.current_color;
        p.previous_style = p.current_style;
        p.current_cursor = box;
        p.current_color = color;
        p.cursor_changed_at = time;
    }
    p.current_style = look.cursor_style;
    gl.epoxy_glUniform4fv.?(loc.current_cursor, 1, &p.current_cursor);
    gl.epoxy_glUniform4fv.?(loc.previous_cursor, 1, &p.previous_cursor);
    gl.epoxy_glUniform4fv.?(loc.current_cursor_color, 1, &p.current_color);
    gl.epoxy_glUniform4fv.?(loc.previous_cursor_color, 1, &p.previous_color);
    gl.epoxy_glUniform1i.?(loc.current_cursor_style, p.current_style);
    gl.epoxy_glUniform1i.?(loc.previous_cursor_style, p.previous_style);
    // One cursor at a time: the pane with the keyboard has it, so cursor effects show only there.
    gl.epoxy_glUniform1i.?(loc.cursor_visible, @intFromBool(look.cursor_visible and focused));
    gl.epoxy_glUniform1f.?(loc.time_cursor_change, p.cursor_changed_at);

    // The colors.
    const bg = rgba(look.bg, 1);
    const fg = rgba(look.fg, 1);
    gl.epoxy_glUniform3f.?(loc.background_color, bg[0], bg[1], bg[2]);
    gl.epoxy_glUniform3f.?(loc.foreground_color, fg[0], fg[1], fg[2]);
    gl.epoxy_glUniform3f.?(loc.cursor_color, color[0], color[1], color[2]);

    // The date as Shadertoy gives it: year, month from 0, day, and seconds into the day.
    const dt = glib.DateTime.newNowLocal() orelse return;
    defer dt.unref();
    const secs: f32 = @floatFromInt(dt.getHour() * 3600 + dt.getMinute() * 60);
    gl.epoxy_glUniform4f.?(loc.date, @floatFromInt(dt.getYear()), @floatFromInt(dt.getMonth() - 1), @floatFromInt(dt.getDayOfMonth()), secs + @as(f32, @floatCast(dt.getSeconds())));
}

fn rgba(color: u32, alpha: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255,
        @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(color & 0xff)) / 255,
        alpha,
    };
}

test "a shader's adjustable numbers are read from its marked constants" {
    const p = parseParam("const float CURVE = 0.10;      // 0 to 0.4: how much the glass bulges").?;
    try std.testing.expectEqualStrings("CURVE", p.name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), p.value, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p.min, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), p.max, 0.0001);
    try std.testing.expectEqualStrings("how much the glass bulges", p.about);
    const q = parseParam("  const float SPACING = 3.0; // 2 to 8").?;
    try std.testing.expectEqualStrings("", q.about);
    // Without a range there's no slider: a constant may be meant to stay as it is.
    try std.testing.expect(parseParam("const float X = 1.0; // just a note") == null);
    try std.testing.expect(parseParam("const vec3 PHOSPHOR = vec3(1.0); // 0 to 1: a color") == null);
    try std.testing.expect(parseParam("float y = 2.0;") == null);
}
