#!/bin/bash
# lichii-bc250 uninstaller.
#
# Usage:  ./tools/bc250/bc250-uninstall.sh [--system] [--yes]
#
#   (default)  removes what bc250-install.sh added for your user:
#                - the launcher and package in ~/Applications/lichii-bc250
#                - the "Zelda Ocarina of Time" Steam shortcut it registered (Steam must be stopped)
#                - the lichii-bc250-build and lichii-bc250-runtime containers and ~/.local/share/lichii-bc250
#                  (the LLVM download for --pgo builds)
#                - build/ and build-pgo/ in this checkout
#   --system   also reverts the README's system tuning steps (asks for sudo):
#                - removes /etc/sysctl.d/99-bc250-{swappiness,compaction,watermark}.conf
#                - puts zram back to Bazzite's default (half of RAM) in /etc/systemd/zram-generator.conf
#              The 16 GB disk swapfile and any kernel arguments are left alone; the commands to remove
#              them are printed at the end.
#   --yes      don't ask for confirmation.
#
# Never touched: your saves, keys, firmware and shader caches (~/.local/share/eden), and your game
# dump. Delete ~/.local/share/eden yourself if you want those gone too.

set -euo pipefail

APP_DIR="$HOME/Applications/lichii-bc250"
DATA_DIR="$HOME/.local/share/lichii-bc250"
CONTAINER=lichii-bc250-build
SHORTCUT_NAME="Zelda Ocarina of Time"
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

SYSTEM=0
YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --system) SYSTEM=1 ;;
        --yes|-y) YES=1 ;;
        -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

log() { printf "\033[1;36m[lichii-bc250]\033[0m %s\n" "$*"; }
confirm() {
    [ "$YES" = 1 ] && return 0
    read -r -p "$1 [y/N] " a
    [ "$a" = y ] || [ "$a" = Y ]
}

if [ "$(id -u)" = 0 ]; then
    echo "Run me as your desktop user, not as root (I ask for sudo when needed)." >&2
    exit 1
fi
if pgrep -x eden-cli >/dev/null; then
    echo "The emulator is running. Close the game first." >&2
    exit 1
fi

echo "This removes the lichii-bc250 launcher, package, Steam shortcut, build container and build files."
[ "$SYSTEM" = 1 ] && echo "It also reverts the system tuning (sysctl files, zram size) with sudo."
echo "Your saves, keys, firmware and game dump are kept."
confirm "Continue?" || { echo "Nothing changed."; exit 0; }

