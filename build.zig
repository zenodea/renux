const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const gobject = b.dependency("gobject", .{ .target = target, .optimize = optimize });
    inline for (.{
        .{ "adw", "adw1" },
        .{ "gdk", "gdk4" },
        .{ "gio", "gio2" },
        .{ "glib", "glib2" },
        .{ "gobject", "gobject2" },
        .{ "gtk", "gtk4" },
        .{ "pango", "pango1" },
        .{ "pangocairo", "pangocairo1" },
        .{ "cairo", "cairo1" },
        .{ "gsk", "gsk4" },
        .{ "glibunix", "glibunix2" },
        .{ "rsvg", "rsvg2" },
    }) |import| {
        mod.addImport(import[0], gobject.module(import[1]));
    }

    // libghostty-vt through its C API, the same one the Android app uses.
    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = .ReleaseFast });
    const vt_lib = ghostty.artifact("ghostty-vt-static");
    mod.linkLibrary(vt_lib);
    // The installed headers include a generated version.h, so read them from there.
    const vt_header = b.addTranslateC(.{
        .root_source_file = vt_lib.getEmittedIncludeTree().path(b, "ghostty/vt.h"),
        .target = target,
        .optimize = optimize,
    });
    vt_header.addIncludePath(vt_lib.getEmittedIncludeTree());
    vt_header.defineCMacro("GHOSTTY_STATIC", "");
    mod.addImport("vtc", vt_header.createModule());

    const exe = b.addExecutable(.{ .name = "compy", .root_module = mod });
    b.installArtifact(exe);

    // The app icon and desktop entry, where Linux desktops look for them.
    b.installFile("data/dev.compy.linux.svg", "share/icons/hicolor/scalable/apps/dev.compy.linux.svg");
    b.installFile("data/dev.compy.linux.png", "share/icons/hicolor/512x512/apps/dev.compy.linux.png");
    b.installFile("data/dev.compy.linux.desktop", "share/applications/dev.compy.linux.desktop");
    // Nerd Font symbols, so icons in prompts show with any font.
    b.installFile("data/fonts/SymbolsNerdFontMono-Regular.ttf", "share/compy/fonts/SymbolsNerdFontMono-Regular.ttf");
    b.installFile("data/fonts/SymbolsNerdFont-LICENSE.txt", "share/compy/fonts/SymbolsNerdFont-LICENSE.txt");
    // Fontconfig takes the bundled font on Linux.
    if (target.result.os.tag != .macos) mod.linkSystemLibrary("fontconfig", .{});


    // On a Mac (only used for development) Zig's linker names a library once for every binding
    // module that links it, and dyld refuses such a binary. So there the binding modules link
    // nothing and the app links each library once.
    if (target.result.os.tag == .macos) {
        var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        unlinkBindings(b.allocator, &seen, mod, gobject.builder);
        // For setting the Dock icon through the Objective-C runtime.
        mod.linkSystemLibrary("objc", .{ .use_pkg_config = .no });
        mod.linkFramework("AppKit", .{});
        // For registering the bundled font with Core Text.
        mod.linkFramework("CoreText", .{});
        mod.linkFramework("CoreFoundation", .{});
        // One pkg-config call, so a library shared by several packages appears once.
        const flags = b.run(&.{ "pkg-config", "--libs", "libadwaita-1", "gtk4", "pangocairo", "librsvg-2.0" });
        var it = std.mem.tokenizeAny(u8, flags, " \n");
        while (it.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "-L")) {
                mod.addLibraryPath(.{ .cwd_relative = flag[2..] });
            } else if (std.mem.startsWith(u8, flag, "-l")) {
                mod.linkSystemLibrary(flag[2..], .{ .use_pkg_config = .no });
            }
        }
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run Compy").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// Clears what the binding modules link. The bindings import each other, so it tracks what it saw.
fn unlinkBindings(
    gpa: std.mem.Allocator,
    seen: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
    m: *std.Build.Module,
    bindings: *std.Build,
) void {
    for (m.import_table.values()) |dep| {
        if (dep.owner != bindings) continue;
        if ((seen.getOrPut(gpa, dep) catch @panic("OOM")).found_existing) continue;
        dep.link_objects.clearRetainingCapacity();
        unlinkBindings(gpa, seen, dep, bindings);
    }
}
