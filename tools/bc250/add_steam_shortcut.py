#!/usr/bin/env python3
"""Add or update a non-Steam shortcut in Steam's shortcuts.vdf (binary KeyValues).

Steam's format (little-endian):
  0x00 = child dict, 0x01 = string, 0x02 = int32, 0x08 = end of dict.
The file is: 0x00 "shortcuts"\\0 <entry dicts> 0x08 0x08; without the final
extra 0x08 Steam logs "failed to load shortcut file" and deletes the VDF.

The entry is keyed by its Steam app id: crc32(exe + appname) with the high bit
set, so the same game from the same wrapper updates in place and grid artwork
stays attached. A backup of the previous file is written next to it.

Usage:
  add_steam_shortcut.py --vdf <shortcuts.vdf> --name "<AppName>" \
      --exe <path> [--launch-options "<opts>"]

Steam must be stopped when this runs.
"""
import argparse
import binascii
import shutil
import struct
import time

T_DICT, T_STR, T_INT, T_END = 0, 1, 2, 8


def parse(d, p):
    out = []
    while p < len(d):
        t = d[p]
        if t == T_END:
            return out, p + 1
        p += 1
        ks = p
        while d[p] != 0:
            p += 1
        key = d[ks:p].decode("utf-8", "replace")
        p += 1
        if t == T_STR:
            vs = p
            while d[p] != 0:
                p += 1
            out.append((key, d[vs:p].decode("utf-8", "replace")))
            p += 1
        elif t == T_INT:
            out.append((key, struct.unpack("<I", d[p:p + 4])[0]))
            p += 4
        elif t == T_DICT:
            sub, p = parse(d, p)
            out.append((key, sub))
        else:
            raise ValueError(f"unknown type byte {t:#x} at {p - 1}")
    return out, p


def serialize(pairs):
    buf = bytearray()
    for key, val in pairs:
        if isinstance(val, list):
            buf.append(T_DICT)
            buf += key.encode("utf-8") + b"\x00"
            buf += serialize(val)
            buf.append(T_END)
        elif isinstance(val, int):
            buf.append(T_INT)
            buf += key.encode("utf-8") + b"\x00" + struct.pack("<I", val & 0xFFFFFFFF)
        else:
            buf.append(T_STR)
            buf += key.encode("utf-8") + b"\x00" + str(val).encode("utf-8") + b"\x00"
    return bytes(buf)


def appid(exe, name):
    h = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return (h | 0x80000000) & 0xFFFFFFFF


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vdf", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--exe", required=True)
    ap.add_argument("--launch-options", default="")
    ap.add_argument("--sortas", default="")
    args = ap.parse_args()

    with open(args.vdf, "rb") as f:
        d = f.read()
    assert d[0] == T_DICT, "root marker not 0x00"
    p = 1
    while d[p] != 0:
        p += 1
    root_key = d[1:p].decode("utf-8", "replace")
    p += 1
    assert root_key == "shortcuts", f"unexpected root key {root_key!r}"
    entries, _ = parse(d, p)

    target = appid(args.exe, args.name)
    new_entry = [
        ("appid", target),
        ("AppName", args.name),
        ("Exe", args.exe),
        ("StartDir", args.exe.rsplit("/", 1)[0] + "/"),
        ("icon", ""),
        ("ShortcutPath", ""),
        ("LaunchOptions", args.launch_options),
        ("IsHidden", 0),
        ("AllowDesktopConfig", 1),
        ("AllowOverlay", 1),
        ("OpenVR", 0),
        ("Devkit", 0),
        ("DevkitGameID", ""),
        ("DevkitOverrideAppID", 0),
        ("LastPlayTime", int(time.time())),
        ("FlatpakAppID", ""),
        ("sortas", args.sortas or args.name),
        ("tags", []),
    ]

    found = False
    rebuilt = []
    for idx, ent in entries:
        if not isinstance(ent, list):
            rebuilt.append((idx, ent))
            continue
        hit = any(k == "appid" and v == target for k, v in ent)
        if hit and not found:
            rebuilt.append((idx, new_entry))  # update in place
            found = True
        else:
            rebuilt.append((idx, ent))
    if not found:
        rebuilt.append((str(len(rebuilt)), new_entry))

    out = bytearray()
    out.append(T_DICT)
    out += b"shortcuts\x00"
    out += serialize(rebuilt)
    out.append(T_END)
    out.append(T_END)  # document terminator

    shutil.copy2(args.vdf, args.vdf + ".bak")
    with open(args.vdf, "wb") as f:
        f.write(out)
    print(f"shortcut '{args.name}' (appid {target}) "
          f"{'updated' if found else 'added'}; backup: {args.vdf}.bak")


if __name__ == "__main__":
    main()
