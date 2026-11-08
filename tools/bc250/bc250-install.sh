#!/bin/bash
# oot-bc250 installer for the AMD BC-250 console (Bazzite).
#
# Usage:  ./tools/bc250/bc250-install.sh [--with-shortcut] [--game <path>]
#         or:  curl -fsSL <repo>/tools/bc250/bc250-install.sh | bash -s -- --with-shortcut
#
# What it does:
#   1. Creates a Fedora 42 distrobox container and installs the build dependencies in it.
#   2. Builds the eden-cli binary from this checkout (Release, clang, no Qt).
#   3. Installs the launch wrapper with the BC-250 tuning and the per-game config template.
#   4. Optionally registers a Steam non-Steam shortcut for your Ocarina of Time dump
#      (requires Steam to be stopped; the installer tells you when).
#
# The first launch of the game stays on a black screen for 3-5 minutes while it prepares
# the shader pipelines; later boots are much faster. See the README for details.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
REPO_BUILD_DIR="__REPO_BUILD_DIR__"
CONTAINER=oot-bc250-build
IMAGE=fedora:42
APP_DIR="$HOME/Applications/oot-bc250"
INSTALL_USER="${SUDO_USER:-$USER}"

WITH_SHORTCUT=0
GAME_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --with-shortcut) WITH_SHORTCUT=1 ;;
        --game) shift; [ $# -gt 0 ] || { echo "--game needs a path"; exit 1; }; GAME_PATH="$1" ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

log() { printf "\033[1;36m[oot-bc250]\033[0m %s\n" "$*"; }

if [ "$(id -u)" = 0 ]; then
    # Plain root ssh logins have no systemd user session: re-exec as the desktop user
    # so distrobox and Steam paths work.
    [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != root ] && exec sudo -u "$INSTALL_USER" "$0" "$@"
    echo "Run me as your desktop user, not as root." >&2
    exit 1
fi

if ! command -v distrobox >/dev/null; then
    echo "distrobox not found. On Bazzite it is preinstalled; on other distros:" >&2
    echo "  curl -s https://raw.githubusercontent.com/containers/distrobox/main/install | sh -s -- --prefix ~/.local" >&2
    exit 1
fi

# --- 1. Build container -------------------------------------------------------
if ! distrobox list 2>/dev/null | grep -q "$CONTAINER"; then
    log "creating the $CONTAINER distrobox (image $IMAGE)"
    distrobox create -n "$CONTAINER" -i "$IMAGE" -Y
else
    log "reusing the $CONTAINER distrobox"
fi

if ! distrobox enter "$CONTAINER" -- test -x /usr/bin/ninja; then
    log "installing build dependencies (about 500 MB in the container)"
    distrobox enter "$CONTAINER" -- sudo dnf -y install \
        git autoconf cmake fmt-devel gcc gcc-c++ clang glslang hidapi-devel json-devel \
        libtool libusb1-devel libzstd-devel lz4-devel nasm ninja-build openssl-devel \
        pulseaudio-libs-devel speexdsp-devel wayland-devel zlib-devel ffmpeg-free-devel \
        libXext-devel boost-devel SDL3-devel jq patch make spirv-tools >/dev/null
else
    log "dependencies already installed"
fi

# --- 2. Build ----------------------------------------------------------------
log "building eden-cli (Release, ~15-30 min on the BC-250; first build is the slow one)"
cd "$REPO_DIR"
if [ ! -f build/CMakeCache.txt ]; then
    distrobox enter "$CONTAINER" -- cmake -S "$REPO_DIR" -B "$REPO_DIR/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_QT=OFF -DYUZU_CMD=ON -DENABLE_WEB_SERVICE=OFF \
        -DYUZU_ROOM=OFF -DYUZU_TESTS=OFF -DENABLE_WERROR=OFF -DENABLE_UPDATE_CHECKER=OFF \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
fi
distrobox enter "$CONTAINER" -- cmake --build "$REPO_DIR/build" --target eden-cli --parallel 4
[ -x "$REPO_DIR/build/bin/eden-cli" ] || { echo "build failed: no eden-cli" >&2; exit 1; }
log "built $REPO_DIR/build/bin/eden-cli"

# --- 3. Wrapper and config ----------------------------------------------------
log "installing the launch wrapper to $APP_DIR"
mkdir -p "$APP_DIR"

cat > "$APP_DIR/oot-bc250" <<'WRAP'
#!/usr/bin/env bash
# oot-bc250 launcher: tunes the emulator for the BC-250 iGPU, then runs eden-cli.
# Usage: oot-bc250 [-f] -g "<path to your Ocarina of Time dump>"
set -euo pipefail
CONTAINER=oot-bc250-build
unset LD_PRELOAD
# The BC-250 iGPU (RADV) with UMA: cap the texture cache so it never tramples
# the 15 GB of system RAM the game and the compositor also live in.
export EDEN_NX2_TC_EXPECTED_MIB=4096
export EDEN_NX2_TC_CRITICAL_MIB=4608
# Present every second vblank; the game itself asks for 30 fps.
export EDEN_NX2_SPLIT=2          # split GPU thread: the back half runs on its own thread
export EDEN_NX2_FENCE_BATCH=1   # batch GPU fence syncpoints
export EDEN_NX2_PRELOAD_ALL_PIPELINES=1  # build cached pipelines at boot, not on first sight
exec distrobox enter "$CONTAINER" -- "$REPO_BUILD_DIR/bin/eden-cli" "$@"
WRAP
sed -i "s|__REPO_BUILD_DIR__|$REPO_DIR/build|" "$APP_DIR/oot-bc250"
chmod +x "$APP_DIR/oot-bc250"

if [ ! -f "$APP_DIR/oot.ini" ]; then
    log "writing the per-game config template ($APP_DIR/oot.ini)"
    cat > "$APP_DIR/oot.ini" <<'INI'
[DisabledAddOns]
size=1
1\title_id\default=false
1\title_id=288309953924349952
1\disabled\size=1
1\disabled\1\d=Max Resolution (built-in)
1\disabled\1\d\default=false

[Renderer]
gpu_accuracy\default=false
gpu_accuracy=0
use_asynchronous_shaders\default=false
use_asynchronous_shaders=true
async_presentation\default=false
async_presentation=true
frame_gen_type\default=false
frame_gen_type=1
frame_gen\default=false
frame_gen=true
frame_gen_multiplier\default=false
frame_gen_multiplier=2
frame_gen_flow_scale\default=false
frame_gen_flow_scale=50
frame_gen_target_rate\default=false
frame_gen_target_rate=30
scaling_filter\default=false
scaling_filter=6
fsr_sharpening_slider\default=false
fsr_sharpening_slider=60

[System]
memory_layout_mode\default=false
memory_layout_mode=2
use_docked_mode\default=false
use_docked_mode=0
INI
else
    log "keeping the existing $APP_DIR/oot.ini"
fi

cat <<'DONE'

\033[1mInstalled.\033[0m Launch the game with:

  $APP_DIR/oot-bc250 -f -g "<path to your Ocarina of Time dump>"

Run the wrapper with  -c "$APP_DIR/oot.ini"  for the tuned per-game settings
(every \default flag matters: without them the loader ignores your values).

\033[1mFirst launch:\033[0m the screen stays black for 3-5 minutes while the
shader pipelines are prepared. This is normal, happens once per game version
per emulator build, and shrinks on later boots as the cache fills.

Keys and firmware go where upstream expects them (~/.local/share/eden/keys,
nand/system/Contents/registered); you must dump them from your own console.
DONE

# --- 4. Steam shortcut (optional) --------------------------------------------
if [ "$WITH_SHORTCUT" = 1 ]; then
    if [ -z "$GAME_PATH" ]; then
        log "shortcut needs the game: add --game \"<path to your dump>\""
        exit 0
    fi
    [ -f "$GAME_PATH" ] || { echo "no such game file: $GAME_PATH" >&2; exit 1; }
    if pgrep -x steam >/dev/null; then
        cat >&2 <<'MSG'
Steam is running. The shortcut file can only be edited while Steam is stopped
(Steam rewrites it from memory otherwise). Close Steam/Gaming Mode, then rerun
the installer with the same --with-shortcut --game options.
MSG
        exit 1
    fi
    VDF=$(ls -1 "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf 2>/dev/null | head -1)
    [ -n "$VDF" ] || { echo "no shortcuts.vdf found (run Steam once first)" >&2; exit 1; }
    log "adding the Steam shortcut to $(basename "$(dirname "$(dirname "$VDF")")")"
    python3 "$REPO_DIR/tools/bc250/add_steam_shortcut.py" \
        --vdf "$VDF" --name "Zelda Ocarina of Time" \
        --exe "$APP_DIR/oot-bc250" \
        --launch-options "-f -c \"$APP_DIR/oot.ini\" -g \"$(realpath "$GAME_PATH")\""
    log "shortcut added; start Steam and it will be in your library under Non-Steam"
fi
