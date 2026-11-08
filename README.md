# oot-bc250

> **Disclaimer: this project does not support or condone piracy.** No game data, keys,
> firmware or other copyrighted console assets are included, provided or linked here. The
> emulator requires you to dump **your own** game, keys and firmware from **your own**
> console; use it only with backups of content you legally own. Do not open issues about
> obtaining games, keys or firmware — they will be closed.

A [Lichii](https://github.com/zortos293/Lichii) fork tuned for **The Legend of Zelda:
Ocarina of Time (Switch 2)** on the **AMD BC-250 console** (GFX1013-class iGPU, RADV,
1080p TV output, shared-memory 16 GB with a small UMA carve-out).

All emulator credit belongs to the Lichii, Eglantine, Eden and yuzu authors; this repo only
carries the BC-250-specific deltas on top. GPLv3, like upstream.

## Changelog

- **Narrowed the mesh-emulation pre-dispatch barrier.** The barrier before every emulated
  mesh draw's compute dispatch drained the entire pipeline (all graphics, compute and
  transfer stages, all writes) — ~57 full drains per frame in Ocarina of Time, more GPU
  cost than the dispatches themselves on an iGPU. The mesh programs read compute output,
  DMA copies and fragment stores; the barrier now covers exactly those sources.
  `EDEN_NX2_MESH_WIDE_BARRIER=1` restores the wide form.
- **Empty emulated draws are skipped before doing work.** The game culls on the GPU and
  hands ~12% of emulated draws zero groups; each one still paid three staging requests,
  a render-pass break and a pass restart around a no-op. They now return before any of it.
- **PR #573 AMD performance fixes, ported and RADV-gated.** Upstream gates every fix on
   AMD's proprietary Windows driver; the BC-250 runs RADV (`VK_DRIVER_ID_MESA_RADV`), so
   they never fired there. This fork extends the gates (see below).
- **BC-250 installer and Steam shortcut helper** (`tools/bc250/`): distrobox build, tuned
  wrapper and per-game config template, and a safe binary `shortcuts.vdf` writer.

## What this fork adds on top of upstream `nx2`

