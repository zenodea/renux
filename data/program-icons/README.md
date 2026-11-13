# Program icons

`scripts/gen-program-icons.py` builds `src/icons/program_icons.zig` from this folder.

Each icon is one SVG with a single path on a 24 by 24 grid, named for the program, and a
line in `colors.txt` giving the color of its tile.

- These were drawn for this app. They are plain glyphs, not those programs' logos: `aider`,
  `aws`, `azure`, `codex`, `crush`, `droid`, `eza`, `fzf`, `gdb`, `goose`, `jq`, `k9s`, `kiro`,
  `lazygit`, `less`, `man`, `nano`, `ninja`, `pi`, `ranger`, `ripgrep`, `ssh`, `systemd`, `tail`,
  `watch`, `wget`, `yazi` and `zoxide`. Several stand for a few programs of one kind, such as
  `eza` for `ls` and `systemd` for `journalctl`; `src/icons/programs.zig` says which.
- The rest come from Simple Icons, which is released under CC0 1.0.
