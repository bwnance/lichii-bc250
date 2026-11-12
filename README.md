<p align="center">
  <img src="logo.png" alt="lichii-bc250 logo" width="520">
</p>

# lichii-bc250 v6

> **Disclaimer: this project does not support or condone piracy.** No game data, keys,
> firmware or other copyrighted console assets are included, provided or linked here. The
> emulator requires you to dump **your own** game, keys and firmware from **your own**
> console; use it only with backups of content you legally own. Do not open issues about
> obtaining games, keys or firmware — they will be closed.

A [Lichii](https://github.com/zortos293/Lichii) fork optimized for the **AMD BC-250 console**
(GFX1013-class iGPU, RADV, 1080p TV output, 16 GB of memory shared by the CPU and the GPU). The
work targets the BC-250 itself (memory pressure, swap, GPU memory peaks, the container the
emulator runs in), so it helps whatever runs on it. **The Legend of Zelda: Ocarina of Time
(Switch 2)** is the title it has been tuned and measured on so far, so the numbers and the
installer's defaults are for it; other games are planned.

All emulator credit belongs to the Lichii, Eglantine, Eden and yuzu authors; this repo only
carries the BC-250-specific changes on top. GPLv3, like upstream. The repository was called
`oot-bc250` until 2026-11-11; GitHub redirects the old URL.

**What's new:** see [CHANGELOG.md](CHANGELOG.md). In short, v6 removes the stutters: new effects
no longer freeze the picture while their shaders build, and the emulator uses much less memory,
so the system stops swapping the game out in the middle of play.

## How it plays

Measured on the reference console (below), in play sessions through the Deku Tree and Hyrule
Field and in automated loops:

- **About 60 fps on screen.** The game runs at 28-30 fps; FSR3 frame generation adds one frame
  between each pair. When the game dips under 30 the TV shows a frame twice now and then, which
  reads as slight unevenness rather than stutter.
- **No more long hitches in play** (v6): the worst pause after loading went from 1-2.6 s to about
  0.15 s. New effects can appear a frame or two late the first time they show up in a session.
- **Loading an area** can still pause for about a second; the first visit to a big area (Castle Town)
  for 2-3 s.
- **The very first boot** of the game shows a black screen for 3-5 minutes (see step 5).

## Setup in five steps

You need a BC-250 running **Bazzite** with the BC-250 patches (the
[62fixolab images](https://github.com/62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images)
are what the reference console uses), a controller, and your own game dump, keys and firmware.
Do everything on the BC-250 itself (Desktop Mode, or over ssh); commands with `sudo` ask for
your password. Each step ends with a **Check** so you know it worked.

### Step 1: prepare the BC-250 (once)

These system changes are what the measured performance assumes. They are outside the emulator
and survive its updates.

1. **Give the system more RAM: UMA carve-out 512 MB.** The BC-250 reserves part of its 16 GB
   for the GPU; the stock reservation leaves too little for the game. The setting lives in the
   board's CMOS (it survives OS reinstalls) and is written with
   [bc250_memcfg](https://github.com/fanoush/bc250_memcfg) (build it from source as its README
   says):

   ```sh
   sudo bc250memcfg UMA_SIZE 512
   sudo systemctl reboot
   ```

   **Check:** `free -m` shows about 15 GB of total memory, and
   `cat /sys/class/drm/card*/device/mem_info_vram_total` shows `536870912`.

2. **Stop the system from swapping the game out early: swappiness 10.** Bazzite ships
   `vm.swappiness=180`, which on this board pushes the game's memory to swap while RAM is still
   free and causes multi-second freezes. The file name must sort after Bazzite's
   `/usr/lib/sysctl.d/65-memory.conf`:

   ```sh
   printf 'vm.swappiness = 10\n' | sudo tee /etc/sysctl.d/99-bc250-swappiness.conf
   sudo sysctl --system
   ```

   **Check:** `cat /proc/sys/vm/swappiness` shows `10`, also after a reboot.

3. **Keep memory defragmented: compaction proactiveness 100.** The GPU driver asks for memory in
   2 MB blocks; when memory is fragmented the kernel frees space by swapping the game out, even
   with gigabytes of RAM free, and the game stalls when it needs that memory back. Background
   compaction prepares those blocks instead (in a Deku Tree session it cut the 10-second windows
   with drops from 69% to 43%):

   ```sh
   printf 'vm.compaction_proactiveness = 100\n' > /tmp/compaction.conf
   sudo install -m 644 /tmp/compaction.conf /etc/sysctl.d/99-bc250-compaction.conf
   sudo sysctl --system
   ```

   **Check:** `cat /proc/sys/vm/compaction_proactiveness` shows `100`, also after a reboot.

4. **Keep 1.5 GB of RAM free ahead of time: watermark scale factor 1000.** A big area load needs
   gigabytes of GPU memory at once (Ocarina's Castle Town: about 3 GB in 30 s). With Bazzite's
   default (125) the kernel keeps only ~190 MB free, so every one of those allocations waits while
   the kernel compresses other memory into swap: a 10-14 s freeze on the first visit. With 1000 the
   kernel's background thread keeps ~1.5 GB free, and the same entry freezes for 2-3 s:

   ```sh
   printf 'vm.watermark_scale_factor = 1000\n' > /tmp/watermark.conf
   sudo install -m 644 /tmp/watermark.conf /etc/sysctl.d/99-bc250-watermark.conf
   sudo sysctl --system
   ```

   **Check:** `cat /proc/sys/vm/watermark_scale_factor` shows `1000`, also after a reboot.

5. **Swap: a larger zram plus a disk swapfile as a safety net.** Bazzite already has zram
   (compressed swap in RAM), sized at half of RAM (7.4 GB here). Long sessions in big areas filled
   it, and swapping to disk then froze the game for up to 27 s. Make zram three quarters of RAM
   (11 GB here; takes effect after a reboot):

   ```sh
   sudo sed -i 's#^zram-size *=.*#zram-size = min(ram * 3 / 4, 16384)#' /etc/systemd/zram-generator.conf
   ```

   A 16 GB swapfile on disk keeps a long session from running out of memory outright. `/var` is
   btrfs, which needs its own subvolume for a swapfile:

   ```sh
   sudo btrfs subvolume create /var/swap
   sudo btrfs filesystem mkswapfile --size 16g /var/swap/swapfile
   sudo swapon --priority 10 /var/swap/swapfile
   echo '/var/swap/swapfile none swap defaults,pri=10 0 0' | sudo tee -a /etc/fstab
   ```

   **Check:** `swapon --show` lists zram (priority 100, about 11 GB after the reboot) and the swapfile
   (priority 10).

6. **Optional: a larger GPU memory limit.** The game's GPU memory peaks around 5 GB during an
   area load, under the kernel's default limit (half of RAM) but not by much:

   ```sh
   sudo rpm-ostree kargs --append-if-missing=ttm.pages_limit=3145728 \
       --append-if-missing=ttm.page_pool_size=3145728
   sudo systemctl reboot
   ```

   **Check:** `cat /proc/cmdline` contains `ttm.pages_limit=3145728`.

7. **Optional: all 8 CPU cores, 40 GPU compute units, GPU clock 500-2000 MHz.** The reference
   console uses these (set with the BC-250 community tools and the image's
   `cyan-skillfish-governor-smu` config). They help a little; the steps above matter more.
   2000 MHz is above the image's default of 1850: watch your temperatures.

   **Check:** `nproc` shows `16` with all 8 cores.

### Step 2: put your keys and firmware in place

Dump them from your own console, then copy them where the emulator expects them:

- keys: `~/.local/share/eden/keys/` (`prod.keys`, `title.keys`);
- firmware: `~/.local/share/eden/nand/system/Contents/registered/`.

**Check:** both folders exist and are not empty.

### Step 3: install

Download the prebuilt release (no compiling, a few minutes):

```sh
git clone https://github.com/lethevimlet/lichii-bc250.git
cd lichii-bc250
./tools/bc250/bc250-install.sh
```

It downloads the latest release package from GitHub (built with Lichii's performance profile on
Ubuntu 24.04; it runs on Bazzite and CachyOS and uses the system's own GPU driver), unpacks it
to `~/Applications/lichii-bc250/lichii`, and installs the launcher
`~/Applications/lichii-bc250/lichii-bc250`, which sets the BC-250 tuning, plus the game settings
`~/Applications/lichii-bc250/oot.ini` (frame generation, the presentation queue, the Xbox 360
controller mapping, and so on). `--release v7` picks a specific release.

**Build it yourself instead** (30-60 minutes the first time, needs `distrobox`):

```sh
./tools/bc250/bc250-install.sh --build --pgo
```

This creates a Fedora 42 container called `lichii-bc250-build` (the system itself stays
untouched), installs the build tools in it, downloads LLVM 23 once with `--pgo` (~2 GB, of which
~600 MB is kept in `~/.local/share/lichii-bc250/llvm23`) and builds `eden-cli` with Lichii's
performance profile, which is about 10% faster. Leave `--pgo` out to use the container's own
compiler.

**Check:** the installer ends with `Installed.` and the launch command.

### Step 4: add the game to Steam (optional)

To start the game from Gaming Mode with a controller, register it as a non-Steam game. Steam
must be closed for this (it rewrites its shortcut file otherwise): switch to Desktop Mode, quit
Steam, then run:

```sh
./tools/bc250/bc250-install.sh --with-shortcut --game "/path/to/your/Ocarina of Time dump"
```

The second run downloads the package again (or reuses your build with `--build`) and adds the shortcut. Start Steam again: the game
is in your library under **Non-Steam**.

Without Steam, launch it directly:

```sh
~/Applications/lichii-bc250/lichii-bc250 -f -c ~/Applications/lichii-bc250/oot.ini \
  -g "/path/to/your/Ocarina of Time dump"
```

**Check:** the game starts (see step 5 for the first boot).

### Step 5: the first launch

- **Connect the controller before you start the game** (an Xbox 360 wireless receiver is the
  tested setup). It also reconnects if it drops out mid-game.
- **The first boot stays black for 3-5 minutes** while the shader pipelines are prepared. This
  is normal and happens once per game version and emulator build; later boots are much faster.
  New areas hitch a little the first time you visit them, for the same reason.
- **The first minute in each area is rougher** than the rest (see "How it plays").

## Updating

```sh
cd lichii-bc250
git pull
./tools/bc250/bc250-install.sh            # or: --build --pgo if you build it yourself
```

Your `oot.ini` is kept (controls and your own changes), but the installer brings its frame
generation settings up to date. A Steam shortcut made earlier keeps working.

## Uninstalling

```sh
./tools/bc250/bc250-uninstall.sh            # launcher, package, Steam shortcut, build container
./tools/bc250/bc250-uninstall.sh --system   # also reverts the sysctl and zram steps (sudo)
```

Close Steam first if you want the shortcut removed (Steam rewrites its shortcut file otherwise).
Your saves, keys, firmware and shader caches in `~/.local/share/eden` are never touched; the disk
swapfile and kernel arguments are left in place, and the uninstaller prints how to remove them.

## Settings worth knowing

All of these are in `oot.ini`; every value needs its `<key>\default=false` line next to it, or
the emulator ignores it.

- **Frame generation** (`frame_gen=true`, FSR3, multiplier 2, `frame_gen_target_rate=0`): one
  generated frame between every two game frames, ~60 fps on screen from a ~30 fps game.
  Don't set the target rate to 60: the emulator then generates two frames per game frame and
  the game slows to 20 fps.
- **Presentation queue** (`frame_gen_queue_target=1`): four frames waiting for the TV instead of
  three, which smooths delivery. `0` goes back to three.
- **Max Resolution add-on** (on): renders the scene at full 1080p. Without it the image is
  smaller and upscaled, which looks soft on a TV; it costs no measurable fps here.
- **Dynamic FPS add-on** (on): keeps the game at normal speed when the frame rate dips. Without
  it the game runs in slow motion below 30 fps.
- **Controllers:** the template carries the Xbox 360 receiver mapping. A different pad needs its
  own `player_0_*` lines in `[Controls]` (or configure it once in a GUI build and copy the
  block over).
- **Shader cache:** `~/.cache/eden/shader/0400486024dec000/` for Ocarina of Time. A cache from
  an earlier run shortens the first boot; it does not change frame rates.

## Reference console

The numbers above were measured on this setup (step 1 with all the optional items):

| Setting | Value |
|---|---|
| OS | Bazzite (62fixolab BC-250 image), Gaming Mode at 1920x1080 |
| Memory | 16 GB total, UMA carve-out 512 MB (~15.2 GB system RAM) |
| Swap | zram (zstd, 3/4 of RAM) plus a 16 GB disk swapfile, `vm.swappiness=10`, `vm.compaction_proactiveness=100`, `vm.watermark_scale_factor=1000` |
| CPU | 8 cores / 16 threads (stock boots with 6 cores) |
| GPU | 40 compute units, governor 500-2000 MHz |
| GPU memory limit | `ttm.pages_limit=3145728` (12 GB) |

Things that made no difference on this board, so you can skip them: a lower internal
resolution or a smaller texture cache budget, pinning the GPU clock to maximum, `lz4` instead of
`zstd` for zram (worse: it compresses less), the Fritchii v5 builds (tuned for desktop GPUs,
slower here), and Mailbox or FIFO-relaxed present modes.

## What this fork changes

<details>
<summary>Technical summary (details per version in CHANGELOG.md)</summary>

1. **AMD performance fixes from Lichii PR #573, extended to RADV.** Upstream only enabled them
   for AMD's Windows driver; the BC-250 runs Mesa's RADV:
   - query-cache copies no longer block on slots where no query ended (removes Ocarina's
     occlusion-culling stalls); since build 150 this is upstream's wait-on-last copy (#679),
     extended to RADV, plus a non-blocking host read of query results;
   - already-satisfied semaphore acquires skip the split GPU thread's drain;
   - native submission budget of 512 draws on RADV;
   - large texture unswizzles split over helper threads;
   - the Kokiri Forest compute shader builds unoptimized (1.3-4 s stalls on AMD otherwise);
   - async draw discard defaults on for RADV (new pipelines no longer freeze the game).
2. **Task/mesh shader fallback** (upstream PR #569) with a narrower barrier, empty-draw skip and
   smaller arenas: the BC-250's GPU has no `VK_EXT_mesh_shader`, so without it Ocarina's foliage
   and building walls are missing.
3. **Memory work for a 16 GB shared-memory board:** staging buffers in 8 MiB steps, ASTC
   textures re-compressed a few layers at a time, a texture cache that keeps recently used
   textures, capped compute bindings, smaller mesh arenas, `MADV_COLD` instead of
   `MADV_PAGEOUT`.
4. **Frame pacing:** the game runs two frames ahead of the GPU threads, GPU threads pinned to
   their own cores, frame generation always 2x with a four-frame presentation queue.
5. **Containers:** controllers reconnect inside the distrobox (SDL uses inotify instead of
   udev there).
6. **Diagnostics** (all off unless their variable is set): stutter trace, GPU thread profile, a
   Chrome-trace timeline of the GPU threads (`EDEN_NX2_TIMELINE`), on-screen repeat counts in the
   log, GPU memory peak dumps, command-list round-trip timing.

</details>

## Building by hand

The installer is the supported path. To build without it (tested on Fedora 42 with clang;
`src/audio_core/out/` must be present):

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_QT=OFF -DYUZU_CMD=ON -DENABLE_WEB_SERVICE=OFF -DYUZU_ROOM=OFF \
  -DYUZU_TESTS=OFF -DBUILD_TESTING=OFF -DENABLE_WERROR=OFF -DENABLE_UPDATE_CHECKER=OFF \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build build --target eden-cli --parallel 4
```

For the PGO build by hand, see "Building with PGO" in [CHANGELOG.md](CHANGELOG.md#building-with-pgo).

**Base:** Lichii `nx2` build 150 (`17baed716d`) plus selected build 160 commits and this fork's
changes. Data stays in the Eden folders (`~/.local/share/eden`, `~/.config/eden`,
`~/.cache/eden`).
