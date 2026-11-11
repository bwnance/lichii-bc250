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

**Base:** Lichii `nx2` **build 150** (`17baed716d`, 2026-11-10), with this fork's commits on
top. Data stays in the Eden folders (`~/.local/share/eden`, `~/.config/eden`,
`~/.cache/eden`): see the build 150 notes below.

## Changelog

### 2026-11-11 (later): Fritchii v5.6-v5.8.3 ports

Owner's verdict after playing it: "works really well most of the time above 30 fps with just
2 minor drops to 20 fps, best candidate so far". Measured on the straight Kokiri Forest walk:
~25 fps world rate (23.2-24.5 before).

- **Hot guest pages stay unprotected** (port of Eglantine f27522bfb9 via Fritchii, `EDEN_NX2_EXP48`,
  on; `=0` turns it off). Pages the game's CPU rewrites every frame were write-protected after
  each upload and faulted on the next write; they now stay modified and are uploaded at most
  once a frame. About +1 fps on the walk, no memory cost. A page written again after its upload
  reaches the GPU one frame later; no flicker seen in play.
- **No empty GPU submissions** (`EDEN_NX2_EXP61`, on), counting batched uploads as work.
- **JIT: dynarmic's IR verification pass skipped** (`EDEN_NX2_JIT_FAST_COMPILE=0` keeps it).
- **A compute pipeline being rebuilt keeps dispatching** instead of freezing up to ~3 s
  (Lichii #969).
- Off by default here: `EDEN_NX2_JIT_WARM=1` (idle cores pre-compile game code: +600 MB RSS and
  one boot hang in four runs on the BC-250), `EDEN_NX2_IR_POOL_CAP_MIB=<n>` (no effect measured).
- Not taken: Fritchii's EXP56, EXP58, EXP53, the read throttle switch and the report/fence
  allocation rework (already covered by this base, specific to Fritchii's texture cache, or
  tied to features this base doesn't have).
- Measured: 663 MiB of the ~3.7 GiB of resident guest memory holds only zeros. Lichii's
  zero-page trim is Windows-only; a safe Linux equivalent is still open.

### 2026-11-11: Lichii build 150, memory trims, Max Resolution on

Measured on the owner's test (load the save in Kokiri Forest, walk straight ahead for 30 s;
two runs each): **~25 fps** world rate, peak GPU memory ~6.4-6.5 GB, image noticeably sharper.

- **Rebased on Lichii build 150.** Brings upstream's drain-free semaphore acquires (#949),
  cheaper per-draw work on the split back thread (#858), memory-reading macros run on the
  back thread (#1056), staging buffer reuse (#778), the Ocarina **white wash / blown-out
  lighting** fix (#1236), the ocarina crackle fix (#1196) and stand-ins for damaged texture
  members (#1197). The fork's own copies of the task/mesh fallback, `MADV_COLD` (#756) and
  #841 are now upstream's. The fork's macro DMA-read fast path is dropped: upstream's
  #1056 replaces it (`EDEN_NX2_DMA_READ_DRAIN` / `_RELAXED` no longer exist). Build 150 alone
  is about 7% faster than the previous build on the walk.
- **Max Resolution add-on on** (installer template and reference setup). The game renders
  its scene at full 1080p instead of upscaling a lower resolution; the "dreamy", soft image
  is gone. No measurable fps or memory cost on the BC-250.
- **Uneven-mip ASTC stays BC3 on AMD** unless `EDEN_NX2_UNEVEN_ASTC_RGBA8=1`. Upstream
  (#679) kept such textures as RGBA8 on RADV: Ocarina's two 1365x1365 cube arrays (90
  layers) became 967 MiB each and the board ran out of memory (peak GPU memory 6.9 GB).
- **Large ASTC arrays are re-compressed a few layers at a time** (`EDEN_NX2_ASTC_CHUNK_MIB`,
  default 64): the two 967 MiB decode images at every Kokiri Forest load are gone.
- **Native compute storage bindings keep the 8 MiB cap** unless
  `EDEN_NX2_NATIVE_COMPUTE_FULL=1`. Build 150's Mario Kart World fix (#1231) made Ocarina
  keep one 1 GiB buffer: peak GPU memory 6.3 -> 8.7 GB, more swapping and drops, no visible
  change.
- **Mesh emulation arenas start at 16 MiB** (`EDEN_NX2_MESH_ARENA_MIB`; they grow when
  needed): Ocarina needs at most ~10 MiB a submission but kept six 64 MiB arenas (384 MiB),
  now 64-80 MiB. `EDEN_NX2_MESH_ARENA_LOG=1` logs the usage.
- **Freed device memory blocks are kept for reuse** (`EDEN_NX2_MEM_RESERVE_MIB`, default 256,
  0 = off): new blocks took the kernel 10-58 ms to back while the board's RAM was full.
  Allocations of 4 ms or more are logged.
- **Data folder:** build 150 moves its data to `~/.local/share/lichii` and makes eden-cli
  stop until the Qt GUI imports the old folder. This fork builds eden-cli only, so it keeps
  the `eden` folders: saves, keys, config and shader caches stay where they are.
- **Diagnostics:** images of 256 MiB or more (`EDEN_NX2_LARGE_IMAGE_MIB=<n>` to change) are named in the log; upstream's
  `EDEN_NX2_STUTTER_TRACE=1` attributes every slow frame (it showed the remaining drops are
  memory pressure: allocations and page-ins while the 16 GB board swaps, not shader builds).

### 2026-11-10: baseline

- **The game runs a frame ahead of the GPU threads (`EDEN_NX2_FRAMES_AHEAD=2`).** The
  wrapper always set 2, but only `1` was parsed, so it meant 0, and `1` itself also waited
  for the current frame whenever the GPU was behind, which on the BC-250 is every frame.
  The game, the GPU threads and the GPU never overlapped. Kokiri Forest walk: 13.6 -> 21.3
  fps (same binary). Upstream made Ocarina wait for each frame to avoid one-frame white
  flashes on an RTX 5080; watch for those.
- **No more multi-second freezes every few minutes** (port of Lichii #756). Every 30 s the
  emulator wrote cold guest memory to swap with `MADV_PAGEOUT` while holding the mmap lock,
  stopping every guest core (audio included) for 3-15 s; it now uses `MADV_COLD`.
- **Load spikes no longer push the game into swap as hard.** Large staging buffers are
  sized in 8 MiB steps instead of powers of two and freed promptly: a Kokiri Forest load
  held 1.1 GiB of mostly empty 256 MiB buffers; now ~70 MiB. Peak GPU memory 5.3 -> ~3.7-4.5 GB.
- **GPU thread pinning on** (`pin_gpu_threads=true` in the template): the split GPU threads
  get their own cores in the same L3 cluster, the guest cores the rest.
- **Macro DMA reads drain the GPU back thread only when queued work can change the words**
  (99.6% of the drains changed nothing). Replaced by upstream's #1056 since build 150.
- **Cached task/mesh pipelines build at boot through the compute fallback** (Lichii #841).
- **Diagnostics:** `EDEN_NX2_PIPELINE_BUILD_TRACE` lines carry wall time and thread name,
  `EDEN_NX2_TC_LOG=<frames>`, `EDEN_NX2_VMA_DUMP=<path>` (VMA allocation map at the peak).

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
     PR author's 9070 XT; removes the occlusion-culling stalls OoT suffers from). Since build
     150 this is upstream's wait-on-last copy (#679), which this fork extends to RADV, plus
     a non-blocking host read of query results on RADV.
   - Already-satisfied semaphore acquires skip the split-GPU-thread drain (73% of ~2800/s
     acquires in Kokiri Forest).
   - Native submission budget of 512 draws on RADV.
   - Large texture unswizzles split over helper threads.
   - The Kokiri Forest compute shader builds unoptimized (1.3-4 s stalls on AMD).
   - Async draw discard defaults on for RADV (new pipelines no longer freeze the game).
2. Based on upstream `nx2` including the merged **task/mesh fallback** (PR #569), plus this
   fork's narrower pre-dispatch barrier, empty-draw skip and smaller arenas: the
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
- The built-in **Max Resolution** add-on renders the scene at full 1080p (on in the
  template). Without it the game draws a smaller image and upscales it, which looks soft on a
  TV; on the BC-250 it costs no measurable fps.
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
and Max Resolution on (full 1080p scene). If any of
those are changed, expect different results.

## Reference console configuration

The performance above was measured with this hardware and tuning (the numbers assume the
installer's wrapper and config *plus* these settings):

| Setting | Value |
|---|---|
| Memory | 16 GB total; **UMA carve-out 512 MB** (~15.2 GB system RAM) |
| Swap | zram plus a disk swapfile; **`vm.swappiness=10`** (Bazzite's default is 180) |
| CPU | All 8 cores enabled (stock boots with 6) |
| GPU compute units | 40 (all WGPs routed) |
| GPU clocks | 500–2000 MHz governor range (stock caps at 1850) |

Notes:
- The small carve-out is the biggest single lever: the game's guest memory plus the
  texture cache does not fit in the stock 6 GB carve-out alongside the OS, and the
  emulator OOM-kills. The GPU spills into shared memory, which this workload tolerates
  well; it used ~330 MB of a 1024 MB carve-out, so 512 MB gives the system 0.5 GB more.
- Memory is still the limit: the emulator holds ~7 GB of RAM plus 3.5-4.5 GB of GPU memory.
  With swappiness 180 the kernel swapped game memory out with 1 GB of RAM still free, and
  touching it again cost seconds at 1-17 fps. `/etc/sysctl.d/99-bc250-swappiness.conf`
  with `vm.swappiness = 10` keeps it in RAM and drops file cache first.
- 2000 MHz over the stock 1850 is stable for emulation on this box, but it is outside the
  image's default for a reason: watch your temperatures. If yours runs hotter, drop back
  to 1850.
- The GPU's minimum 500 MHz saves ~10 W at idle and does not affect load performance.

## Matching the reference setup, step by step

The emulator build and its launcher come from the installer (above). These are the system
changes outside the emulator that the reference console has. Run them on the BC-250 itself;
the ones with `sudo` need your password. Each step says how to check it.

1. **UMA carve-out 512 MB.** The carve-out lives in the board's CMOS, not on the disk, so it
   survives OS reinstalls and needs a reboot to apply. With
   [bc250_memcfg](https://github.com/fanoush/bc250_memcfg) (build it from source):

   ```sh
   sudo bc250memcfg UMA_SIZE 512     # written now, used from the next boot
   sudo systemctl reboot
   ```

   Check: `cat /sys/class/drm/card1/device/mem_info_vram_total` shows `536870912`, and
   `free -m` shows about 15 GB of RAM. (Your card may be `card0`.)

2. **Swap: zram plus a disk swapfile.** Bazzite already sets up zram (compressed swap in
   RAM). Add a disk swapfile as a safety net so a long session can't run out of memory
   outright. On Bazzite `/var` is btrfs, and btrfs needs a dedicated subvolume for a
   swapfile:

   ```sh
   sudo btrfs subvolume create /var/swap
   sudo btrfs filesystem mkswapfile --size 16g /var/swap/swapfile
   sudo swapon --priority 10 /var/swap/swapfile
   echo '/var/swap/swapfile none swap defaults,pri=10 0 0' | sudo tee -a /etc/fstab
   ```

   Priority 10 keeps zram (priority 100) in use first; the disk is only touched once zram
   is full. Check: `swapon --show` lists both.

3. **Swappiness 10.** This is the setting that removed most of the multi-second drops.
   Bazzite ships `vm.swappiness=180` (good for zram on a desktop), which on this board
   pushed the game's own memory out to swap while RAM was still free; touching that memory
   again stalled the game for seconds. At 10 the kernel drops file cache first and keeps
   the game in RAM:

   ```sh
   printf 'vm.swappiness = 10\n' | sudo tee /etc/sysctl.d/99-bc250-swappiness.conf
   sudo sysctl --system
   ```

   The file name must sort after Bazzite's `/usr/lib/sysctl.d/65-memory.conf`, which sets
   180. Check: `cat /proc/sys/vm/swappiness` shows `10`, also after a reboot.

4. **8 CPU cores, 40 compute units, GPU clock range 500-2000 MHz.** See the table above;
   the BC-250 community tools (core/CU unlock, the image's `cyan-skillfish-governor-smu`
   config) set these. The core unlock is undone by a cold boot (power cut) and needs a warm
   reboot to apply. Check: `nproc` shows `16`.

5. **Optional: larger kernel GPU-memory (GTT) limit.** The reference console boots with
   `ttm.pages_limit=3145728 ttm.page_pool_size=3145728` (12 GB) because another program on
   it needed more. Ocarina's GPU memory peaks at about 6.5 GB during an area load, under the
   default limit (half of RAM, ~7.5 GB) but close to it, so this is recommended:

   ```sh
   sudo rpm-ostree kargs --append-if-missing=ttm.pages_limit=3145728 \
       --append-if-missing=ttm.page_pool_size=3145728
   ```

6. **Connect the controller before you start the game.** The emulator only picks up the
   pad that is connected at launch; plug in or pair the Xbox 360 receiver first, or the
   game will get no input.

Things that made no difference on this board, so you can skip them: a lower internal
resolution or a smaller texture cache budget (memory and fps stay the same), pinning the
GPU clock to maximum (the GPU is not the limit), and the newer Fritchii v5 builds (they
are tuned for desktop GPUs with their own memory and run slower here, with frame
generation disabled).

## Verified on hardware (BC-250, RADV GFX1013)

- Foliage and building walls render (mesh fallback); no white holes.
- World frame rate ~25 fps walking straight through Kokiri Forest for 30 s (build 150 base;
  ~23.5 on the previous base, ~12-14 before the frames-ahead fix), console-speed gameplay via
  Dynamic FPS; frame generation doubles the presented rate (about 45-50 shown while walking,
  60 in menus) at no cost to the world rate.
- Remaining: short dips after area loads. An area load fills the 16 GB of shared memory
  (guest memory ~5 GB, emulator ~2-3 GB, GPU ~6.5 GB at the peak) and the kernel swaps; the
  page-ins and slow GPU allocations that follow cause most of the drops that are left.
