#!/bin/bash
# lichii-bc250 installer for the AMD BC-250 console (CachyOS).
#
# Usage:  ./tools/bc250/bc250-install.sh [--pgo] [--with-shortcut] [--game <path>]
#
#   --pgo            build with the bundled Lichii profile (~10% more fps) using the system LLVM
#                    (clang 22+); with an older one, downloads LLVM 23 (~2 GB, keeps ~600 MB)
#   --with-shortcut  add a Steam non-Steam shortcut (needs --game and Steam stopped)
#   --game <path>    your own Ocarina of Time dump, for the shortcut
#
# What it does:
#   1. Installs the build dependencies on the host with pacman (asks for sudo once), and a
#      udev rule so Steam Input can read Xbox One S-style Bluetooth pads' sticks.
#   2. Builds the eden-cli binary from this checkout (Release, clang, no Qt; PGO with --pgo).
#   3. Installs the launch wrapper with the BC-250 tuning and the per-game config template.
#   4. Optionally registers a Steam non-Steam shortcut for your Ocarina of Time dump
#      (requires Steam to be stopped; the installer tells you when).
#
# The first launch of the game stays on a black screen for 3-5 minutes while it prepares
# the shader pipelines; later boots are much faster. See the README for details.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
APP_DIR="$HOME/Applications/lichii-bc250"
INSTALL_USER="${SUDO_USER:-$USER}"

WITH_SHORTCUT=0
WITH_PGO=0
LLVM_VERSION=23.1.5
LLVM_DIR="$HOME/.local/share/lichii-bc250/llvm23"
GAME_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --with-shortcut) WITH_SHORTCUT=1 ;;
        --pgo) WITH_PGO=1 ;;
        --game) shift; [ $# -gt 0 ] || { echo "--game needs a path"; exit 1; }; GAME_PATH="$1" ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

log() { printf "\033[1;36m[lichii-bc250]\033[0m %s\n" "$*"; }

if [ "$(id -u)" = 0 ]; then
    # Build and install as the desktop user so the build tree, ~/Applications and the
    # Steam paths belong to them; pacman is called through sudo below.
    [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != root ] && exec sudo -u "$INSTALL_USER" "$0" "$@"
    echo "Run me as your desktop user, not as root." >&2
    exit 1
fi

if ! command -v pacman >/dev/null; then
    echo "pacman not found: this installer targets CachyOS (or another Arch-based distro)." >&2
    exit 1
fi

# --- 1. Build dependencies ----------------------------------------------------
DEPS=(
    base-devel git curl autoconf cmake ninja pkgconf clang llvm lld nasm patch make jq
    fmt glslang spirv-tools hidapi nlohmann-json libtool libusb zstd lz4 openssl
    libpulse speexdsp wayland zlib ffmpeg libxext boost sdl3
)
# pacman -T prints the entries that are not satisfied (and nothing when all are).
MISSING=$(pacman -T "${DEPS[@]}" || true)
if [ -n "$MISSING" ]; then
    log "installing build dependencies: $(echo $MISSING)"
    # shellcheck disable=SC2086
    sudo pacman -S --needed --noconfirm $MISSING
else
    log "dependencies already installed"
fi

# --- 1b. Controller access for Steam Input -----------------------------------
# Steam's own udev rules (steam-devices) give the desktop user the hidraw node of most
# Bluetooth pads, but not the Xbox One S over Bluetooth (045E:02E0), which 8BitDo adapters
# and pads in X-input mode also report. Without it Steam falls back to evdev for that pad
# and passes its buttons to the game but none of its stick movement.
UDEV_RULE=/etc/udev/rules.d/61-xbox-one-s-bt-hidraw.rules
UDEV_LINE='KERNEL=="hidraw*", KERNELS=="*045E:02E0*", MODE="0660", TAG+="uaccess"'
if [ "$(cat "$UDEV_RULE" 2>/dev/null)" != "$UDEV_LINE" ]; then
    log "adding the Xbox One S Bluetooth hidraw rule for Steam Input ($UDEV_RULE)"
    echo "$UDEV_LINE" | sudo tee "$UDEV_RULE" >/dev/null
    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=hidraw
else
    log "controller udev rule already present"
fi

# --- 2. Build ----------------------------------------------------------------
cd "$REPO_DIR"
CMAKE_ARGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DENABLE_QT=OFF -DYUZU_CMD=ON
            -DENABLE_WEB_SERVICE=OFF -DYUZU_ROOM=OFF -DYUZU_TESTS=OFF -DBUILD_TESTING=OFF
            -DENABLE_WERROR=OFF -DENABLE_UPDATE_CHECKER=OFF)
if [ "$WITH_PGO" = 1 ]; then
    BUILD_DIR="$REPO_DIR/build-pgo"
    PROFILE="$REPO_DIR/lichii-linux.profdata"
    [ -f "$PROFILE" ] || { echo "missing $PROFILE (the PGO profile ships with the repo)" >&2; exit 1; }
    # The profile is indexed format 14, which clang 22 and newer read. CachyOS ships a recent
    # LLVM; use it when it is new enough and has the linker and archiver, else download LLVM.
    SYS_CLANG_MAJOR=$(clang -dumpversion 2>/dev/null | cut -d. -f1)
    if [ "${SYS_CLANG_MAJOR:-0}" -ge 22 ] && command -v ld.lld llvm-ar llvm-ranlib >/dev/null; then
        LLVM_BIN="$(dirname "$(command -v clang)")"
        log "PGO with the system LLVM (clang $(clang -dumpversion))"
    elif [ ! -x "$LLVM_DIR/bin/clang" ]; then
        LLVM_BIN="$LLVM_DIR/bin"
        # Only the compiler, linker, archiver and clang's own headers are kept (~600 MB of the
        # 12 GB release).
        log "downloading LLVM $LLVM_VERSION (~2 GB, streamed; keeps ~600 MB)"
        mkdir -p "$LLVM_DIR"
        curl -fL "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VERSION/LLVM-$LLVM_VERSION-Linux-X64.tar.xz" |
            tar -xJ -C "$LLVM_DIR" --strip-components=1 --wildcards \
                "*/bin/clang" "*/bin/clang++" "*/bin/clang-[0-9]*" "*/bin/lld" "*/bin/ld.lld" \
                "*/bin/llvm-ar" "*/bin/llvm-ranlib" "*/lib/clang/*"
        [ -x "$LLVM_DIR/bin/clang" ] || { echo "LLVM download failed" >&2; exit 1; }
    else
        LLVM_BIN="$LLVM_DIR/bin"
    fi
    PGO_FLAGS="-fprofile-use=$PROFILE -Wno-backend-plugin -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date"
    CMAKE_ARGS+=(-DCMAKE_C_COMPILER="$LLVM_BIN/clang" -DCMAKE_CXX_COMPILER="$LLVM_BIN/clang++"
                 -DCMAKE_AR="$LLVM_BIN/llvm-ar" -DCMAKE_RANLIB="$LLVM_BIN/llvm-ranlib"
                 -DCMAKE_C_FLAGS="$PGO_FLAGS" -DCMAKE_CXX_FLAGS="$PGO_FLAGS"
                 -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld -DENABLE_LTO=OFF)