# --- Steam shortcut ------------------------------------------------------------
VDF=$(ls -1 "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf 2>/dev/null | head -1 || true)
if [ -n "$VDF" ] && grep -qa "$APP_DIR/lichii-bc250" "$VDF"; then
    if pgrep -x steam >/dev/null; then
        log "Steam is running: the shortcut was NOT removed (Steam would write it back)."
        log "Close Steam (Desktop Mode, quit Steam) and run me again, or delete the shortcut in Steam."
    else
        python3 - "$VDF" "$APP_DIR/lichii-bc250" <<'PY'
import shutil, struct, sys, time
vdf, exe = sys.argv[1], sys.argv[2]
d = open(vdf, "rb").read()

def parse(p):
    out = []
    while p < len(d):
        t = d[p]
        if t == 8:
            return out, p + 1
        p += 1
        ks = p
        while d[p]: p += 1
        key = d[ks:p]; p += 1
        if t == 1:
            vs = p
            while d[p]: p += 1
            out.append((t, key, d[vs:p])); p += 1
        elif t == 2:
            out.append((t, key, d[p:p + 4])); p += 4
        elif t == 0:
            sub, p = parse(p)
            out.append((t, key, sub))
        else:
            raise SystemExit(f"unknown VDF type {t}")
    return out, p

def dump(items):
    b = b""
    for t, k, v in items:
        b += bytes([t]) + k + b"\0"
        b += v + b"\0" if t == 1 else v if t == 2 else dump(v)
    return b + b"\x08"

root, _ = parse(0)
assert root and root[0][1].lower() == b"shortcuts"
entries = root[0][2]
def is_ours(e):
    for t, k, v in e[2]:
        if t == 1 and k.lower() == b"exe" and exe.encode() in v:
            return True
    return False
keep = [e for e in entries if not is_ours(e)]
if len(keep) == len(entries):
    print("no lichii-bc250 shortcut found"); raise SystemExit(0)
keep = [(0, str(i).encode(), e[2]) for i, e in enumerate(keep)]
shutil.copy2(vdf, f"{vdf}.bak-uninstall-{time.strftime('%Y%m%d-%H%M%S')}")
open(vdf, "wb").write(dump([(0, root[0][1], keep)]))
print(f"removed {len(entries) - len(keep)} shortcut(s); backup next to {vdf}")
PY
    fi
else
    log "no Steam shortcut for $APP_DIR/lichii-bc250"
fi

# --- Launcher, package, container, downloads, build dirs ----------------------
if [ -f "$APP_DIR/oot.ini" ]; then
    # The game config holds the person's controller mapping: keep a copy, which the
    # installer puts back on a reinstall.
    mkdir -p "$HOME/.config/lichii-bc250"
    cp -p "$APP_DIR/oot.ini" "$HOME/.config/lichii-bc250/oot.ini"
    log "kept your game config (controls) in ~/.config/lichii-bc250/oot.ini; a reinstall uses it"
fi
if [ -d "$APP_DIR" ]; then
    log "removing $APP_DIR"
    rm -rf "$APP_DIR"
fi
rm -f "$HOME/.local/share/applications/lichii-bc250.desktop"
if [ -d "$DATA_DIR" ]; then
    log "removing $DATA_DIR"
    rm -rf "$DATA_DIR"
fi
for c in "$CONTAINER" lichii-bc250-runtime; do
    if command -v distrobox >/dev/null && distrobox list 2>/dev/null | grep -qw "$c"; then
        log "removing the $c container"
        distrobox rm -f "$c" >/dev/null
    fi
done
for b in build build-pgo; do
    if [ -f "$REPO_DIR/$b/CMakeCache.txt" ]; then
        log "removing $REPO_DIR/$b"
        rm -rf "${REPO_DIR:?}/$b"
    fi
done

# --- System tuning ------------------------------------------------------------
if [ "$SYSTEM" = 1 ]; then
    log "reverting the system tuning (sudo)"
    sudo rm -f /etc/sysctl.d/99-bc250-swappiness.conf /etc/sysctl.d/99-bc250-compaction.conf \
               /etc/sysctl.d/99-bc250-watermark.conf
    sudo sysctl --system >/dev/null
    Z=/etc/systemd/zram-generator.conf
    if [ -f "$Z" ] && grep -q '^zram-size *= *min(ram \* 3 / 4' "$Z"; then
        sudo sed -i 's#^zram-size *=.*#zram-size = min(ram / 2, 16384)#' "$Z"
        log "zram set back to half of RAM (takes effect after a reboot)"
    fi
    cat <<'MSG'
Left in place on purpose (remove them yourself if you want):
  - the disk swapfile:   sudo swapoff /var/swap/swapfile && sudo rm /var/swap/swapfile
                         && sudo btrfs subvolume delete /var/swap
                         and delete the /var/swap/swapfile line from /etc/fstab
  - the GPU memory kernel arguments, if you added them:
      sudo rpm-ostree kargs --delete-if-present=ttm.pages_limit=3145728 \
                            --delete-if-present=ttm.page_pool_size=3145728
  - the BC-250 VRAM split (bc250memcfg UMA_SIZE): it's a firmware setting other software may rely on.
MSG
fi

log "Uninstalled. Saves, keys and firmware are still in ~/.local/share/eden."
