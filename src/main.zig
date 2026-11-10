const std = @import("std");
const App = @import("app/app.zig").App;

/// For the few standard library calls that need it.
pub var io: std.Io = undefined;

/// Where the running Renux writes its process ID, for `renux --toggle`.
fn pidPath(buf: []u8) ?[:0]const u8 {
    const glib = @import("glib");
    return std.fmt.bufPrintSentinel(buf, "{s}/renux.pid", .{std.mem.span(glib.getUserRuntimeDir())}, 0) catch null;
}

/// The process ID file, held open and locked for as long as this Renux runs. The lock, which the
/// system drops when the process ends however it ends, is what says the ID in the file is a
/// live Renux and not a number some other program has since been given.
var pid_fd: std.c.fd_t = -1;

/// Makes this process the one `renux --toggle` reaches, unless a running Renux already is.
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

/// Gives the toggle up as Renux quits.
fn releaseToggle() void {
    if (pid_fd < 0) return;
    var buf: [512]u8 = undefined;
    if (pidPath(&buf)) |path| _ = std.c.unlink(path.ptr);
    _ = std.c.close(pid_fd);
    pid_fd = -1;
}

/// The running Renux that `--toggle` should reach, if there is one.
fn toggleTarget() ?std.c.pid_t {
    var buf: [512]u8 = undefined;
    const path = pidPath(&buf) orelse return null;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    // Getting the lock means no Renux holds it: the file was left by one that has gone.
    if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) == 0) return null;
    var text: [32]u8 = undefined;
    const n = std.c.read(fd, &text, text.len);
    if (n <= 0) return null;
    const pid = std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, text[0..@intCast(n)], " \n"), 10) catch return null;
    return if (pid > 1) pid else null;
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    // `renux --toggle`, for a desktop shortcut: shows or hides the running Renux.
    var args = init.minimal.args.iterate();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            const text = "renux " ++ @import("build_options").version ++ "\n";
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
    @import("terminal/fonts.zig").registerBundled();
    if (@import("builtin").os.tag == .macos and std.c.getenv("RENUX_NOFOCUS") != null) @import("platform/macos.zig").neverActivate();
    const app = try App.create();
    const code = app.run();
    // A setting changed in the last second is still waiting to be written.
    @import("settings/settings.zig").flush();
    releaseToggle();
    std.process.exit(@intCast(code));
}

test {
    _ = @import("rex/ws.zig");
    _ = @import("terminal/term.zig");
    _ = @import("rex/control.zig");
    _ = @import("util/json.zig");
    _ = @import("rex/view.zig");
    _ = @import("rex/stream.zig");
    _ = @import("rex/server.zig");
    _ = @import("terminal/keys.zig");
    _ = @import("theme/theme.zig");
    _ = @import("terminal/boxdraw.zig");
    _ = @import("terminal/links.zig");
    _ = @import("icons/programs.zig");
    _ = @import("icons/blockicon.zig");
    _ = @import("ui/palette.zig");
    _ = @import("settings/settings.zig");
    _ = @import("theme/themes.zig");
    _ = @import("settings/settings_window.zig");
    _ = @import("settings/shortcuts.zig");
    _ = @import("settings/theme_editor.zig");
    _ = @import("rex/tailscale.zig");
    _ = @import("util/qr.zig");
}
