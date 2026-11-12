# Changelog

Versions follow `main`: the README title carries the current one, and it goes up by one with
every merge into `main`. Entries before v4 are dated only.


### v7 (branch `v7`, not merged yet) — 2026-11-12: shorter freezes in big areas

- **New system setting: `vm.watermark_scale_factor=1000`** (README, step 1.4). Entering Hyrule Castle
  Town the first time froze the game for 10-14 s (six runs): the area needs ~3 GB of GPU memory in
  30 s, and each of ~140 allocations waited while the kernel compressed other memory into swap
  (10.7-13 s of allocation time). With the kernel keeping ~1.5 GB free ahead of time the entry
  freezes for 2-3 s, and the rest of the castle route has no pause over 0.15 s (before: up to
  4.5 s). Hyrule Field loop: 58.4 screen fps, 4 repeated frames/s (before 57-58 fps, 8-12/s).
  2000 was worse (more swapping in play).
- **zram three quarters of RAM** (README, step 1.5; 7.4 -> 11 GB here). A 10-minute session in
  Castle Town filled the old zram, the kernel moved on to the disk swapfile and the game froze for
  up to 27 s.
- **Lichii PR #1373 ported** (MWAITX idle wait for guest cores): within noise on the BC-250
  (Hyrule Field walk 28.9 -> 29.0 game fps), kept because it matches upstream.
- Measured and not adopted: GPU clock held at 2000 MHz (+0.3-0.8 game fps, inconclusive over
  5-minute runs), Unsafe CPU accuracy, per-physical-core pinning, a 60 Hz guest vsync, a smaller
  texture cache or ASTC decode cap for the castle load (no change), and suspending the texture
  cache's keep-recent protection under memory pressure (smaller cache, no smoother play).

### v6 — 2026-11-12: stutters gone (memory and shader builds)

Monitored play (Deku Tree, Hyrule Field, combat) showed the remaining drops were the 16 GB
board running out of RAM and swapping the game out, and new effects building their shaders on
the GPU thread. In the owner's session after these changes the worst pause after loading was
148 ms (before: 1-2.6 s) and no frame was held up by a shader build.

- **Background shader translation** (`EDEN_NX2_BACKGROUND_TRANSLATE`, on): a new pipeline's
  shaders translated on the GPU thread while it waited (17 ms on average, up to 80 ms). The
  environments now copy the engine state translation reads and the whole build runs as a shader
  job; draws the async-shader rule may drop are dropped until it is done, others wait for it.
  Cold-cache test: frames held up by shader builds 68 -> 0.
- **Image recycling** (`EDEN_NX2_IMAGE_RECYCLE_MIB`, 256): Ocarina renders its depth and HDR
  targets at a new address every frame, so the emulator made a new 8 MiB image ~30 times a
  second (1-2 GB of new GPU memory per 10 s), and every new block made the kernel swap. Freed
  images of 4 MiB and more are kept and reused: -80% new GPU memory, -60% swap-outs.
- **Shader compile caps** (installer: `EDEN_NX2_PIPELINE_WORKERS=4`,
  `EDEN_NX2_PIPELINE_DRIVER_THREADS=2`, `EDEN_NX2_IR_POOL_CAP_MIB=64`): a first visit to Hyrule
  Field compiled on 15 + 8 threads at once and took 3.7 GB, freezing the game for up to 13 s.
  Capped: peak 3.7 GB instead of 5.6 GB, worst freeze 6.9 s instead of 13 s (cold cache).
- **Smaller texture cache** (installer: 1.5 / 2 GB instead of 3 / 3.5 GB): ~2 GB more RAM free
  in play, fewer swap stalls, no texture reloads seen.
- **Parallel stage translation for texture tables up to 4 MiB** (`EDEN_NX2_TEX_POOL_FLUSH_MIB`):
  Ocarina's is 1,058,176 bytes, just over the old 1 MiB limit.
- **System setting from v5 now in the setup guide:** `vm.compaction_proactiveness=100`.
- **Diagnostics:** "Device memory 10 s" log lines (new GPU memory and the commonest sizes),
  slow pipeline builds log their phases, "Background translation" counts every 10 s.

### v5 — 2026-11-12: smoother frame delivery, Lichii build 160 picks, measuring tools

- **Deeper presentation queue:** the template sets `frame_gen_queue_target=1` (4 presentation
  frames instead of 3). Frames that come out early bank time for late ones, so frames reach
  the TV more evenly. On the TV it felt much smoother, near-stable 60 after a few minutes,
  with no noticeable input lag. To go back, set `frame_gen_queue_target=0`.
- **What 60 fps looks like on this route:** five-minute loops (walk, camera spin, walk back)
  show the screen at 59.9-60 fps with almost no repeated frames from the second minute on;
  the game holds 30 fps. The first minute after an area load is still rough (~52 fps on
  screen): the load fills memory and the kernel swaps about 3 GB out, then pages part of it
  back in. That is the next target.