1. **PR #573 AMD performance fixes, ported and RADV-gated.** Upstream gates every fix on
   AMD's proprietary Windows driver; the BC-250 runs RADV (`VK_DRIVER_ID_MESA_RADV`), so
   they never fired there. This fork extends the gates:
   - Query-cache copies no longer block on slots where no query ended (9 -> 22 fps on the
     PR author's 9070 XT; removes the occlusion-culling stalls OoT suffers from).
   - Already-satisfied semaphore acquires skip the split-GPU-thread drain (73% of ~2800/s
     acquires in Kokiri Forest).
   - Native submission budget of 512 draws on RADV.
   - Large texture unswizzles split over helper threads.
   - The Kokiri Forest compute shader builds unoptimized (1.3-4 s stalls on AMD).
   - Async draw discard defaults on for RADV (new pipelines no longer freeze the game).
2. Based on upstream `nx2` including the merged **task/mesh fallback** (PR #569): the
   BC-250's GPU lacks `VK_EXT_mesh_shader`, so without it OoT's foliage, building walls and
   other task/mesh geometry is skipped entirely. With it, the missing geometry renders
   correctly (verified on hardware).

## Building

Tested on Fedora 42 with clang; CLI only (no Qt):

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_QT=OFF -DYUZU_CMD=ON -DENABLE_WEB_SERVICE=OFF -DYUZU_ROOM=OFF \
  -DYUZU_TESTS=OFF -DENABLE_WERROR=OFF -DENABLE_UPDATE_CHECKER=OFF \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build build --target eden-cli
```

`src/audio_core/out/` must be present (it is in this branch's history; it is gitignored in
some upstream source exports, and the build fails without it).

## Runtime notes for the BC-250

- Firmware and keys go where upstream expects them (`~/.local/share/eden/keys`,
  `nand/system/Contents/registered/<ncaid>/00`). You must dump these from your own console.
- The built-in **Dynamic FPS** add-on makes game speed follow wall-clock time, so movement
  stays console-speed below 30 fps; disable it in Add-Ons if you prefer frame-locked timing
  (game then runs slow-motion under 30 fps).
- The built-in **Max Resolution** add-on pins the internal resolution; leaving it disabled
  lets the game's dynamic resolution drop under GPU load (recommended on an iGPU).
- FSR3 frame generation (`frame_gen`, type `Fsr3`) works; it acts after the game presents,
  so in-emulator frame counters do not include generated frames.

## Installation on the BC-250

The console runs Bazzite (an immutable OS), so the binary is built inside a distrobox
container and launched through a small wrapper that sets the tuning for this iGPU.

```sh
git clone https://github.com/lethevimlet/oot-bc250.git
cd oot-bc250
./tools/bc250/bc250-install.sh --with-shortcut --game "<path to your Ocarina of Time dump>"
```

That creates the `oot-bc250-build` Fedora 42 container, installs the build dependencies in
it, builds `eden-cli`, installs the wrapper to `~/Applications/oot-bc250/oot-bc250` with the
tuning in the wrapper and a per-game config template (`oot.ini`), and — with
`--with-shortcut` — registers the game as a Steam non-Steam shortcut so it launches from
Gaming Mode with a controller. The shortcut step needs Steam stopped (the installer tells
you when); the installer never starts or stops Steam for you.

The manual launch, if you prefer no shortcut:

```sh
~/Applications/oot-bc250/oot-bc250 -f -c ~/Applications/oot-bc250/oot.ini \
  -g "<path to your Ocarina of Time dump>"
```

### First launch: 3-5 minutes of black screen

The first boot of the game stays on a **black screen for 3-5 minutes** while the shader
pipelines are prepared. This is normal, happens once per game version per emulator build,
and shrinks on later boots as the cache fills. The same applies in smaller form to the
first minutes of each new area in a session: first-visit content compiles its pipelines
once (a hitch), and the cost decays session by session. This is the single most common
"it's broken" report — it isn't; wait it out the first time.

### Shader caches

The pipeline cache lives in `~/.cache/eden/shader/<title id lowercase>/` (for Ocarina of
Time: `~/.cache/eden/shader/0400486024dec000/`). Caches from other builds of the same
lineage are picked up when the format version and magic match, and files from other
versions are ignored safely. A pre-warmed cache removes most of the first-boot wait
above; it does **not** raise steady-state performance. The GPU driver keeps its own
binary cache separately, which rebuilds on first run regardless.

### Controllers

The CLI frontend does not auto-bind gamepads. The installer's `oot.ini` template ships the
verified Xbox 360 wireless receiver mapping (the common BC-250 setup); a different pad
needs its own `player_0_*` lines in the `[Controls]` section, or configure the pad once
with the GUI build and copy the `[Controls]` block over. Every mapping line must carry
`<key>\default=false` — without it the loader ignores the value.

### Achieving the measured performance

The numbers below assume the installer's wrapper and template exactly: texture-cache
budgets for the UMA split, the split GPU thread, batched fences, two-frames-ahead pacing,
shader preloading at boot, handheld docked mode, 8 GB memory layout, GPU Fast accuracy,
async shaders and presentation, FSR scaling filter with 60% sharpening, FSR3 frame
generation at 2x capped at 30, Dynamic FPS on (console-speed movement at any frame rate)
and Max Resolution off (the game's dynamic resolution drops under GPU load). If any of
those are changed, expect different results.

## Reference console configuration

The performance above was measured with this hardware and tuning (the numbers assume the
installer's wrapper and config *plus* these settings):

| Setting | Value |
|---|---|
| Memory | 16 GB total; **UMA carve-out 1024 MB** (~14.7 GB system RAM) |
| CPU | All 8 cores enabled (stock boots with 6) |
| GPU compute units | 40 (all WGPs routed) |
| GPU clocks | 500–2000 MHz governor range (stock caps at 1850) |

Notes:
- The 1024 MB carve-out is the biggest single lever: the game's guest memory plus the
  texture cache does not fit in the stock 6 GB carve-out alongside the OS, and the
  emulator OOM-kills. At 1024 MB the GPU spills into shared memory, which this workload
  tolerates well.
- 2000 MHz over the stock 1850 is stable for emulation on this box, but it is outside the
  image's default for a reason: watch your temperatures. If yours runs hotter, drop back
  to 1850.
- The GPU's minimum 500 MHz saves ~10 W at idle and does not affect load performance.

## Verified on hardware (BC-250, RADV GFX1013)

- Foliage and building walls render (mesh fallback); no white holes.
- World frame rate ~17-21 fps with flat frame times (occlusion stalls gone), console-speed
  gameplay via Dynamic FPS; frame generation roughly doubles the presented rate.
