# Renux

A native Linux client for [Rex](https://rex.superlogical.com), written in Zig with GTK4 and
libadwaita. It shows a Rex server's sessions, windows and panes, with live terminals drawn
through libghostty-vt.

The program it builds is called `compy`, and its desktop ID is `dev.compy.linux`.

## Building

You need Zig 0.17, GTK 4, libadwaita and librsvg, with their development files.

```sh
git submodule update --init
zig build -Doptimize=ReleaseFast
zig build test
```

The program is `zig-out/bin/compy`. Add `-Ddev` for the development hooks: screenshots, the
test script and the frame log.

On a Mac with Homebrew, for development, point pkg-config at Homebrew first:

```sh
export PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig
```

## Layout

| Path | What it holds |
|---|---|
| `src/` | The app: `app.zig` is the window, `workspace.zig` the panes, `termview.zig` the terminal, `server.zig` the Rex protocol |
| `data/` | The desktop file, icons, fonts and program icons that are installed with it |
| `scripts/` | Generators for the icon tables in `src/` |
| `third_party/ghostty` | Ghostty, for its terminal library |

## License

Apache 2.0; see `LICENSE`. Bundled fonts and icons keep their own licenses, noted beside them.
