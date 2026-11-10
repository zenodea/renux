//! Short local commands, such as `tailscale status`, run without holding up the window: the
//! command runs beside the main loop and its answer arrives there later. Main thread only.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");

const gpa = std.heap.c_allocator;

/// A command that hasn't answered by now is stuck, and is ended.
const patience_ms = 10_000;
const max_args = 8;

/// Hears what the command printed, or null if it failed to answer. The text lives only for the call.
pub const Done = *const fn (ctx: ?*anyopaque, output: ?[]const u8) void;

const Job = struct {
    ctx: ?*anyopaque,
    done: Done,
    proc: *gio.Subprocess,
    timer: c_uint = 0,
};

/// A launcher whose commands don't inherit the Rex terminal Renux may itself have been started
/// from, so `rex` and others talk to this computer's own server rather than that terminal's.
fn launcher(flags: gio.SubprocessFlags) *gio.SubprocessLauncher {
    const l = gio.SubprocessLauncher.new(flags);
    inline for (.{ "REX_SERVER", "REX_SESSION", "REX_BLOCK" }) |name| l.unsetenv(name);
    return l;
}

fn spawn(argv: []const [:0]const u8, flags: gio.SubprocessFlags) ?*gio.Subprocess {
    if (argv.len == 0 or argv.len > max_args) return null;
    var args: [max_args + 1]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| args[i] = a.ptr;
    const l = launcher(flags);
    defer l.as(gobject.Object).unref();
    var err: ?*glib.Error = null;
    const proc = l.spawnv(@ptrCast(&args), &err);
    if (err) |e| e.free();
    return proc;
}

/// Runs a command and tells `done` what it printed, once, later. False if it couldn't be
/// started at all, such as when the program isn't installed; `done` isn't called then.
pub fn run(argv: []const [:0]const u8, ctx: ?*anyopaque, done: Done) bool {
    const job = gpa.create(Job) catch return false;
    const proc = spawn(argv, .{ .stdout_pipe = true, .stderr_silence = true }) orelse {
        gpa.destroy(job);
        return false;
    };
    job.* = .{ .ctx = ctx, .done = done, .proc = proc };
    job.timer = glib.timeoutAdd(patience_ms, &stuck, job);
    proc.communicateUtf8Async(null, null, &finished, job);
    return true;
}

/// Starts a command and leaves it to run, for ones that outlive the click that started them.
pub fn start(argv: []const [:0]const u8) bool {
    const proc = spawn(argv, .{ .stdout_silence = true, .stderr_silence = true }) orelse return false;
    proc.as(gobject.Object).unref();
    return true;
}

fn stuck(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data.?));
    job.timer = 0;
    // Ending it makes the read below finish, which answers `done`.
    job.proc.forceExit();
    return 0;
}

fn finished(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    defer {
        if (job.timer != 0) _ = glib.Source.remove(job.timer);
        job.proc.as(gobject.Object).unref();
        gpa.destroy(job);
    }
    var out: ?[*:0]u8 = null;
    var err: ?*glib.Error = null;
    const ok = job.proc.communicateUtf8Finish(result, @ptrCast(&out), null, &err) != 0;
    if (err) |e| e.free();
    defer if (out) |o| glib.free(o);
    job.done(job.ctx, if (ok) if (out) |o| std.mem.span(o) else "" else null);
}
