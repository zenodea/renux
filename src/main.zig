const std = @import("std");
const App = @import("app.zig").App;

/// For the few standard library calls that need it.
pub var io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const app = try App.create();
    std.process.exit(@intCast(app.run()));
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
}
