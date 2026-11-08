# oot-bc250

A [Lichii](https://github.com/zortos293/Lichii) fork tuned for **The Legend of Zelda:
Ocarina of Time (Switch 2)** on the **AMD BC-250 console** (GFX1013-class iGPU, RADV,
1080p TV output, shared-memory 16 GB with a small UMA carve-out).

All emulator credit belongs to the Lichii, Eglantine, Eden and yuzu authors; this repo only
carries the BC-250-specific deltas on top. GPLv3, like upstream.

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

## Verified on hardware (BC-250, RADV GFX1013)

- Foliage and building walls render (mesh fallback); no white holes.
- World frame rate ~17-21 fps with flat frame times (occlusion stalls gone), console-speed
  gameplay via Dynamic FPS; frame generation roughly doubles the presented rate.
