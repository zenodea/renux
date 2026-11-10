const std = @import("std");
const App = @import("app.zig").App;

/// For the few standard library calls that need it.
pub var io: std.Io = undefined;

/// Where the running Compy writes its process ID, for `compy --toggle`.
pub fn pidPath(buf: []u8) ?[:0]const u8 {
    const glib = @import("glib");
    return std.fmt.bufPrintSentinel(buf, "{s}/compy.pid", .{std.mem.span(glib.getUserRuntimeDir())}, 0) catch null;
}

pub fn main(init: std.process.Init) !void {
    io = init.io;
    // `compy --toggle`, for a desktop shortcut: shows or hides the running Compy.
    var args = init.minimal.args.iterate();
    while (args.next()) |arg| if (std.mem.eql(u8, arg, "--toggle")) {
        var buf: [512]u8 = undefined;
        if (pidPath(&buf)) |path| if (readPid(path)) |pid| {
            if (std.c.kill(pid, std.posix.SIG.USR1) == 0) return;
        };
        break;
    };
    // Before GTK starts, which is when Pango first lists the fonts.
    @import("fonts.zig").registerBundled();
    if (@import("builtin").os.tag == .macos and std.c.getenv("COMPY_NOFOCUS") != null) @import("macos.zig").neverActivate();
    const app = try App.create();
    std.process.exit(@intCast(app.run()));
}

fn readPid(path: [:0]const u8) ?std.c.pid_t {
    const glib = @import("glib");
    var contents: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(path.ptr, &contents, &len, null) == 0) return null;
    defer glib.free(contents);
    return std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, contents[0..len], " \n"), 10) catch null;
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
    _ = @import("tailscale.zig");
    _ = @import("qr.zig");
}
