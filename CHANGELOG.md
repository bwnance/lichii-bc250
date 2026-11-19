# Changelog

Versions follow `main`: the README title carries the current one, and it goes up by one with
every merge into `main`. Entries before v4 are dated only.


### v20 — 2026-11-18: shorter freezes in new areas, Ocarina flashing objects

- **Shorter freezes when shaders are still compiling.** A compute pass whose shader is still being built
  is skipped for a frame when the game already wrote its outputs, instead of freezing until the build
  ends (Lichii #2104). A draw that waits for a shader now compiles its driver stage itself instead of
  queuing behind the background prebuild (#2098). On the BC-250 with an empty shader cache, Castle Town's
  worst freeze went from 7.4 s to 2.6 s; with a warm cache its first entry from 3.3-4.7 s to 1.6-1.9 s.
- **Ocarina of Time: objects flashing through solid colours** (wall trims and others). A handle the game
  leaves out of range was read as one of its render targets by a rule made for Switch Sports; that rule
  now applies to Switch Sports only (Lichii #2051, Eglantine #900). Cached shaders that the old rule could
  have misread are captured again once; we narrowed upstream's check so the rest of the shader cache
  stays valid (upstream's version made about half of Ocarina's cached pipelines fail to load on every boot).
- Multi-range buffers are freed after 60 unused frames instead of kept for the whole session (#2054).
- A race in invalidating JIT code pages fixed (#2053), with the change counter shared by all cores for
  our shared JIT.
- Frame rate unchanged (2 runs x 4 routes, 55-59 fps on both builds).

### v19 — 2026-11-17: installer fixes

- **No crash at start with Borderless Gaming installed.** Borderless Gaming registers a Vulkan effects
  layer (`VK_LAYER_BGFX_effects`) for every Vulkan program. Inside the emulator that layer aborted it
  while it started ("Failed to create the thread pool Gate thread"). The launcher now switches it off
  (`DISABLE_BGFX=1`); systems without Borderless Gaming are not affected.
- **Removed a dead line from the template `game.ini`.** `memory_layout_mode` sat under `[System]`, where
  the emulator never reads it. Switch 2 games always get the 12 GiB layout on their own, so nothing
  changes in play. Existing `game.ini` files can keep the line; it does nothing.
- No emulator changes; re-run the installer to get the new launcher.

### v18 — 2026-11-17: one settings file for every game, and Steam shortcuts from the installer

- **`game.ini` is the BC-250 settings file for every game** (it was `oot.ini`, Ocarina only). The
  launcher uses it when no `-c` is given, so any game gets the tuned settings (Mario Kart World runs
  at ~57 fps with them). An existing install's `oot.ini` is renamed to `game.ini` on update, its
  backups too, and `oot.ini` stays as a link to it so older shortcuts keep working.
- **`--add-game <path> [--name <name>]`** adds Steam shortcuts for your games (repeat it for
  several); on an existing install it only adds the shortcuts. Steam must be closed first.
- The uninstaller keeps `game.ini` for a later install.
- No emulator changes; tested and not kept for busy scenes (Castle Town plaza): a larger GPU
  memory reserve and `vm.extfrag_threshold=1000` (both within run-to-run noise).

### v17 — 2026-11-17: latest Lichii, and RAM freed before area loads

- **Merged the latest Lichii** (86 upstream changes after v15's merge): GPU thread improvements
  (command list copies batched, the GPU back no longer waits for a guest's turn), staging buffers
  that recover when memory runs short, Ocarina mesh-draw and "No sharpening" fixes, a Mesh Shaders
  setting, and upstream's own versions of two of this fork's fixes (#1908, merged from here, and
  #1991, the texture retention limit from v16). Test routes: Kokiri 58.3, Hyrule Field on Epona
  57.7, Castle Town 57.6 fps, the best so far on each.
- **Shorter freezes when entering an area.** An area load reads the next area's files 2-5 s before
  its textures arrive; with RAM full, those ~250 GPU memory allocations waited while the kernel
  swapped (Castle Town entry: 2.2-3.8 s). When the game starts such a read burst and less than
  2 GB is free, the emulator now asks the kernel to free cold memory up to 2 GB first (at most once
  a minute): Castle Town entry 1.2-1.5 s. Inside the installer's container the emulator can't do
  that itself, so the launcher runs a small helper next to it. Works for every game;
  `EDEN_NX2_PRE_RECLAIM_MIB=0` turns it off, `EDEN_NX2_PRE_RECLAIM_TARGET_MIB` sets the target.
  (An earlier version freed 1.5 GB at every burst and caused short audio stutters; it only frees
  what is missing now.)
- Tested and not kept: a larger image recycler, periodic heap trimming (`EDEN_NX2_HEAP_TRIM_S`
  stays as an off-by-default test switch), collecting the texture cache in the middle of a frame.

### v16 — 2026-11-16: shared JIT, smoother camera turns, shorter area-entry freezes, no lag with frame gen off

- **One copy of the translated game code for all six emulated CPU cores** (it was translated and
  stored once per core: 73 % of it duplicates). The emulator's own memory is about 1 GB lower
  (Castle Town route: 2.7 vs 3.7 GB; JIT code 174 vs 660 MB) and it stays lower in long sessions.
  `EDEN_NX2_SHARED_JIT=0` goes back to one cache per core. Design notes: docs/bc250-shared-jit.md.
- **Fast camera turns no longer rebuild textures.** Textures used in the last ~10 s were meant to
  be kept while there is room, but on the BC-250 that rule never applied (it compared all of the
  GPU memory, not only textures, with the limit), so a texture out of view for one second was
  deleted and decoded again when the camera came back: 150-380 a second while turning. Test
  routes: Kokiri Forest 53.6 -> 58.1 fps (turns 47-51 -> 58-60), Kakariko 58.2 -> 58.8, second
  laps 59-60 everywhere.
- **Shorter freezes when entering an area.** Ocarina's 288 MiB shadow map is re-created on every
  area entry and the emulator first copied its old contents from game memory (2.3 s with RAM
  full); a new depth buffer the game hasn't drawn yet is now just created. Dead render-target
  copies are freed instead of kept for 10 s. Castle Town entry: 4.1-5.7 s -> 2.3-2.9 s.
- **No input lag with frame generation off and a framerate limit.** With Gaming Mode's 30 fps
  limit, frames waited in the emulator's present queue (~130 ms, felt as up to a second of lag).
  Without frame generation only the newest finished frame is presented now (~23 ms).
  Frame generation is unchanged. `EDEN_NX2_NOFG_LATEST=0` restores the old behaviour.
- Diagnostics: `EDEN_NX2_PRESENT_LATENCY_LOG=1` (present-queue latency every 10 s), an on-demand
  GPU memory map (`touch <EDEN_NX2_VMA_PEAK_DUMP>.now`), retention limit in the texture cache log.

### v15 — 2026-11-15: a 768 MB memory leak fixed, faster start-up, latest Lichii

- **Fixed a memory leak that grew all session.** The emulator kept a record of every GPU compute
  upload and only cleared it for one kind of compute launch, which Ocarina doesn't use: 24 bytes per
  upload, never freed, 768 MB after ~90 minutes of play (found with a memory profiler in a real play
  session; about 40% of the emulator's memory growth). That memory pushed the rest of the game into
  swap in long sessions. It now stays under 100 KB.
- **Merged the latest Lichii** (55 upstream changes after build 228). For Ocarina on the BC-250:
  start-up waits only for the shaders of your last two sessions and builds older ones in the
  background (the start-up shader list grew with every session), Ocarina upscale and output shaders
  recognised by their program, cheaper write traps on pages without textures, early read-back
  downloads kept for pages the game reads every few frames, staging buffers that degrade instead of
  aborting when memory runs out, and gyro that survives a controller reconnect.
- Kept from this fork where upstream changed the same code: 64 MiB ASTC decode chunks and the
  transcode memory limits, the present-fence profile zone, fast-draw handling of macro memory reads.

### v14 — 2026-11-15: Lichii build 228, and a memory setting that stops long-session stutter

- **Update your watermark setting to 300** (README setup step 4). The earlier recommendation, 1000,
  kept ~3 GB of RAM free at all times, so the kernel kept pushing the game's own memory out to swap
  and reading it back: in a long session v13 dropped to 53-56 fps with a 1-9 s pause every minute or
  two after ~15 minutes. With 300 the same kind of session read ~10x less back from swap and held
  58-60 fps (Lake Hylia, fishing pond, Zora's Domain, Jabu-Jabu); area entries freeze ~1 s longer.
- **The installer now checks the README's system settings** at the end of every install or update
  and warns about any that differ (RAM split, swappiness, compaction, watermark, zram, swapfile, and
  the optional GPU memory limit and oomd). It changes none of them.
- **Merged Lichii build 228** (152 upstream changes since build 177). For Ocarina on the BC-250 the
  ones that matter: Mesa keeps its own shader cache instead of a second copy in the emulator (#1653),
  fewer waits when the game reads GPU results back (#1795), the ocarina-warp freeze fix (#1218),
  compute shader rebuilds on a worker (#995), guest cores no longer block on frame fences (#1639),
  the cloth/hair speed and other FPS Unlock fixes. Castle route A/B against v13: about the same.
- Kept from this fork where upstream changed the same code: the BC-250 mesh fallback, non-blocking
  occlusion reads on RADV, the texture-cache budget fix from v13, 64 MiB ASTC decode chunks, the
  Bluetooth controller stand-in, and background shader translation.

### v13 — 2026-11-15: smoother Castle Town: no texture-cache thrash, ~1 GB less at loads

Measured on the BC-250 castle route (3 alternating runs each): route 49.5-52.9 -> 55.1-55.9 fps,
repeated frames 7.8-10.4 -> 5.3-5.5 per second, second plaza visit 48-55.5 -> 56.4-58.7 fps, field
and town 57.8-60 fps.

- **Texture cache no longer thrashes in busy places.** The installer's texture-cache limits were
  compared with *all* GPU memory, not just textures, so in Castle Town (~4 GB of GPU memory in use)
  the cache thought it was always full and threw away textures still in use: 1,100-2,300 re-uploads
  and up to ~1,000 texture conversions every 10 s. The limits now count textures only.
- **About 1.1 GB less memory at area loads.** Buffers the emulator had already deleted stayed
  allocated for 8 more frames, and an area load is one frame several seconds long: 1.2-1.3 GB held
  at the Castle Town peak. They are now freed as soon as the GPU is done with them (peak ~120 MiB).
  Texture-decoding scratch memory is capped lower too (64 MiB).
- **The image reuse pool is back on** (v12 turned it off by mistake): without it, play in Castle
  Town allocated and freed 1.8-5 GB of GPU memory every 10 s.
- New diagnostics: `EDEN_NX2_PROTECT_STATS=1` (memory-protection calls by site), deleted-buffer
  peak in the buffer-cache log line.

### v12 — 2026-11-15: steadier play in big areas, about 0.6 GB less GPU memory, no runaway Steam cache

- **Steam's shader pre-cache no longer fills the disk.** Steam records every pipeline a game
  builds into `~/.local/share/Steam/steamapps/shadercache/<id>/fozpipelinesv6`. For an emulator
  that file never stops growing: on the BC-250 it reached 42 GB in a day and filled the disk. The
  launcher now turns that recording off (`DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1`), which also
  made area loads and play smoother. If you updated from an older version, you can delete the
  `fozpipelinesv6` folder under your Ocarina shortcut's id to get the space back.
- **About 0.6 GB less GPU memory while playing** (3.6-3.9 GB instead of 4.3-4.6 GB on the Castle
  Town route): the spare image pool and the device-memory reserve, which held up to 0.5 GB for
  almost no reuse, are off by default (`EDEN_NX2_IMAGE_RECYCLE_MIB` / `EDEN_NX2_MEM_RESERVE_MIB`
  turn them back on). On a 16 GB board that RAM is what keeps the game out of swap: in 4 test runs
  of each version, v11 fell into heavy swapping once (field and town at 47-52 fps), v12 never.
- **Shorter freezes when entering big areas.** Entering Castle Town made thousands of new upload
  buffers in a single frame (2,209 in one 6.4 s frame), each a fresh memory allocation. Past
  64 MiB of uploads in flight the emulator now waits a few milliseconds for the GPU and reuses
  one (`EDEN_NX2_STAGING_CAP_MIB`, 0 = off).
- Upstream Lichii fixes: texture-cache cleanup that no longer stalls on images it can't remove
  and frees the emptiest memory blocks first (#1731), tighter timing for emulated events (#1733),
  a shader simplification (#1681), and two Ocarina timing fixes for the FPS unlock (cutscene
  frames #1743, Scarecrow's Song #1745).
- Known: the first ~30 s after arriving in a big area (Castle Town's plaza) can still drop below
  60 fps while the game reads back memory swapped out during the load.

### v11 — 2026-11-14: controller settings kept, the GUI in the package, texture-cache and upstream fixes

- **Controller settings stay put.** A mapping line written into `oot.ini` without its
  `<key>\default=false` line was read as "use the default" and, because the emulator rewrites
  its config on every start, replaced by a keyboard key marked as set: hand-made controller
  mappings vanished after one launch. Such a line is now used as written. The installer also
  saves `oot.ini` before every update (`oot.ini.bak-<date>`, last five kept), and the uninstaller
  keeps it in `~/.config/lichii-bc250/oot.ini` for a reinstall.
- **The GUI is back in the package.** The release now carries Lichii's Qt window next to
  `eden-cli`: `lichii-bc250 --gui`, or **Lichii BC-250** in the Desktop Mode menu. A controller
  mapped there is copied into `oot.ini` on the next game start from the Steam shortcut.
- Texture cache: images the GPU drew into and used in the last 300 frames are no longer thrown
  away and rebuilt when the cache is over its limit (the 297 MiB shadow map was rebuilt
  repeatedly late in long sessions, with 1-2.5 s freezes).
- Lichii upstream: the Ocarina white-flash fix (revert of #1486), Ocarina FPS-unlock fixes,
  foliage shadows (points and lines) through the mesh fallback, and an audio gap fix.

### v10 — 2026-11-14: fixes for missing foliage on some drivers and for controllers outside Steam

- **Missing or white/yellow foliage and props, for real this time.** The v9 logs from an affected
  CachyOS system showed what the driver refuses: pipelines with **mesh shaders**. Stock RADV offers
  no mesh shaders on the BC-250 (GFX1013), so every BC-250 this fork is tuned on draws Ocarina's
  task/mesh programs through the emulator's compute fallback. That CachyOS driver build does offer
  `VK_EXT_mesh_shader` there, then refuses every mesh pipeline (`VK_ERROR_FEATURE_NOT_PRESENT`),
  so the grass, leaves and props drawn that way never appeared. On a BC-250 the emulator now always
  uses the fallback (`EDEN_NX2_ALLOW_NATIVE_MESH=1` keeps the driver's mesh shaders).
  **On v9 the same fix is one variable:** `EDEN_NX2_FORCE_MESH_FALLBACK=1`.
- **Controllers that aren't Steam's virtual pad now work.** The installer binds player 1 to
  Steam Input's virtual pad, which every controller becomes when the game starts from Steam with
  Steam Input on. Started any other way (Desktop Mode, a terminal, Steam Input off), a pad shows up
  under its own identity and nothing was bound to it: no input at all (reported with a Bluetooth
  8BitDo after a switch to Bazzite). When the bound controller isn't connected, the first other
  gamepad now stands in for it, read through SDL's standard gamepad layout, so buttons, sticks and
  triggers land in the right place on any pad. It works for a pad connected before or after the
  game starts. Tested on the BC-250 with a virtual Bluetooth pad and Steam's pad hidden: before
  the fix the title screen ignored it, with it the pad went through the menus into the game.
- **Logs for input reports:** at start the log lists every gamepad the system has, with its IDs and
  whether the emulator can open it (`Gamepad on this system: ...`), names each controller that
  connects, and says when a pad stands in for the bound one.
- Castle route 53.8 screen fps, 6.1 repeated frames/s, the same as v9; same log lines.


### v9 — 2026-11-14: about 500 MB less RAM, fix for missing objects and white/yellow foliage

- **About 500 MB less emulator memory** (Castle Town route, end of route: ~3.5 GB of the
  emulator's own memory instead of ~4.05 GB in v8). Two changes did it, with no change to what is
  drawn:
  - built pipelines no longer keep a compressed copy of their shader code (about 310 MB in a long
    session); set `EDEN_NX2_KEEP_SPIRV=1` to keep it;
  - each shader's bookkeeping record is about 70 % smaller (its storage-buffer list was a fixed
    64-entry array; Ocarina's shaders use at most a handful), about 200 MB over ~3,800 pipelines.
  Less memory used means the 11 GB compressed swap fills later, so the 1-4 s pauses that start
  when it spills to the disk swapfile in long sessions come later or not at all.
- **Pipelines the GPU driver refuses are now built again instead of being dropped.** Some
  systems (reported on CachyOS) fail a share of the game's graphics pipelines with
  `VK_ERROR_FEATURE_NOT_PRESENT`. In v8 such a pipeline drew nothing for the rest of the session:
  objects went missing, and grass and leaves stayed white or glowing yellow because the pass that
  colours them never ran. v9 retries a refused pipeline without the pipeline cache, then also
  without the optional extension state, and logs which retry worked.
- **Better logs for this kind of report:** the log now lists the Vulkan layers installed on the
  system (overlays, capture and frame-generation tools sit between the emulator and the driver)
  and, for each refused pipeline, what it asked the driver for. If the problem remains, the
  `Driver refused a graphics pipeline` lines in `eden_log.txt` say which part is refused.
- **Checked on the BC-250** with CachyOS's own driver (Mesa 26.2.6 from a CachyOS container) and
  an empty shader cache. That driver did not refuse any pipeline here, so the retry was tested by
  forcing every third pipeline to fail first: every one was built on the first retry and Hyrule
  Field rendered correctly. Castle route: 53.7 screen fps, same as v8 within run-to-run noise.
- **Known, same as v8:** with an empty shader cache (first start, or after deleting it) the
  scene can look washed out or white for up to ~40 s after loading, and new areas can show white
  leaves for a few seconds, while their shaders compile in the background. It goes away once
  they're built and doesn't come back on later starts.
- New diagnostics: `EDEN_NX2_KEPT_PIPELINES` (how many built pipelines stay alive), a "Built
  graphics pipelines" log line, `EDEN_NX2_TEST_PIPELINE_FAILURE=N` (fails every Nth pipeline's
  first attempt, to test the retry).


### v8 — 2026-11-13: smoother open areas (14 upstream speed-ups)

- **14 Lichii commits cherry-picked onto v7**, the ones that make the GPU threads and the CPU JIT
  cheaper: cheaper reports and fences (#1515, #1516), page protection outside the cache lock
  (#1518), reused command-list copies (#1520), more fast draws (#1519, #1521), list-fed macro
  calls without waiting (#1486), back-thread micro-cuts (#1586), 3D state writes sent as
  register blocks (#1585), faster JIT register allocation and x86-64 code generation (#1517,
  #1531, #1570), plus the two follow-up fixes (#1591, #1592).
- **Hyrule Field** (first 3 minutes, 3 runs each against v7): 3.4-5.5 repeated frames/s instead
  of 5.9-9.0, 17-41 frames over 40 ms per minute instead of 32-65, game 29.3-29.6 fps instead of
  28.3-29.3. **Castle route:** 53.9-55.0 screen fps (v7 52.9-53.5), entry freeze 2.8-2.9 s,
  same GPU memory.
- **The installer runs the release in a small Fedora 42 container** (`lichii-bc250-runtime`,
  created in under a minute, only the GPU driver and system libraries). Run directly on Bazzite
  the same program held about 1.4 GB more memory (title screen 4.1 vs 2.5 GB, Castle Town peak
  5.5 vs 4.0 GB); a 33-minute session that way filled RAM and swap and locked up the console.
  `--native` keeps the old behaviour; the uninstaller removes the container too.
- **New optional setup step 8:** a systemd-oomd safety net that closes the game instead of
  letting the console lock up if memory ever runs out.
- **Not taken:** the newest upstream builds as a whole. Merging Lichii build 196 and the 35
  commits after it lengthened the Castle Town entry freeze (6-11 s instead of 2-3 s) and kept
  ~500 MB more GPU memory there; that merge is kept on branch `exp/v8-full-merge` for later.


### v7 — 2026-11-12: shorter freezes in big areas, prebuilt releases

- **Prebuilt releases.** Pushing a `v*` tag builds the PGO emulator on GitHub (Ubuntu 24.04,
  libraries bundled, the system's own Vulkan loader and GPU driver) and publishes it as a
  release. `bc250-install.sh` now downloads the latest release instead of compiling
  (`--release <tag>` for a specific one, `--build [--pgo]` still builds from source), and the
  launcher runs it directly on the system, without a container. New `bc250-uninstall.sh`
  removes everything the installer added (`--system` also reverts the sysctl and zram steps);
  saves, keys and firmware are never touched.
- **GPU memory in 8 MiB blocks instead of 16** (`EDEN_NX2_VMA_BLOCK_MIB`): the 16 MiB blocks were
  ~19 % empty (464 MiB at the Castle Town peak). With 8 MiB only 22-34 MiB is unused and the GPU
  memory peak is ~400 MB lower; castle route 53.4-55.1 fps (was 53.0-54.4). 4 MiB was slower.
- **Lichii nx2 build 160 merged** (35 commits past what v6 had, incl. #1336/#1337 kept pipelines
  and SPIR-V, #1335, HDR and UI). Kept ours where they overlap: JIT warm-up, frames ahead 2,
  background translation, heap trims, the texture cache's 300-frame minimum age.
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
