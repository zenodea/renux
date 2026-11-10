//! The card that appears beside a sidebar row when the pointer rests on it, as in Rex: the
//! window's name, then each of its panes with what runs there, how it's doing and where.
const std = @import("std");
const glib = @import("glib");
const gtk = @import("gtk");
const pango = @import("pango");
const Server = @import("server.zig").Server;
const blockicon = @import("blockicon.zig");
const programs = @import("programs.zig");

const gpa = std.heap.c_allocator;

/// How long the pointer rests on a row before its card shows.
const delay_ms = 450;

/// One card serves every row; it sits beside whichever row the pointer is on.
var card: ?*gtk.Popover = null;
var timer: c_uint = 0;
var waiting: ?*Ctx = null;

const Ctx = struct {
    row: *gtk.Widget,
    /// The row's own name for the window, which heads the card. It lives as long as the row.
    title: *gtk.Label,
    server: *Server,
    session_id: []u8,
    window_id: []u8,
};

/// Makes `row` show the card for one window of a session while the pointer rests on it.
pub fn attach(row: *gtk.Widget, title: *gtk.Label, server: *Server, session_id: []const u8, window_id: []const u8) void {
    const ctx = gpa.create(Ctx) catch return;
    const sid = gpa.dupe(u8, session_id) catch return gpa.destroy(ctx);
    const wid = gpa.dupe(u8, window_id) catch {
        gpa.free(sid);
        return gpa.destroy(ctx);
    };
    ctx.* = .{ .row = row, .title = title, .server = server, .session_id = sid, .window_id = wid };
    const motion = gtk.EventControllerMotion.new();
    _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Ctx, &entered, ctx, .{});
    _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Ctx, &left, ctx, .{});
    row.addController(motion.as(gtk.EventController));
    _ = gtk.Widget.signals.destroy.connect(row, *Ctx, &rowGone, ctx, .{});
    last = ctx;
}

/// Development: the row attached last, and its card shown as resting the pointer on it would.
var last: ?*Ctx = null;

/// Development: the card's widget while it is showing, for screenshots.
pub fn visibleCard() ?*gtk.Widget {
    const c = card orelse return null;
    return if (c.as(gtk.Widget).getMapped() != 0) c.as(gtk.Widget) else null;
}

pub fn showLast() void {
    if (last) |ctx| show(ctx);
}

fn entered(_: *gtk.EventControllerMotion, _: f64, _: f64, ctx: *Ctx) callconv(.c) void {
    cancel();
    waiting = ctx;
    timer = glib.timeoutAdd(delay_ms, &fire, null);
}

fn left(_: *gtk.EventControllerMotion, ctx: *Ctx) callconv(.c) void {
    if (waiting == ctx) cancel();
    hide(ctx.row);
}

fn rowGone(row: *gtk.Widget, ctx: *Ctx) callconv(.c) void {
    if (waiting == ctx) cancel();
    if (last == ctx) last = null;
    // The card must not go down with a row it happens to sit beside.
    if (card) |c| if (c.as(gtk.Widget).getParent() == row) c.as(gtk.Widget).unparent();
    gpa.free(ctx.session_id);
    gpa.free(ctx.window_id);
    gpa.destroy(ctx);
}

fn cancel() void {
    if (timer != 0) _ = glib.Source.remove(timer);
    timer = 0;
    waiting = null;
}

fn hide(row: *gtk.Widget) void {
    const c = card orelse return;
    if (c.as(gtk.Widget).getParent() == row) c.popdown();
}

fn fire(_: ?*anyopaque) callconv(.c) c_int {
    timer = 0;
    const ctx = waiting orelse return 0;
    waiting = null;
    show(ctx);
    return 0;
}

