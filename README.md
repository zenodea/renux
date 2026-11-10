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
| `src/main.zig` | Where the program starts |
| `src/app/` | The window and its actions, start-up, local server and pairing pages |
| `src/ui/` | Panes and their cards, the agent board, the activity panel, the palette and other dialogs, find, hover cards |
| `src/terminal/` | The terminal widget, the terminal model on libghostty-vt, keys, links, fonts |
| `src/rex/` | The Rex protocol: control connection, output streams, WebSocket, layout model |
| `src/settings/` | Settings, their window, shortcuts and the theme editor |
| `src/theme/` | Colors and built-in themes |
| `src/icons/` | Interface and program icons, and how they are drawn |
| `src/platform/` | Parts for one operating system only |
| `src/util/` | Small helpers: JSON, drawing, subprocesses, QR codes |
| `data/` | What is installed beside the program: desktop file, app icons, fonts, program icons |
| `scripts/` | Generators for the icon tables in `src/icons/` |
| `third_party/ghostty` | Ghostty, for its terminal library |

## License

Apache 2.0; see `LICENSE`. Bundled fonts and icons keep their own licenses, noted beside them.