else
    BUILD_DIR="$REPO_DIR/build"
    CMAKE_ARGS+=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)
fi
# A build tree configured inside the old Fedora distrobox points at that container's
# libraries; move it aside so this host configures afresh.
if [ -f "$BUILD_DIR/CMakeCache.txt" ] && [ ! -f "$BUILD_DIR/.lichii-native" ]; then
    OLD="$BUILD_DIR.distrobox-$(date +%Y%m%d%H%M%S)"
    log "moving the old container-built tree aside to $OLD (delete it when you like)"
    mv "$BUILD_DIR" "$OLD"
fi
log "building eden-cli in $BUILD_DIR (Release, ~30-60 min on the BC-250; first build is the slow one)"
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    cmake -S "$REPO_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
    touch "$BUILD_DIR/.lichii-native"
else
    # Re-run configure so the version string matches the checkout (it is only set there).
    cmake "$BUILD_DIR" >/dev/null
fi
# 4 jobs: more can run the 16 GB box out of memory on the largest files.
cmake --build "$BUILD_DIR" --target eden-cli --parallel 4
[ -x "$BUILD_DIR/bin/eden-cli" ] || { echo "build failed: no eden-cli" >&2; exit 1; }
log "built $BUILD_DIR/bin/eden-cli"

# --- 3. Wrapper and config ----------------------------------------------------
log "installing the launch wrapper to $APP_DIR"
mkdir -p "$APP_DIR"

cat > "$APP_DIR/lichii-bc250" <<'WRAP'
#!/usr/bin/env bash
# lichii-bc250 launcher: tunes the emulator for the BC-250 iGPU, then runs eden-cli.
# Usage: lichii-bc250 [-f] -g "<path to your game dump>"
set -euo pipefail
unset LD_PRELOAD
# The BC-250 iGPU (RADV) with UMA: cap the texture cache so it never tramples
# the 15 GB of system RAM the game and the compositor also live in. 1.5/2 GB (v6) left
# ~2 GB more RAM free in play than 3/3.5 GB, with fewer swap stalls and no texture reloads.
export EDEN_NX2_TC_EXPECTED_MIB=1536
export EDEN_NX2_TC_CRITICAL_MIB=2048
export EDEN_NX2_VSYNC_HZ=30       # the game starts its frames on a 30 Hz tick
export EDEN_NX2_SWAP_INTERVAL=2   # present every second vblank; the game asks for 30 fps
export EDEN_VI2_MAX_RESOLUTION_MODE=1  # report the handheld display mode
export EDEN_NX2_SPLIT=2          # split GPU thread: the back half runs on its own thread
export EDEN_NX2_FENCE_BATCH=1    # batch GPU fence syncpoints
export EDEN_NX2_FRAMES_AHEAD=2   # the game runs a frame ahead of the GPU threads: 13.6 -> 21.3 fps
export EDEN_NX2_PRELOAD_ALL_PIPELINES=0  # cached pipelines build on first sight (boots faster)
# Compile new shaders on 4 workers and 2 driver threads, and give back each worker's memory
# after large shaders: on a first visit to Hyrule Field the default (all threads) took 3.7 GB at
# once and froze the game for up to 13 s while the box swapped.
export EDEN_NX2_PIPELINE_WORKERS=4 EDEN_NX2_PIPELINE_DRIVER_THREADS=2 EDEN_NX2_IR_POOL_CAP_MIB=64
# The BC-250 has no mesh hardware, but some Mesa builds (e.g. the BC-250 toolkit's 26.2.6)
# advertise VK_EXT_mesh_shader anyway; native task/mesh draws then render white. Keep the
# emulator's own compute fallback, which is what stock Mesa uses.
export EDEN_NX2_FORCE_MESH_FALLBACK=1
exec "__REPO_BUILD_DIR__/bin/eden-cli" "$@"
WRAP
sed -i "s|__REPO_BUILD_DIR__|$BUILD_DIR|" "$APP_DIR/lichii-bc250"
chmod +x "$APP_DIR/lichii-bc250"

if [ ! -f "$APP_DIR/oot.ini" ]; then
    log "writing the per-game config template ($APP_DIR/oot.ini)"
    cat > "$APP_DIR/oot.ini" <<'INI'
[DisabledAddOns]
size=1
1\title_id\default=false
1\title_id=288309953924349952
1\disabled\size=0

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
frame_gen_target_rate=0
frame_gen_queue_target\default=false
frame_gen_queue_target=1
pin_gpu_threads\default=false
pin_gpu_threads=true
scaling_filter\default=false
scaling_filter=6
fsr_sharpening_slider\default=false
fsr_sharpening_slider=60

