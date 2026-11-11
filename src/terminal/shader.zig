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

// The one OpenGL context all panes draw their shaders in, and the program built from the file.
var context: ?*gdk.GLContext = null;
var context_failed = false;
var program: c_uint = 0;
var vao: c_uint = 0;
var loc: Locations = .{};
/// Which file the program came from and a hash of what it said, to build it again on a change.
var source_path: ?[:0]u8 = null;
var source_hash: u64 = 0;
var checked_at: i64 = 0;
/// The source uses the time, so the panes draw every frame.
var uses_time = false;
var started_at: i64 = 0;

const recheck_us = 500 * std.time.us_per_ms;

/// Each pane's own textures, kept between frames.
pub const Pane = struct {
    input: c_uint = 0,
    input_w: c_int = 0,
    input_h: c_int = 0,
    fbo: c_uint = 0,
    frame: i32 = 0,
    last_us: i64 = 0,

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
    channel0: c_int = -1,
};

/// Whether a shader is set and ready. Reads the file again now and then, and builds the
/// program again when what it says has changed, so a shader can be edited while it runs.
pub fn active() bool {
    const setting = settings.current.custom_shader;
    if (setting.len == 0) {
        unload();
        return false;
    }
    const now = glib.getMonotonicTime();
    const same_path = if (source_path) |p| std.mem.eql(u8, p, setting) else false;
    if (same_path and now - checked_at < recheck_us) return program != 0;
    checked_at = now;
    if (!same_path) {
        if (source_path) |p| gpa.free(p);
        source_path = gpa.dupeSentinel(u8, setting, 0) catch null;
        source_hash = 0;
    }
    const source = readSource(setting) orelse {
        if (source_hash != 1) report("Couldn't read the shader file", setting);
        source_hash = 1;
        unloadProgram();
        return false;
    };
    defer gpa.free(source);
    const hash = std.hash.Wyhash.hash(0, source);
    if (hash == source_hash) return program != 0;
    source_hash = hash;
    unloadProgram();
    build(source);
    return program != 0;
}

/// Whether the shader draws differently as time passes, so its panes draw every frame.
pub fn animated() bool {
    return program != 0 and uses_time;
}

