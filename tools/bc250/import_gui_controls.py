#!/usr/bin/env python3
"""Copy the controller mapping made in the Lichii GUI into the game's config file.

The Steam shortcut runs eden-cli with its own config (game.ini; oot.ini before v18), while the GUI keeps its settings in
~/.config/eden/qt-config.ini. When a controller is mapped in the GUI (Emulation > Configure >
Controls), the launcher calls this script before starting the game: it replaces the player_*
lines of [Controls] in the game config with the GUI's and leaves every other line alone.

It copies only when the GUI's mapping changed since the last copy (a hash is kept next to the
game config) and only a mapping someone actually made (a "player_0_button_*\\default=false" line).
An untouched GUI config holds the keyboard defaults, which must never replace the gamepad mapping.
The game config is backed up to <config>.before-gui-controls first.

Usage: import_gui_controls.py <game config.ini> [<gui qt-config.ini>]
"""
import hashlib
import os
import re
import shutil
import sys

PLAYER = re.compile(r"^player_\d+_")


def controls_block(lines):
    """Return (start, end) line indexes of the [Controls] body, or None."""
    start = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            if start is not None:
                return start, i
            if s == "[Controls]":
                start = i + 1
    return (start, len(lines)) if start is not None else None


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    game = sys.argv[1]
    if len(sys.argv) > 2:
        gui = sys.argv[2]
    else:
        base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
        gui = os.path.join(base, "eden", "qt-config.ini")
    if not os.path.isfile(game) or not os.path.isfile(gui):
        return 0

    with open(gui, encoding="utf-8", errors="replace") as f:
        gui_lines = f.read().splitlines()
    block = controls_block(gui_lines)
    if block is None:
        return 0
    # One line per key, the last one wins (as when the emulator reads the file); keys with a
    # doubled backslash are leftovers of hand edits that nothing reads.
    entries = {}
    for line in gui_lines[block[0]:block[1]]:
        if PLAYER.match(line) and "=" in line:
            key = line.split("=", 1)[0]
            if "\\\\" not in key:
                entries.pop(key, None)
                entries[key] = line
    mapping = sorted(entries.values(), key=lambda l: l.split("=", 1)[0])
    if not any(re.match(r"^player_0_button_\w+\\default=false$", l.strip()) for l in mapping):
        return 0  # nothing mapped in the GUI: keep the game config's mapping

    digest = hashlib.sha256("\n".join(mapping).encode()).hexdigest()
    stamp = game + ".gui-controls"
    try:
        with open(stamp, encoding="utf-8") as f:
            if f.read().strip() == digest:
                return 0
    except OSError:
        pass

    with open(game, encoding="utf-8", errors="replace") as f:
        game_lines = f.read().splitlines()
    block = controls_block(game_lines)
    if block is None:
        game_lines += ["", "[Controls]"] + mapping
    else:
        body = [l for l in game_lines[block[0]:block[1]] if not PLAYER.match(l)]
        game_lines = game_lines[:block[0]] + mapping + body + game_lines[block[1]:]

    shutil.copy2(game, game + ".before-gui-controls")
    tmp = game + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(game_lines) + "\n")
    os.replace(tmp, game)
    with open(stamp, "w", encoding="utf-8") as f:
        f.write(digest + "\n")
    print(f"lichii-bc250: copied the controller mapping from {gui} into {game} "
          f"(previous file: {game}.before-gui-controls)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