[System]
memory_layout_mode\default=false
memory_layout_mode=2
use_docked_mode\default=false
use_docked_mode=0
[Controls]
player_0_body_color_left=702950
player_0_body_color_left\default=true
player_0_body_color_right=16727080
player_0_body_color_right\default=true
player_0_button_a="engine:sdl,button:1,guid:03000000de280000ff11000001000000,port:0"
player_0_button_a\default=false
player_0_button_b="engine:sdl,button:0,guid:03000000de280000ff11000001000000,port:0"
player_0_button_b\default=false
player_0_button_color_left=7710
player_0_button_color_left\default=true
player_0_button_color_right=1968650
player_0_button_color_right\default=true
player_0_button_ddown="engine:sdl,hat:0,direction:down,guid:03000000de280000ff11000001000000,port:0"
player_0_button_ddown\default=false
player_0_button_dleft="engine:sdl,hat:0,direction:left,guid:03000000de280000ff11000001000000,port:0"
player_0_button_dleft\default=false
player_0_button_dright="engine:sdl,hat:0,direction:right,guid:03000000de280000ff11000001000000,port:0"
player_0_button_dright\default=false
player_0_button_dup="engine:sdl,hat:0,direction:up,guid:03000000de280000ff11000001000000,port:0"
player_0_button_dup\default=false
player_0_button_home="engine:sdl,button:8,guid:03000000de280000ff11000001000000,port:0"
player_0_button_home\default=false
player_0_button_l="engine:sdl,button:4,guid:03000000de280000ff11000001000000,port:0"
player_0_button_l\default=false
player_0_button_lstick="engine:sdl,button:9,guid:03000000de280000ff11000001000000,port:0"
player_0_button_lstick\default=false
player_0_button_minus="engine:sdl,button:6,guid:03000000de280000ff11000001000000,port:0"
player_0_button_minus\default=false
player_0_button_plus="engine:sdl,button:7,guid:03000000de280000ff11000001000000,port:0"
player_0_button_plus\default=false
player_0_button_r="engine:sdl,button:5,guid:03000000de280000ff11000001000000,port:0"
player_0_button_r\default=false
player_0_button_rstick="engine:sdl,button:10,guid:03000000de280000ff11000001000000,port:0"
player_0_button_rstick\default=false
player_0_button_screenshot="engine:keyboard,code:0,toggle:0"
player_0_button_screenshot\default=false
player_0_button_slleft="engine:sdl,button:4,guid:03000000de280000ff11000001000000,port:0"
player_0_button_slleft\default=false
player_0_button_slright="engine:sdl,button:4,guid:03000000de280000ff11000001000000,port:0"
player_0_button_slright\default=false
player_0_button_srleft="engine:sdl,button:5,guid:03000000de280000ff11000001000000,port:0"
player_0_button_srleft\default=false
player_0_button_srright="engine:sdl,button:5,guid:03000000de280000ff11000001000000,port:0"
player_0_button_srright\default=false
player_0_button_x="engine:sdl,button:3,guid:03000000de280000ff11000001000000,port:0"
player_0_button_x\default=false
player_0_button_y="engine:sdl,button:2,guid:03000000de280000ff11000001000000,port:0"
player_0_button_y\default=false
player_0_button_zl="engine:sdl,axis:2,guid:03000000de280000ff11000001000000,invert:+,port:0,threshold:0.500000"
player_0_button_zl\default=false
player_0_button_zr="engine:sdl,axis:5,guid:03000000de280000ff11000001000000,invert:+,port:0,threshold:0.500000"
player_0_button_zr\default=false
player_0_connected=true
player_0_connected\default=true
player_0_lstick="engine:sdl,axis_x:0,axis_y:1,deadzone:0.150000,guid:03000000de280000ff11000001000000,invert_x:+,invert_y:+,offset_x:0.000000,offset_y:0.000000,port:0,range:0.950000"
player_0_lstick\default=false
player_0_motionleft="engine:keyboard,code:55,toggle:0"
player_0_motionleft\default=false
player_0_motionright="engine:keyboard,code:56,toggle:0"
player_0_motionright\default=false
player_0_profile_name=
player_0_profile_name\default=true
player_0_rstick="engine:sdl,axis_x:3,axis_y:4,deadzone:0.150000,guid:03000000de280000ff11000001000000,invert_x:+,invert_y:+,offset_x:0.000000,offset_y:0.000000,port:0,range:0.950000"
player_0_rstick\default=false
player_0_type=0
player_0_type\default=true
player_0_vibration_enabled=true
player_0_vibration_enabled\default=true
player_0_vibration_strength=100
player_0_vibration_strength\default=true
touch_from_button_maps\size=1
controller_navigation\default=true
controller_navigation=true
enable_joycon_driver\default=true
enable_joycon_driver=true
enable_procon_driver\default=true
enable_procon_driver=false
vibration_enabled\default=true
vibration_enabled=true
enable_accurate_vibrations\default=true
enable_accurate_vibrations=false
motion_enabled\default=true
motion_enabled=true
udp_input_servers\default=true
udp_input_servers=127.0.0.1:26760
enable_udp_controller\default=true
enable_udp_controller=false
pause_tas_on_load\default=true
pause_tas_on_load=true
tas_enable\default=true
tas_enable=false
tas_loop\default=true
tas_loop=false
tas_show_recording_dialog\default=true
tas_show_recording_dialog=true
mouse_panning_sensitivity\default=true
mouse_panning_sensitivity=50
mouse_enabled\default=true
mouse_enabled=false
mouse_panning_x_sensitivity\default=true
mouse_panning_x_sensitivity=50
mouse_panning_y_sensitivity\default=true
mouse_panning_y_sensitivity=50
mouse_panning_deadzone_counterweight\default=true
mouse_panning_deadzone_counterweight=20
mouse_panning_decay_strength\default=true
mouse_panning_decay_strength=18
mouse_panning_min_decay\default=true
mouse_panning_min_decay=6
emulate_analog_keyboard\default=true
emulate_analog_keyboard=false
keyboard_enabled\default=true
keyboard_enabled=false
debug_pad_enabled\default=true
debug_pad_enabled=false
touch_device\default=true
touch_device="min_x:100,min_y:50,max_x:1800,max_y:850"
touch_from_button_map\default=true
touch_from_button_map=0
enable_ring_controller\default=true
enable_ring_controller=true
enable_ir_sensor\default=true
enable_ir_sensor=false
ir_sensor_device\default=true
ir_sensor_device=auto
random_amiibo_id\default=true
random_amiibo_id=false
player_1_type\default=true
player_1_type=0
player_1_profile_name\default=true
player_1_profile_name=
player_1_connected\default=true
player_1_connected=false
player_1_vibration_enabled\default=true
player_1_vibration_enabled=true
player_1_vibration_strength\default=true
player_1_vibration_strength=100
player_1_body_color_left\default=true
player_1_body_color_left=702950
player_1_body_color_right\default=true
player_1_body_color_right=16727080
player_1_button_color_left\default=true
player_1_button_color_left=7710
player_1_button_color_right\default=true
player_1_button_color_right=1968650
player_2_type\default=true
player_2_type=0
player_2_profile_name\default=true
player_2_profile_name=
player_2_connected\default=true
player_2_connected=false
player_2_vibration_enabled\default=true
player_2_vibration_enabled=true
player_2_vibration_strength\default=true
player_2_vibration_strength=100
player_2_body_color_left\default=true
player_2_body_color_left=702950
player_2_body_color_right\default=true
player_2_body_color_right=16727080
player_2_button_color_left\default=true
player_2_button_color_left=7710
player_2_button_color_right\default=true
player_2_button_color_right=1968650
player_3_type\default=true
player_3_type=0
player_3_profile_name\default=true
player_3_profile_name=
player_3_connected\default=true
player_3_connected=false
player_3_vibration_enabled\default=true
player_3_vibration_enabled=true
player_3_vibration_strength\default=true
player_3_vibration_strength=100
player_3_body_color_left\default=true
player_3_body_color_left=702950
player_3_body_color_right\default=true
player_3_body_color_right=16727080
player_3_button_color_left\default=true
player_3_button_color_left=7710
player_3_button_color_right\default=true
player_3_button_color_right=1968650
player_4_type\default=true
player_4_type=0
player_4_profile_name\default=true
player_4_profile_name=
player_4_connected\default=true
player_4_connected=false
player_4_vibration_enabled\default=true
player_4_vibration_enabled=true
player_4_vibration_strength\default=true
player_4_vibration_strength=100
player_4_body_color_left\default=true
player_4_body_color_left=702950
player_4_body_color_right\default=true
player_4_body_color_right=16727080
player_4_button_color_left\default=true
player_4_button_color_left=7710
player_4_button_color_right\default=true
player_4_button_color_right=1968650
player_5_type\default=true
player_5_type=0
player_5_profile_name\default=true
player_5_profile_name=
player_5_connected\default=true
player_5_connected=false
player_5_vibration_enabled\default=true
player_5_vibration_enabled=true
player_5_vibration_strength\default=true
player_5_vibration_strength=100
player_5_body_color_left\default=true
player_5_body_color_left=702950
player_5_body_color_right\default=true
player_5_body_color_right=16727080
player_5_button_color_left\default=true
player_5_button_color_left=7710
player_5_button_color_right\default=true
player_5_button_color_right=1968650
player_6_type\default=true
player_6_type=0
player_6_profile_name\default=true
player_6_profile_name=
player_6_connected\default=true
player_6_connected=false
player_6_vibration_enabled\default=true
player_6_vibration_enabled=true
player_6_vibration_strength\default=true
player_6_vibration_strength=100
player_6_body_color_left\default=true
player_6_body_color_left=702950
player_6_body_color_right\default=true
player_6_body_color_right=16727080
player_6_button_color_left\default=true
player_6_button_color_left=7710
player_6_button_color_right\default=true
player_6_button_color_right=1968650
player_7_type\default=true
player_7_type=0
player_7_profile_name\default=true
player_7_profile_name=
player_7_connected\default=true
player_7_connected=false
player_7_vibration_enabled\default=true
player_7_vibration_enabled=true
player_7_vibration_strength\default=true
player_7_vibration_strength=100
player_7_body_color_left\default=true
player_7_body_color_left=702950
player_7_body_color_right\default=true
player_7_body_color_right=16727080
player_7_button_color_left\default=true
player_7_button_color_left=7710
player_7_button_color_right\default=true
player_7_button_color_right=1968650
player_8_type\default=true
player_8_type=0
player_8_profile_name\default=true
player_8_profile_name=
player_8_connected\default=true
player_8_connected=false
player_8_vibration_enabled\default=true
player_8_vibration_enabled=true
player_8_vibration_strength\default=true
player_8_vibration_strength=100
player_8_body_color_left\default=true
player_8_body_color_left=702950
player_8_body_color_right\default=true
player_8_body_color_right=16727080
player_8_button_color_left\default=true
player_8_button_color_left=7710
player_8_button_color_right\default=true
player_8_button_color_right=1968650
player_9_type\default=true
player_9_type=0
player_9_profile_name\default=true
player_9_profile_name=
player_9_connected\default=true
player_9_connected=false
player_9_vibration_enabled\default=true
player_9_vibration_enabled=true
player_9_vibration_strength\default=true
player_9_vibration_strength=100
player_9_body_color_left\default=true
player_9_body_color_left=702950
player_9_body_color_right\default=true
player_9_body_color_right=16727080
player_9_button_color_left\default=true
player_9_button_color_left=7710
player_9_button_color_right\default=true
player_9_button_color_right=1968650
touchscreen_enabled\default=true
touchscreen_enabled=true
touchscreen_angle\default=true
touchscreen_angle=0
touchscreen_diameter_x\default=true
touchscreen_diameter_x=90
touchscreen_diameter_y\default=true
touchscreen_diameter_y=90
touch_from_button_maps\1\name\default=false
touch_from_button_maps\1\name=default
touch_from_button_maps\1\entries\size=0
player_1_button_a\default=false
player_1_button_a="engine:keyboard,code:4,toggle:0"
player_1_button_b\default=false
player_1_button_b="engine:keyboard,code:22,toggle:0"
player_1_button_x\default=false
player_1_button_x="engine:keyboard,code:29,toggle:0"
player_1_button_y\default=false
player_1_button_y="engine:keyboard,code:27,toggle:0"
player_1_button_lstick\default=false
player_1_button_lstick="engine:keyboard,code:23,toggle:0"
player_1_button_rstick\default=false
player_1_button_rstick="engine:keyboard,code:10,toggle:0"
player_1_button_l\default=false
player_1_button_l="engine:keyboard,code:9,toggle:0"
player_1_button_r\default=false
player_1_button_r="engine:keyboard,code:11,toggle:0"
player_1_button_zl\default=false
player_1_button_zl="engine:keyboard,code:20,toggle:0"
player_1_button_zr\default=false
player_1_button_zr="engine:keyboard,code:26,toggle:0"
player_1_button_plus\default=false
player_1_button_plus="engine:keyboard,code:16,toggle:0"
player_1_button_minus\default=false
player_1_button_minus="engine:keyboard,code:17,toggle:0"
player_1_button_dleft\default=false
player_1_button_dleft="engine:keyboard,code:30,toggle:0"
player_1_button_dup\default=false
player_1_button_dup="engine:keyboard,code:31,toggle:0"
player_1_button_dright\default=false
player_1_button_dright="engine:keyboard,code:5,toggle:0"
player_1_button_ddown\default=false
player_1_button_ddown="engine:keyboard,code:0,toggle:0"
player_1_button_slleft\default=false
player_1_button_slleft="engine:keyboard,code:0,toggle:0"
player_1_button_srleft\default=false
player_1_button_srleft="engine:keyboard,code:0,toggle:0"
player_1_button_home\default=false
player_1_button_home="engine:keyboard,code:0,toggle:0"
player_1_button_screenshot\default=false
player_1_button_screenshot="engine:keyboard,code:0,toggle:0"
player_1_button_slright\default=false
player_1_button_slright="engine:keyboard,code:0,toggle:0"
player_1_button_srright\default=false
player_1_button_srright="engine:keyboard,code:0,toggle:0"
player_1_lstick\default=false
player_1_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_1_rstick\default=false
player_1_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_1_motionleft\default=false
player_1_motionleft="engine:keyboard,code:36,toggle:0"
player_1_motionright\default=false
player_1_motionright="engine:keyboard,code:37,toggle:0"
player_2_button_a\default=false
player_2_button_a="engine:keyboard,code:4,toggle:0"
player_2_button_b\default=false
player_2_button_b="engine:keyboard,code:22,toggle:0"
player_2_button_x\default=false
player_2_button_x="engine:keyboard,code:29,toggle:0"
player_2_button_y\default=false
player_2_button_y="engine:keyboard,code:27,toggle:0"
player_2_button_lstick\default=false
player_2_button_lstick="engine:keyboard,code:23,toggle:0"
player_2_button_rstick\default=false
player_2_button_rstick="engine:keyboard,code:10,toggle:0"
player_2_button_l\default=false
player_2_button_l="engine:keyboard,code:9,toggle:0"
player_2_button_r\default=false
player_2_button_r="engine:keyboard,code:11,toggle:0"
player_2_button_zl\default=false
player_2_button_zl="engine:keyboard,code:20,toggle:0"
player_2_button_zr\default=false
player_2_button_zr="engine:keyboard,code:26,toggle:0"
player_2_button_plus\default=false
player_2_button_plus="engine:keyboard,code:16,toggle:0"
player_2_button_minus\default=false
player_2_button_minus="engine:keyboard,code:17,toggle:0"
player_2_button_dleft\default=false
player_2_button_dleft="engine:keyboard,code:30,toggle:0"
player_2_button_dup\default=false
player_2_button_dup="engine:keyboard,code:31,toggle:0"
player_2_button_dright\default=false
player_2_button_dright="engine:keyboard,code:5,toggle:0"
player_2_button_ddown\default=false
player_2_button_ddown="engine:keyboard,code:0,toggle:0"
player_2_button_slleft\default=false
player_2_button_slleft="engine:keyboard,code:0,toggle:0"
player_2_button_srleft\default=false
player_2_button_srleft="engine:keyboard,code:0,toggle:0"
player_2_button_home\default=false
player_2_button_home="engine:keyboard,code:0,toggle:0"
player_2_button_screenshot\default=false
player_2_button_screenshot="engine:keyboard,code:0,toggle:0"
player_2_button_slright\default=false
player_2_button_slright="engine:keyboard,code:0,toggle:0"
player_2_button_srright\default=false
player_2_button_srright="engine:keyboard,code:0,toggle:0"
player_2_lstick\default=false
player_2_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_2_rstick\default=false
player_2_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_2_motionleft\default=false
player_2_motionleft="engine:keyboard,code:36,toggle:0"
player_2_motionright\default=false
player_2_motionright="engine:keyboard,code:37,toggle:0"
player_3_button_a\default=false
player_3_button_a="engine:keyboard,code:4,toggle:0"
player_3_button_b\default=false
player_3_button_b="engine:keyboard,code:22,toggle:0"
player_3_button_x\default=false
player_3_button_x="engine:keyboard,code:29,toggle:0"
player_3_button_y\default=false
player_3_button_y="engine:keyboard,code:27,toggle:0"
player_3_button_lstick\default=false
player_3_button_lstick="engine:keyboard,code:23,toggle:0"
player_3_button_rstick\default=false
player_3_button_rstick="engine:keyboard,code:10,toggle:0"
player_3_button_l\default=false
player_3_button_l="engine:keyboard,code:9,toggle:0"
player_3_button_r\default=false
player_3_button_r="engine:keyboard,code:11,toggle:0"
player_3_button_zl\default=false
player_3_button_zl="engine:keyboard,code:20,toggle:0"
player_3_button_zr\default=false
player_3_button_zr="engine:keyboard,code:26,toggle:0"
player_3_button_plus\default=false
player_3_button_plus="engine:keyboard,code:16,toggle:0"
player_3_button_minus\default=false
player_3_button_minus="engine:keyboard,code:17,toggle:0"
player_3_button_dleft\default=false
player_3_button_dleft="engine:keyboard,code:30,toggle:0"
player_3_button_dup\default=false
player_3_button_dup="engine:keyboard,code:31,toggle:0"
player_3_button_dright\default=false
player_3_button_dright="engine:keyboard,code:5,toggle:0"
player_3_button_ddown\default=false
player_3_button_ddown="engine:keyboard,code:0,toggle:0"
player_3_button_slleft\default=false
player_3_button_slleft="engine:keyboard,code:0,toggle:0"
player_3_button_srleft\default=false
player_3_button_srleft="engine:keyboard,code:0,toggle:0"
player_3_button_home\default=false
player_3_button_home="engine:keyboard,code:0,toggle:0"
player_3_button_screenshot\default=false
player_3_button_screenshot="engine:keyboard,code:0,toggle:0"
player_3_button_slright\default=false
player_3_button_slright="engine:keyboard,code:0,toggle:0"
player_3_button_srright\default=false
player_3_button_srright="engine:keyboard,code:0,toggle:0"
player_3_lstick\default=false
player_3_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_3_rstick\default=false
player_3_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_3_motionleft\default=false
player_3_motionleft="engine:keyboard,code:36,toggle:0"
player_3_motionright\default=false
player_3_motionright="engine:keyboard,code:37,toggle:0"
player_4_button_a\default=false
player_4_button_a="engine:keyboard,code:4,toggle:0"
player_4_button_b\default=false
player_4_button_b="engine:keyboard,code:22,toggle:0"
player_4_button_x\default=false
player_4_button_x="engine:keyboard,code:29,toggle:0"
player_4_button_y\default=false
player_4_button_y="engine:keyboard,code:27,toggle:0"
player_4_button_lstick\default=false
player_4_button_lstick="engine:keyboard,code:23,toggle:0"
player_4_button_rstick\default=false
player_4_button_rstick="engine:keyboard,code:10,toggle:0"
player_4_button_l\default=false
player_4_button_l="engine:keyboard,code:9,toggle:0"
player_4_button_r\default=false
player_4_button_r="engine:keyboard,code:11,toggle:0"
player_4_button_zl\default=false
player_4_button_zl="engine:keyboard,code:20,toggle:0"
player_4_button_zr\default=false
player_4_button_zr="engine:keyboard,code:26,toggle:0"
player_4_button_plus\default=false
player_4_button_plus="engine:keyboard,code:16,toggle:0"
player_4_button_minus\default=false
player_4_button_minus="engine:keyboard,code:17,toggle:0"
player_4_button_dleft\default=false
player_4_button_dleft="engine:keyboard,code:30,toggle:0"
player_4_button_dup\default=false
player_4_button_dup="engine:keyboard,code:31,toggle:0"
player_4_button_dright\default=false
player_4_button_dright="engine:keyboard,code:5,toggle:0"
player_4_button_ddown\default=false
player_4_button_ddown="engine:keyboard,code:0,toggle:0"
player_4_button_slleft\default=false
player_4_button_slleft="engine:keyboard,code:0,toggle:0"
player_4_button_srleft\default=false
player_4_button_srleft="engine:keyboard,code:0,toggle:0"
player_4_button_home\default=false
player_4_button_home="engine:keyboard,code:0,toggle:0"
player_4_button_screenshot\default=false
player_4_button_screenshot="engine:keyboard,code:0,toggle:0"
player_4_button_slright\default=false
player_4_button_slright="engine:keyboard,code:0,toggle:0"
player_4_button_srright\default=false
player_4_button_srright="engine:keyboard,code:0,toggle:0"
player_4_lstick\default=false
player_4_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_4_rstick\default=false
player_4_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_4_motionleft\default=false
player_4_motionleft="engine:keyboard,code:36,toggle:0"
player_4_motionright\default=false
player_4_motionright="engine:keyboard,code:37,toggle:0"
player_5_button_a\default=false
player_5_button_a="engine:keyboard,code:4,toggle:0"
player_5_button_b\default=false
player_5_button_b="engine:keyboard,code:22,toggle:0"
player_5_button_x\default=false
player_5_button_x="engine:keyboard,code:29,toggle:0"
player_5_button_y\default=false
player_5_button_y="engine:keyboard,code:27,toggle:0"
player_5_button_lstick\default=false
player_5_button_lstick="engine:keyboard,code:23,toggle:0"
player_5_button_rstick\default=false
player_5_button_rstick="engine:keyboard,code:10,toggle:0"
player_5_button_l\default=false
player_5_button_l="engine:keyboard,code:9,toggle:0"
player_5_button_r\default=false
player_5_button_r="engine:keyboard,code:11,toggle:0"
player_5_button_zl\default=false
player_5_button_zl="engine:keyboard,code:20,toggle:0"
player_5_button_zr\default=false
player_5_button_zr="engine:keyboard,code:26,toggle:0"
player_5_button_plus\default=false
player_5_button_plus="engine:keyboard,code:16,toggle:0"
player_5_button_minus\default=false
player_5_button_minus="engine:keyboard,code:17,toggle:0"
player_5_button_dleft\default=false
player_5_button_dleft="engine:keyboard,code:30,toggle:0"
player_5_button_dup\default=false
player_5_button_dup="engine:keyboard,code:31,toggle:0"
player_5_button_dright\default=false
player_5_button_dright="engine:keyboard,code:5,toggle:0"
player_5_button_ddown\default=false
player_5_button_ddown="engine:keyboard,code:0,toggle:0"
player_5_button_slleft\default=false
player_5_button_slleft="engine:keyboard,code:0,toggle:0"
player_5_button_srleft\default=false
player_5_button_srleft="engine:keyboard,code:0,toggle:0"
player_5_button_home\default=false
player_5_button_home="engine:keyboard,code:0,toggle:0"
player_5_button_screenshot\default=false
player_5_button_screenshot="engine:keyboard,code:0,toggle:0"
player_5_button_slright\default=false
player_5_button_slright="engine:keyboard,code:0,toggle:0"
player_5_button_srright\default=false
player_5_button_srright="engine:keyboard,code:0,toggle:0"
player_5_lstick\default=false
player_5_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_5_rstick\default=false
player_5_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_5_motionleft\default=false
player_5_motionleft="engine:keyboard,code:36,toggle:0"
player_5_motionright\default=false
player_5_motionright="engine:keyboard,code:37,toggle:0"
player_6_button_a\default=false
player_6_button_a="engine:keyboard,code:4,toggle:0"
player_6_button_b\default=false
player_6_button_b="engine:keyboard,code:22,toggle:0"
player_6_button_x\default=false
player_6_button_x="engine:keyboard,code:29,toggle:0"
player_6_button_y\default=false
player_6_button_y="engine:keyboard,code:27,toggle:0"
player_6_button_lstick\default=false
player_6_button_lstick="engine:keyboard,code:23,toggle:0"
player_6_button_rstick\default=false
player_6_button_rstick="engine:keyboard,code:10,toggle:0"
player_6_button_l\default=false
player_6_button_l="engine:keyboard,code:9,toggle:0"
player_6_button_r\default=false
player_6_button_r="engine:keyboard,code:11,toggle:0"
player_6_button_zl\default=false
player_6_button_zl="engine:keyboard,code:20,toggle:0"
player_6_button_zr\default=false
player_6_button_zr="engine:keyboard,code:26,toggle:0"
player_6_button_plus\default=false
player_6_button_plus="engine:keyboard,code:16,toggle:0"
player_6_button_minus\default=false
player_6_button_minus="engine:keyboard,code:17,toggle:0"
player_6_button_dleft\default=false
player_6_button_dleft="engine:keyboard,code:30,toggle:0"
player_6_button_dup\default=false
player_6_button_dup="engine:keyboard,code:31,toggle:0"
player_6_button_dright\default=false
player_6_button_dright="engine:keyboard,code:5,toggle:0"
player_6_button_ddown\default=false
player_6_button_ddown="engine:keyboard,code:0,toggle:0"
player_6_button_slleft\default=false
player_6_button_slleft="engine:keyboard,code:0,toggle:0"
player_6_button_srleft\default=false
player_6_button_srleft="engine:keyboard,code:0,toggle:0"
player_6_button_home\default=false
player_6_button_home="engine:keyboard,code:0,toggle:0"
player_6_button_screenshot\default=false
player_6_button_screenshot="engine:keyboard,code:0,toggle:0"
player_6_button_slright\default=false
player_6_button_slright="engine:keyboard,code:0,toggle:0"
player_6_button_srright\default=false
player_6_button_srright="engine:keyboard,code:0,toggle:0"
player_6_lstick\default=false
player_6_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_6_rstick\default=false
player_6_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_6_motionleft\default=false
player_6_motionleft="engine:keyboard,code:36,toggle:0"
player_6_motionright\default=false
player_6_motionright="engine:keyboard,code:37,toggle:0"
player_7_button_a\default=false
player_7_button_a="engine:keyboard,code:4,toggle:0"
player_7_button_b\default=false
player_7_button_b="engine:keyboard,code:22,toggle:0"
player_7_button_x\default=false
player_7_button_x="engine:keyboard,code:29,toggle:0"
player_7_button_y\default=false
player_7_button_y="engine:keyboard,code:27,toggle:0"
player_7_button_lstick\default=false
player_7_button_lstick="engine:keyboard,code:23,toggle:0"
player_7_button_rstick\default=false
player_7_button_rstick="engine:keyboard,code:10,toggle:0"
player_7_button_l\default=false
player_7_button_l="engine:keyboard,code:9,toggle:0"
player_7_button_r\default=false
player_7_button_r="engine:keyboard,code:11,toggle:0"
player_7_button_zl\default=false
player_7_button_zl="engine:keyboard,code:20,toggle:0"
player_7_button_zr\default=false
player_7_button_zr="engine:keyboard,code:26,toggle:0"
player_7_button_plus\default=false
player_7_button_plus="engine:keyboard,code:16,toggle:0"
player_7_button_minus\default=false
player_7_button_minus="engine:keyboard,code:17,toggle:0"
player_7_button_dleft\default=false
player_7_button_dleft="engine:keyboard,code:30,toggle:0"
player_7_button_dup\default=false
player_7_button_dup="engine:keyboard,code:31,toggle:0"
player_7_button_dright\default=false
player_7_button_dright="engine:keyboard,code:5,toggle:0"
player_7_button_ddown\default=false
player_7_button_ddown="engine:keyboard,code:0,toggle:0"
player_7_button_slleft\default=false
player_7_button_slleft="engine:keyboard,code:0,toggle:0"
player_7_button_srleft\default=false
player_7_button_srleft="engine:keyboard,code:0,toggle:0"
player_7_button_home\default=false
player_7_button_home="engine:keyboard,code:0,toggle:0"
player_7_button_screenshot\default=false
player_7_button_screenshot="engine:keyboard,code:0,toggle:0"
player_7_button_slright\default=false
player_7_button_slright="engine:keyboard,code:0,toggle:0"
player_7_button_srright\default=false
player_7_button_srright="engine:keyboard,code:0,toggle:0"
player_7_lstick\default=false
player_7_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_7_rstick\default=false
player_7_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_7_motionleft\default=false
player_7_motionleft="engine:keyboard,code:36,toggle:0"
player_7_motionright\default=false
player_7_motionright="engine:keyboard,code:37,toggle:0"
player_8_button_a\default=false
player_8_button_a="engine:keyboard,code:4,toggle:0"
player_8_button_b\default=false
player_8_button_b="engine:keyboard,code:22,toggle:0"
player_8_button_x\default=false
player_8_button_x="engine:keyboard,code:29,toggle:0"
player_8_button_y\default=false
player_8_button_y="engine:keyboard,code:27,toggle:0"
player_8_button_lstick\default=false
player_8_button_lstick="engine:keyboard,code:23,toggle:0"
player_8_button_rstick\default=false
player_8_button_rstick="engine:keyboard,code:10,toggle:0"
player_8_button_l\default=false
player_8_button_l="engine:keyboard,code:9,toggle:0"
player_8_button_r\default=false
player_8_button_r="engine:keyboard,code:11,toggle:0"
player_8_button_zl\default=false
player_8_button_zl="engine:keyboard,code:20,toggle:0"
player_8_button_zr\default=false
player_8_button_zr="engine:keyboard,code:26,toggle:0"
player_8_button_plus\default=false
player_8_button_plus="engine:keyboard,code:16,toggle:0"
player_8_button_minus\default=false
player_8_button_minus="engine:keyboard,code:17,toggle:0"
player_8_button_dleft\default=false
player_8_button_dleft="engine:keyboard,code:30,toggle:0"
player_8_button_dup\default=false
player_8_button_dup="engine:keyboard,code:31,toggle:0"
player_8_button_dright\default=false
player_8_button_dright="engine:keyboard,code:5,toggle:0"
player_8_button_ddown\default=false
player_8_button_ddown="engine:keyboard,code:0,toggle:0"
player_8_button_slleft\default=false
player_8_button_slleft="engine:keyboard,code:0,toggle:0"
player_8_button_srleft\default=false
player_8_button_srleft="engine:keyboard,code:0,toggle:0"
player_8_button_home\default=false
player_8_button_home="engine:keyboard,code:0,toggle:0"
player_8_button_screenshot\default=false
player_8_button_screenshot="engine:keyboard,code:0,toggle:0"
player_8_button_slright\default=false
player_8_button_slright="engine:keyboard,code:0,toggle:0"
player_8_button_srright\default=false
player_8_button_srright="engine:keyboard,code:0,toggle:0"
player_8_lstick\default=false
player_8_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_8_rstick\default=false
player_8_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_8_motionleft\default=false
player_8_motionleft="engine:keyboard,code:36,toggle:0"
player_8_motionright\default=false
player_8_motionright="engine:keyboard,code:37,toggle:0"
player_9_button_a\default=false
player_9_button_a="engine:keyboard,code:4,toggle:0"
player_9_button_b\default=false
player_9_button_b="engine:keyboard,code:22,toggle:0"
player_9_button_x\default=false
player_9_button_x="engine:keyboard,code:29,toggle:0"
player_9_button_y\default=false
player_9_button_y="engine:keyboard,code:27,toggle:0"
player_9_button_lstick\default=false
player_9_button_lstick="engine:keyboard,code:23,toggle:0"
player_9_button_rstick\default=false
player_9_button_rstick="engine:keyboard,code:10,toggle:0"
player_9_button_l\default=false
player_9_button_l="engine:keyboard,code:9,toggle:0"
player_9_button_r\default=false
player_9_button_r="engine:keyboard,code:11,toggle:0"
player_9_button_zl\default=false
player_9_button_zl="engine:keyboard,code:20,toggle:0"
player_9_button_zr\default=false
player_9_button_zr="engine:keyboard,code:26,toggle:0"
player_9_button_plus\default=false
player_9_button_plus="engine:keyboard,code:16,toggle:0"
player_9_button_minus\default=false
player_9_button_minus="engine:keyboard,code:17,toggle:0"
player_9_button_dleft\default=false
player_9_button_dleft="engine:keyboard,code:30,toggle:0"
player_9_button_dup\default=false
player_9_button_dup="engine:keyboard,code:31,toggle:0"
player_9_button_dright\default=false
player_9_button_dright="engine:keyboard,code:5,toggle:0"
player_9_button_ddown\default=false
player_9_button_ddown="engine:keyboard,code:0,toggle:0"
player_9_button_slleft\default=false
player_9_button_slleft="engine:keyboard,code:0,toggle:0"
player_9_button_srleft\default=false
player_9_button_srleft="engine:keyboard,code:0,toggle:0"
player_9_button_home\default=false
player_9_button_home="engine:keyboard,code:0,toggle:0"
player_9_button_screenshot\default=false
player_9_button_screenshot="engine:keyboard,code:0,toggle:0"
player_9_button_slright\default=false
player_9_button_slright="engine:keyboard,code:0,toggle:0"
player_9_button_srright\default=false
player_9_button_srright="engine:keyboard,code:0,toggle:0"
player_9_lstick\default=false
player_9_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
player_9_rstick\default=false
player_9_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
player_9_motionleft\default=false
player_9_motionleft="engine:keyboard,code:36,toggle:0"
player_9_motionright\default=false
player_9_motionright="engine:keyboard,code:37,toggle:0"
debug_pad_button_a\default=false
debug_pad_button_a="engine:keyboard,code:4,toggle:0"
debug_pad_button_b\default=false
debug_pad_button_b="engine:keyboard,code:22,toggle:0"
debug_pad_button_x\default=false
debug_pad_button_x="engine:keyboard,code:29,toggle:0"
debug_pad_button_y\default=false
debug_pad_button_y="engine:keyboard,code:27,toggle:0"
debug_pad_button_lstick\default=false
debug_pad_button_lstick="engine:keyboard,code:23,toggle:0"
debug_pad_button_rstick\default=false
debug_pad_button_rstick="engine:keyboard,code:10,toggle:0"
debug_pad_button_l\default=false
debug_pad_button_l="engine:keyboard,code:9,toggle:0"
debug_pad_button_r\default=false
debug_pad_button_r="engine:keyboard,code:11,toggle:0"
debug_pad_button_zl\default=false
debug_pad_button_zl="engine:keyboard,code:20,toggle:0"
debug_pad_button_zr\default=false
debug_pad_button_zr="engine:keyboard,code:26,toggle:0"
debug_pad_button_plus\default=false
debug_pad_button_plus="engine:keyboard,code:16,toggle:0"
debug_pad_button_minus\default=false
debug_pad_button_minus="engine:keyboard,code:17,toggle:0"
debug_pad_button_dleft\default=false
debug_pad_button_dleft="engine:keyboard,code:30,toggle:0"
debug_pad_button_dup\default=false
debug_pad_button_dup="engine:keyboard,code:31,toggle:0"
debug_pad_button_dright\default=false
debug_pad_button_dright="engine:keyboard,code:5,toggle:0"
debug_pad_button_ddown\default=false
debug_pad_button_ddown="engine:keyboard,code:0,toggle:0"
debug_pad_button_slleft\default=false
debug_pad_button_slleft="engine:keyboard,code:0,toggle:0"
debug_pad_button_srleft\default=false
debug_pad_button_srleft="engine:keyboard,code:0,toggle:0"
debug_pad_button_home\default=false
debug_pad_button_home="engine:keyboard,code:0,toggle:0"
debug_pad_button_screenshot\default=false
debug_pad_button_screenshot="engine:keyboard,code:0,toggle:0"
debug_pad_button_slright\default=false
debug_pad_button_slright="engine:keyboard,code:0,toggle:0"
debug_pad_button_srright\default=false
debug_pad_button_srright="engine:keyboard,code:0,toggle:0"
debug_pad_lstick\default=false
debug_pad_lstick="engine:analog_from_button,down:engine$0keyboard$1code$081$1toggle$00,right:engine$0keyboard$1code$079$1toggle$00,modifier:engine$0keyboard$1code$07$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$082$1toggle$00,left:engine$0keyboard$1code$080$1toggle$00"
debug_pad_rstick\default=false
debug_pad_rstick="engine:analog_from_button,down:engine$0keyboard$1code$014$1toggle$00,right:engine$0keyboard$1code$015$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.500000,up:engine$0keyboard$1code$012$1toggle$00,left:engine$0keyboard$1code$013$1toggle$00"
ring_controller\default=false
ring_controller="engine:analog_from_button,down:engine$0keyboard$1code$00$1toggle$00,right:engine$0keyboard$1code$00$1toggle$00,modifier:engine$0keyboard$1code$00$1toggle$00,modifier_scale:0.050000,up:engine$0keyboard$1code$00$1toggle$00,left:engine$0keyboard$1code$00$1toggle$00"
microphone_volume\default=true
microphone_volume=100
INI
else
    # Keep the user's file (controls, their own changes) but bring the tuned frame
    # generation settings up to date: v4 always 2x, v5 a 4-frame presentation queue.
    log "keeping the existing $APP_DIR/oot.ini; updating its frame generation settings"
    for kv in frame_gen=true frame_gen_type=1 frame_gen_multiplier=2 frame_gen_target_rate=0 \
              frame_gen_queue_target=1; do
        key=${kv%%=*}
        if grep -q "^$key=" "$APP_DIR/oot.ini"; then
            sed -i "s|^$key=.*|$kv|; s|^$key\\\\default=.*|$key\\\\default=false|" "$APP_DIR/oot.ini"
        else
            sed -i "/^\\[Renderer\\]/a $key\\\\default=false\\n$kv" "$APP_DIR/oot.ini"
        fi
    done
fi

B=$'\033[1m' N=$'\033[0m'
cat <<DONE

${B}Installed.${N} Launch the game with:

  $APP_DIR/lichii-bc250 -f -c $APP_DIR/oot.ini -g "<path to your Ocarina of Time dump>"

The -c file holds the tuned per-game settings (every \\default=false line matters:
without it the loader ignores the value next to it).

${B}First launch:${N} the screen stays black for 3-5 minutes while the
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
        --exe "$APP_DIR/lichii-bc250" \
        --launch-options "-f -c \"$APP_DIR/oot.ini\" -g \"$(realpath "$GAME_PATH")\""
    log "shortcut added; start Steam and it will be in your library under Non-Steam"
fi
