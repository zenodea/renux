const std = @import("std");
const App = @import("app.zig").App;

/// For the few standard library calls that need it.
pub var io: std.Io = undefined;

/// Where the running Compy writes its process ID, for `compy --toggle`.
fn pidPath(buf: []u8) ?[:0]const u8 {
    const glib = @import("glib");
    return std.fmt.bufPrintSentinel(buf, "{s}/compy.pid", .{std.mem.span(glib.getUserRuntimeDir())}, 0) catch null;
}

/// The process ID file, held open and locked for as long as this Compy runs. The lock, which the
/// system drops when the process ends however it ends, is what says the ID in the file is a
/// live Compy and not a number some other program has since been given.
var pid_fd: std.c.fd_t = -1;

/// Makes this process the one `compy --toggle` reaches, unless a running Compy already is.
pub fn claimToggle() void {
    if (pid_fd >= 0) return;
    var buf: [512]u8 = undefined;
    const path = pidPath(&buf) orelse return;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (fd < 0) return;
    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
        _ = std.c.close(fd);
        return;
    }
    var nbuf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&nbuf, "{d}\n", .{std.c.getpid()}) catch "";
    _ = std.c.ftruncate(fd, 0);
    _ = std.c.write(fd, text.ptr, text.len);
    pid_fd = fd;
}

/// Gives the toggle up as Compy quits.
fn releaseToggle() void {
    if (pid_fd < 0) return;
    var buf: [512]u8 = undefined;
    if (pidPath(&buf)) |path| _ = std.c.unlink(path.ptr);
    _ = std.c.close(pid_fd);
    pid_fd = -1;
}

/// The running Compy that `--toggle` should reach, if there is one.
fn toggleTarget() ?std.c.pid_t {
    var buf: [512]u8 = undefined;
    const path = pidPath(&buf) orelse return null;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    // Getting the lock means no Compy holds it: the file was left by one that has gone.
    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) == 0) return null;
    var text: [32]u8 = undefined;
    const n = std.c.read(fd, &text, text.len);
    if (n <= 0) return null;
    const pid = std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, text[0..@intCast(n)], " \n"), 10) catch return null;
    return if (pid > 1) pid else null;
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    // `compy --toggle`, for a desktop shortcut: shows or hides the running Compy.
    var args = init.minimal.args.iterate();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            const text = "compy " ++ @import("build_options").version ++ "\n";
            _ = std.c.write(1, text.ptr, text.len);
            return;
        }
        if (std.mem.eql(u8, arg, "--toggle")) {
            if (toggleTarget()) |pid| if (std.c.kill(pid, std.posix.SIG.USR1) == 0) return;
            break;
        }
    }
    // GTK drops the GPU programs it built for drawing once they go 15 seconds unused, then
    // builds them again at the next use, which stalls a frame for tens to hundreds of
    // milliseconds: after any pause, the next tab switch, menu or dialog hitched. A day's
    // patience keeps them for the session. Someone who set the variable themselves keeps theirs.
    _ = @import("glib").setenv("GSK_CACHE_TIMEOUT", "86400", 0);
    // Before GTK starts, which is when Pango first lists the fonts.
    @import("fonts.zig").registerBundled();
    if (@import("builtin").os.tag == .macos and std.c.getenv("COMPY_NOFOCUS") != null) @import("macos.zig").neverActivate();
    const app = try App.create();
    const code = app.run();
    // A setting changed in the last second is still waiting to be written.
    @import("settings.zig").flush();
    releaseToggle();
    std.process.exit(@intCast(code));
}

test {
    _ = @import("ws.zig");
    _ = @import("term.zig");
    _ = @import("control.zig");
    _ = @import("json.zig");
    _ = @import("view.zig");
    _ = @import("stream.zig");
    _ = @import("server.zig");
    _ = @import("keys.zig");
    _ = @import("theme.zig");
    _ = @import("boxdraw.zig");
    _ = @import("links.zig");
    _ = @import("programs.zig");
    _ = @import("blockicon.zig");
    _ = @import("palette.zig");
    _ = @import("settings.zig");
    _ = @import("themes.zig");
    _ = @import("settings_window.zig");
    _ = @import("shortcuts.zig");
    _ = @import("theme_editor.zig");
    _ = @import("tailscale.zig");
    _ = @import("qr.zig");
}
