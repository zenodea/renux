# Program icons

`scripts/gen-program-icons.py` builds `src/program_icons.zig` from this folder.

Each icon is one SVG with a single path on a 24 by 24 grid, named for the program, and a
line in `colors.txt` giving the color of its tile.

- `codex.svg`, `lazygit.svg`, `yazi.svg` and `ssh.svg` were drawn for this app. They are
  plain glyphs, not those programs' logos.
- The rest come from Simple Icons, which is released under CC0 1.0.