fn show(ctx: *Ctx) void {
    if (!ctx.server.isLive()) return;
    const v = ctx.server.sessionView(ctx.session_id) orelse return;
    const w = v.window(ctx.window_id) orelse return;
    const c = card orelse blk: {
        const made = gtk.Popover.new();
        _ = made.as(@import("gobject").Object).refSink();
        made.setAutohide(0);
        made.setHasArrow(0);
        made.setPosition(.right);
        made.as(gtk.Widget).setCanFocus(0);
        made.as(gtk.Widget).setCanTarget(0);
        made.as(gtk.Widget).addCssClass("hover-card");
        card = made;
        break :blk made;
    };
    const cw = c.as(gtk.Widget);
    if (cw.getParent() != ctx.row) {
        if (cw.getParent() != null) cw.unparent();
        cw.setParent(ctx.row);
    }

    const box = gtk.Box.new(.vertical, 8);
    var buf: [320]u8 = undefined;
    var zbuf: [321]u8 = undefined;
    const heading = gtk.Label.new(ctx.title.getText());
    heading.setXalign(0);
    heading.setEllipsize(.end);
    heading.as(gtk.Widget).addCssClass("hover-title");
    box.append(heading.as(gtk.Widget));
    var shown: usize = 0;
    for (w.layers) |l| for (l.blocks) |b| {
        if (!b.isTerminal() or shown == 8) continue;
        shown += 1;
        const info = ctx.server.blockInfo(b.id);
        const line = gtk.Box.new(.horizontal, 8);
        const icon = blockicon.create(ctx.server, b.id, 16);
        icon.setValign(.start);
        icon.setMarginTop(2);
        line.append(icon);
        const text = gtk.Box.new(.vertical, 1);
        text.as(gtk.Widget).setHexpand(1);
        // What runs there: the title a program gave its pane, or the program's name.
        const prog: ?[]const u8 = if (info) |i| ((if (i.has_status) i.status_app else null) orelse i.program) else null;
        // A shell's own title is only its prompt's idea of one, so a shell goes by its name.
        const is_shell = if (prog) |p| @import("termview.zig").TermView.isShell(programs.programName(p)) else true;
        const own_title: ?[]const u8 = if (is_shell) null else if (info) |i| (if (i.title) |t| (if (t.len > 0) t else null) else null) else null;
        const name = own_title orelse programs.displayTitle(&buf, prog, null);
        const top = gtk.Box.new(.horizontal, 8);
        const name_label = gtk.Label.new(zt(&zbuf, name).ptr);
        name_label.setXalign(0);
        name_label.setEllipsize(.end);
        name_label.as(gtk.Widget).setHexpand(1);
        name_label.as(gtk.Widget).addCssClass("hover-name");
        top.append(name_label.as(gtk.Widget));
        if (info) |i| if (i.has_status) {
            const state: ?[:0]const u8 = switch (i.status) {
                .blocked => "Blocked",
                .failed => "Failed",
                .working => "Working",
                .done => "Done",
                .other => null,
            };
            if (state) |text_of| {
                const chip = gtk.Label.new(text_of.ptr);
                chip.as(gtk.Widget).addCssClass("hover-chip");
                chip.as(gtk.Widget).addCssClass(@tagName(i.status));
                chip.as(gtk.Widget).setValign(.center);
                top.append(chip.as(gtk.Widget));
            }
        };
        text.append(top.as(gtk.Widget));
        if (info) |i| {
            // What it says about itself, or failing that what kind of thing it waits on.
            const said: ?[]const u8 = if (i.message) |m| (if (m.len > 0) m else null) else null;
            const kind: ?[]const u8 = if (!i.has_status) null else if (i.status_kind) |k| (if (std.mem.eql(u8, k, "permission")) "permission prompt" else if (k.len > 0) k else null) else null;
            if (said orelse kind) |line_text| text.append(dim(zt(&zbuf, line_text)));
            if (i.folder) |f| text.append(dim(zt(&zbuf, programs.shortFolder(&buf, f))));
        }
        line.append(text.as(gtk.Widget));
        box.append(line.as(gtk.Widget));
    };
    c.setChild(box.as(gtk.Widget));
    c.popup();
}

/// `text` with the zero at its end that GTK reads to, cut short if it's longer than `buf`.
fn zt(buf: []u8, text: []const u8) [:0]const u8 {
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn dim(text: [:0]const u8) *gtk.Widget {
    const l = gtk.Label.new(text.ptr);
    l.setXalign(0);
    l.setEllipsize(.end);
    l.as(gtk.Widget).addCssClass("hover-dim");
    return l.as(gtk.Widget);
}