- **New system setting: `vm.compaction_proactiveness=100`** (README, step 1). Monitoring a full
  Deku Tree run showed the remaining drops are swap page-ins: the GPU driver's 2 MB allocations
  made the kernel swap the game out while 2-4 GB of RAM was free. Background compaction cut the
  10-second windows with drops from 69% to 43% and swap page-ins by 30%. 1-2 s freezes remain
  when new content loads (GPU memory +1-2 GB); that is the next target.
- **Installer:** fixed the launcher it writes (a fresh install could not start the game:
  `REPO_BUILD_DIR` was never set in it); new `--pgo` builds with LLVM 23 and the bundled profile
  (~10% faster); re-running it updates the frame generation settings in an existing `oot.ini`.
- **From Lichii build 160:** #1095 (3D state registers written in one call), #1332 (front and
  back counters on separate cache lines), #1347 (shader clamp folding) and #1333 (read-only
  native compute bindings sized from their size word). #1333 replaces this fork's
  `EDEN_NX2_NATIVE_COMPUTE_FULL` opt-in: Ocarina no longer gets a 1 GiB buffer. The advertised
  shader compile speed-up (#1320) was already in v4.
- **More draws take the light (delta) path:** OoT's per-draw occlusion tests (counter resets,
  render-enable changes, report writes) and its macros' memory-read registers no longer force a
  full draw setup; `EDEN_NX2_FAST_DRAW_VERIFY=1` found no difference in five runs. No
  measurable fps change on its own.
- **New diagnostics (all off by default):**
  - a `Screen:` log line every 10 s: presents per second and frames the TV showed twice;
  - `EDEN_NX2_TIMELINE=<file>`: a Chrome-trace timeline of the GPU threads, started by
    creating `/tmp/nx2-timeline-go`;
  - `EDEN_NX2_LIST_RTT=1`: latency of GPU-written command lists;
  - `EDEN_NX2_CMDPAGE_DIAG=1`: now also counts which GPU path writes them.
- **Investigated without a gain, so not in v5:**
  - skipping drains on equal/mask semaphore waits;
  - parking channels while their command lists are written;
  - Mailbox and FIFO-relaxed present modes;
  - a third GPU thread (the front/back split already separates register processing from
    draws).

### v4 — 2026-11-11 (night): frame generation always 2x (~60 fps on screen)

- The template now sets `frame_gen_target_rate=0`: FSR3 frame generation always adds one
  frame per game frame (multiplier 2). The old `30` only filled dips below 30 fps, so the
  screen stayed at ~30. Route 2, 3 runs each: target 30 = game 28.5 / 29.4 fps (walk /
  spin), screen ~30; **target 0 = game 26.6 / 28.0, screen ~46-60**, frames over 50 and
  100 ms about the same as with 30.
- `frame_gen_target_rate=60` is **not** recommended: with any target set the multiplier is
  ignored and the pacer goes to 3x; each generated frame takes a vsync slot, so the game
  drops to 60/3 = 20 fps (walk 20.3, ~250 frames over 50 ms, worst up to 635 ms).
- New log line every 10 s while frame generation is on:
  `Frame gen output: X game fps + Y generated fps = Z fps`, since the in-emulator counters
  only count game frames.
- Cost: one game frame of extra input lag (~35 ms) and the usual interpolation artifacts on
  fast edges and the HUD. To go back, set `frame_gen_target_rate=30`.

### v3 and earlier

#### 2026-11-11 (evening): stutter fixes, renamed to lichii-bc250

Measured on a new, harder route: after the 30 s Kokiri Forest walk, a 12 s camera spin, 15 s
walking back through the open forest and another 12 s spin (3 runs per build).

| | before | now |
|---|---|---|
| frames over 100 ms (route) | 10 / 8 / 9 | 2 / 2 / 1 |
| frames over 50 ms (route) | 95 / 70 / 90 | 21 / 27 / 8 |
| fps (route) | ~26.5 | 28.4-29.9 |
| fps (30 s walk) | 26.9-27.5 | 28.1-30.3 |
| device-memory peak | ~6.1 GB | 4.5-5.0 GB |

- **Texture cache keeps images used in the last 300 frames** (`EDEN_NX2_TC_MIN_AGE`, ~10 s at
  30 fps; not when device memory runs out). On the BC-250 the cache sits above its critical
  threshold all session, and the collector deleted everything unused for 10 frames: Ocarina's
  6144x6144 ASTC texture was deleted and rebuilt every ~2.6 s as the camera turned (a new
  image, a 192 MiB decode and a 50-190 ms frame each time). This was most of the remaining
  stutter.
- **ASTC decode images are recycled as soon as the GPU is done with them** and capped in
  flight (`EDEN_NX2_ASTC_PENDING_MIB`, default 256). At the save load's memory peak, 449
  decode images held 2.3 GB at once; the peak drops by ~1.7 GB.