fn readSource(path: []const u8) ?[]u8 {
    // ~ is the home folder, as in a shell.
    const full = if (std.mem.startsWith(u8, path, "~/"))
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

fn unload() void {
    unloadProgram();
    if (source_path) |p| gpa.free(p);
    source_path = null;
    source_hash = 0;
}

fn unloadProgram() void {
    if (program == 0) return;
    const ctx = context orelse return;
    ctx.makeCurrent();
    gl.epoxy_glDeleteProgram.?(program);
    program = 0;
    gdk.GLContext.clearCurrent();
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
    \\void mainImage(out vec4 fragColor, in vec2 fragCoord);
    \\void main() { mainImage(_fragColor, gl_FragCoord.xy); }
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

fn build(source: []const u8) void {
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
    const p = gl.epoxy_glCreateProgram.?();
    gl.epoxy_glAttachShader.?(p, vs);
    gl.epoxy_glAttachShader.?(p, fs);
    gl.epoxy_glLinkProgram.?(p);
    var ok: c_int = 0;
    gl.epoxy_glGetProgramiv.?(p, gl.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var info: [1024]u8 = undefined;
        var len: c_int = 0;
        gl.epoxy_glGetProgramInfoLog.?(p, info.len, &len, &info);
        report("The shader didn't link", firstLine(info[0..@intCast(@max(0, len))]));
        gl.epoxy_glDeleteProgram.?(p);
        return;
    }
    program = p;
    if (vao == 0) gl.epoxy_glGenVertexArrays.?(1, &vao);
    inline for (comptime std.meta.fieldNames(Locations)) |field| {
        const name = comptime uniformName(field);
        @field(loc, field) = gl.epoxy_glGetUniformLocation.?(p, name.ptr);
    }
    uses_time = std.mem.indexOf(u8, source, "iTime") != null or std.mem.indexOf(u8, source, "iFrame") != null or std.mem.indexOf(u8, source, "iDate") != null;
    started_at = glib.getMonotonicTime();
    log.info("shader ready: {s}", .{source_path orelse ""});
}

fn uniformName(comptime field: []const u8) [:0]const u8 {
    return comptime blk: {
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

/// What one pane's frame cost, for RENUX_SHADER_STATS.
const Stats = struct {
    frames: u32 = 0,
    render: i64 = 0,
    download: i64 = 0,
    upload: i64 = 0,
    shade: i64 = 0,
    since: i64 = 0,
    px: u64 = 0,
};
var stats: Stats = .{};
var stats_on: ?bool = null;

/// Draws `node`, a pane's own drawing, through the shader into `sn`. False if it couldn't, and
/// the caller draws `node` as it is.
pub fn drawPane(p: *Pane, widget: *gtk.Widget, node: *gsk.RenderNode, focused: bool, sn: *gtk.Snapshot) bool {
    if (program == 0) return false;
    const ctx = context orelse return false;
    const w: f32 = @floatFromInt(widget.getWidth());
    const h: f32 = @floatFromInt(widget.getHeight());
    if (w < 1 or h < 1) return false;
    const native = widget.getNative() orelse return false;
    const renderer = native.getRenderer() orelse return false;
    const scale: f32 = if (native.getSurface()) |s| @floatCast(s.getScale()) else 1;
    const pw: c_int = @intFromFloat(@round(w * scale));
    const ph: c_int = @intFromFloat(@round(h * scale));
    const t0 = glib.getMonotonicTime();

    // 1. The pane's picture, at the screen's pixel size, upside down for OpenGL.
    const flip = gtk.Snapshot.new();
    flip.translate(&.{ .f_x = 0, .f_y = @floatFromInt(ph) });
    flip.scale(scale, -scale);
    flip.appendNode(node);
    const flipped = flip.freeToNode() orelse return false;
    defer flipped.unref();
    var viewport: graphene.Rect = .{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = @floatFromInt(pw), .f_height = @floatFromInt(ph) } };
    const picture = renderer.renderTexture(flipped, &viewport);
    defer picture.unref();
    const t1 = glib.getMonotonicTime();

    // 2. Into OpenGL.
    const downloader = gdk.TextureDownloader.new(picture);
    defer downloader.free();
    downloader.setFormat(.r8g8b8a8_premultiplied);
    var stride: usize = 0;
    const bytes = downloader.downloadBytes(&stride);
    defer bytes.unref();
    var size: usize = 0;
    const data = bytes.getData(&size) orelse return false;
    const t2 = glib.getMonotonicTime();

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
    const t3 = glib.getMonotonicTime();

    // 3. The shader, into a texture of its own that GTK holds until it has shown it.
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
    gl.epoxy_glUseProgram.?(program);
    setUniforms(p, pw, ph, focused);
    gl.epoxy_glActiveTexture.?(gl.GL_TEXTURE0);
    gl.epoxy_glBindTexture.?(gl.GL_TEXTURE_2D, p.input);
    gl.epoxy_glBindVertexArray.?(vao);
    gl.epoxy_glDrawArrays.?(gl.GL_TRIANGLES, 0, 3);
    gl.epoxy_glBindVertexArray.?(0);
    gl.epoxy_glBindFramebuffer.?(gl.GL_FRAMEBUFFER, 0);
    const sync = gl.epoxy_glFenceSync.?(gl.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    gl.epoxy_glFlush.?();
    const t4 = glib.getMonotonicTime();

    // 4. Back to GTK, turned the right way up again.
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
    sn.translate(&.{ .f_x = 0, .f_y = h });
    sn.scale(1, -1);
    sn.appendTexture(result, &.{ .f_origin = .{ .f_x = 0, .f_y = 0 }, .f_size = .{ .f_width = w, .f_height = h } });
    sn.restore();

    p.frame +%= 1;
    count(t1 - t0, t2 - t1, t3 - t2, t4 - t3, @intCast(pw * ph));
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

fn setUniforms(p: *Pane, pw: c_int, ph: c_int, focused: bool) void {
    const now = glib.getMonotonicTime();
    const fw: f32 = @floatFromInt(pw);
    const fh: f32 = @floatFromInt(ph);
    const time: f32 = @floatCast(@as(f64, @floatFromInt(now - started_at)) / std.time.us_per_s);
    const delta: f32 = if (p.last_us == 0) 0 else @floatCast(@as(f64, @floatFromInt(now - p.last_us)) / std.time.us_per_s);
    p.last_us = now;
    gl.epoxy_glUniform3f.?(loc.resolution, fw, fh, 1);
    gl.epoxy_glUniform1f.?(loc.time, time);
    gl.epoxy_glUniform1f.?(loc.time_delta, delta);
    gl.epoxy_glUniform1f.?(loc.frame_rate, if (delta > 0) 1 / delta else 60);
    gl.epoxy_glUniform1i.?(loc.frame, p.frame);
    gl.epoxy_glUniform3f.?(loc.channel_resolution, fw, fh, 1);
    gl.epoxy_glUniform4f.?(loc.mouse, 0, 0, 0, 0);
    gl.epoxy_glUniform1i.?(loc.focus, @intFromBool(focused));
    gl.epoxy_glUniform1i.?(loc.channel0, 0);
    // The date as Shadertoy gives it: year, month from 0, day, and seconds into the day.
    const dt = glib.DateTime.newNowLocal() orelse return;
    defer dt.unref();
    const secs: f32 = @floatFromInt(dt.getHour() * 3600 + dt.getMinute() * 60);
    gl.epoxy_glUniform4f.?(loc.date, @floatFromInt(dt.getYear()), @floatFromInt(dt.getMonth() - 1), @floatFromInt(dt.getDayOfMonth()), secs + @as(f32, @floatCast(dt.getSeconds())));
}

/// RENUX_SHADER_STATS=1 logs what the round trip costs, every two seconds.
fn count(render: i64, download: i64, upload: i64, shade: i64, px: u64) void {
    if (stats_on == null) stats_on = std.c.getenv("RENUX_SHADER_STATS") != null;
    if (!stats_on.?) return;
    const now = glib.getMonotonicTime();
    if (stats.since == 0) stats.since = now;
    stats.frames += 1;
    stats.render += render;
    stats.download += download;
    stats.upload += upload;
    stats.shade += shade;
    stats.px = @max(stats.px, px);
    if (now - stats.since < 2 * std.time.us_per_s) return;
    const n: f64 = @floatFromInt(stats.frames);
    const ms = struct {
        fn of(total: i64, frames: f64) f64 {
            return @as(f64, @floatFromInt(total)) / 1000 / frames;
        }
    }.of;
    std.debug.print("shader: {d} pane frames in 2 s, per frame: render {d:.2} ms, download {d:.2} ms, upload {d:.2} ms, shader {d:.2} ms (largest pane {d} px)\n", .{ stats.frames, ms(stats.render, n), ms(stats.download, n), ms(stats.upload, n), ms(stats.shade, n), stats.px });
    stats = .{};
}