- **Fix: GPU write fault (device lost) in ASTC transcodes.** The transcode submits after every
  decode, so its staging buffers were still used after the tick they were stamped with, and
  the pool could free one while the GPU wrote it.
- **Lichii ports:** #1313 (built-in fix for Ocarina's guard-house freeze), #1314 (guard house
  from single digits to 50+ fps, superseded images deleted), #852, #1320, #1327, #1331, and
  #1225's JIT warm-up list as an opt-in (`EDEN_NX2_JIT_WARMUP_LIST=1`; every core compiles the
  whole list, which costs RAM). Not taken: #1334/#1337 (keep pipelines in memory: +~90 MiB for
  rare hitches), #1335 (device-memory overallocation).
- **Diagnostics:** `EDEN_NX2_VMA_PEAK_DUMP=<path>` writes VMA's allocation map at each new
  device-memory high; `EDEN_NX2_LARGE_IMAGE_MIB=<n>` now also logs why large images are deleted.
- **Controllers reconnect** (see below) and the repo, installer container
  (`lichii-bc250-build`) and wrapper (`~/Applications/lichii-bc250/lichii-bc250`) are renamed.
  An older install keeps working; its container can be removed with
  `distrobox rm lichii-bc250-build`.


#### 2026-11-11 (afternoon): controllers reconnect

- **A pad that disconnects and comes back works again without restarting the game**, and a pad
  switched on after launch is picked up too. Inside a rootless container (the distrobox the
  installer uses) libudev drops the host's hotplug messages, so SDL never saw a controller
  leave or return. When `/run/.containerenv` or `/.dockerenv` exists the emulator now sets
  `SDL_JOYSTICK_DISABLE_UDEV=1`, so SDL watches `/dev/input` with inotify instead (set the
  variable yourself to override). Controller add/remove is logged at Info level. Verified by
  unbinding and rebinding the Xbox 360 receiver mid-game: Steam re-creates its virtual pad and
  the emulator puts it back in the same player slot about a second later.

#### 2026-11-11 (night): PGO build, smaller JIT tables, three Lichii PRs

- **PGO build: about +10% world fps.** Built with clang 23 and `lichii-linux.profdata` (from
  zortos293/Lichii PR #1205: Lichii's profile merged with a Linux Ocarina of Time run on a
  Zen 2 CPU and RADV). Straight Kokiri Forest walk, same source: 26.6 / 26.4 / 28.1 fps with
  the profile against 24.3 / 24.3 without, and fewer slow frames (73-98 over 50 ms per walk
  against 105-120). See "Building with PGO" below.
- **Fastmem patch entries 24 -> 20 bytes** in dynarmic: the block location, the same for every
  access of a block, is stored once per block.
- **Lichii PRs not merged upstream yet:** #1271 (hand freed heap memory back to Linux after
  pipeline evictions), #1241 (Ocarina's recreated post-processing targets skip a pointless
  upload), #1265 (no perf-map lock per compiled block). No measurable change on the walk.

##### Building with PGO

The profile is indexed format 14: it needs clang 22 or newer (Fedora 42's clang 20 cannot read
it). LLVM's prebuilt `LLVM-23.1.5-Linux-X64.tar.xz` from the LLVM GitHub releases works inside
the build container. Same configure as usual, plus:

```sh
L=/path/to/LLVM-23.1.5-Linux-X64/bin
P="-fprofile-use=$PWD/lichii-linux.profdata -Wno-backend-plugin -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date"
cmake -S . -B build-pgo -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=$L/clang -DCMAKE_CXX_COMPILER=$L/clang++ \
  -DCMAKE_AR=$L/llvm-ar -DCMAKE_RANLIB=$L/llvm-ranlib \
  -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld "-DCMAKE_C_FLAGS=$P" "-DCMAKE_CXX_FLAGS=$P" \
  -DENABLE_QT=OFF -DYUZU_CMD=ON -DYUZU_TESTS=OFF -DBUILD_TESTING=OFF -DENABLE_LTO=OFF
cmake --build build-pgo --target eden-cli -j6
```

Functions changed since the profile was recorded just lose their profile data (the warnings
are switched off); the rest is optimized for Ocarina's hot paths.

#### 2026-11-11 (later): Fritchii v5.6-v5.8.3 ports

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

#### 2026-11-11: Lichii build 150, memory trims, Max Resolution on

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
- **Native compute storage bindings keep the 8 MiB cap** and grow only through a plausible size
  word (upstream #1333, since v5; it replaced this fork's `EDEN_NX2_NATIVE_COMPUTE_FULL`
  opt-in). Build 150's Mario Kart World fix (#1231) made Ocarina keep one 1 GiB buffer: peak
  GPU memory 6.3 -> 8.7 GB, more swapping and drops, no visible change.
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

#### 2026-11-10: baseline

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
