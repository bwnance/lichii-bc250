# BC-250 upstream review — 2026-11-08

> **Historical snapshot.** Since 2026-11-11 this fork is based on Lichii build 150, which
> includes many of the candidates below (#679, #778, #858, #949, #1056). See the README changelog
> for what the fork carries now.

Compared against `68495dc410` of this fork. This is a research snapshot, not a claim
that any candidate improves BC-250 performance. Fritchii 4.1 is a Windows x64
prerelease tested upstream on an RTX 4080; BC-250 uses Linux and RADV GFX1013.

## Fritchii

The [4.1 release](https://github.com/Frizti/Fritchii/releases/tag/fritchii-v4.1)
is a settings and cache-import hotfix for [v4](https://github.com/Frizti/Fritchii/releases/tag/fritchii-v4).
Its source branches surveyed were `hotfix/v4.1` (`f6d42b8715`), `nx2`
(`f66ea633db`), `oot-gather-fix` (`18c6280c03`) and `test/no-sky-fold`
(`36e8c6b7d4`), plus open PRs. Version 4.1 offers a Windows binary, not a Linux
one; [PR 15](https://github.com/Frizti/Fritchii/pull/15) fixes Linux compilation
and adds Linux thread pinning. The reported pinning results are from a 9950X3D
and RTX 3080; benefit on BC-250's different topology is unknown. Thread affinity
must respect the process's allowed CPU set and should be evaluated with repeated
frame-time measurements before enabling it.

The `nx2` tip adds a README message beyond the 4.1 hotfix. `test/no-sky-fold`
is an older experimental branch with a shader-folding revert used to investigate
flashes; it is not a newer performance branch. `oot-gather-fix` is an ancestor
of 4.1, preceding its final settings and cache-import changes.

* The v4 matrix-unit speedups target RTX and RDNA3/4 hardware, not this GFX1013.
  NVIDIA DLSS and the Windows updater do not apply here.
* The wider table-pointer pool fix (Lichii #351), query DMA wait (#215),
  prebuilt-pipeline eviction protection (#550), and mesh fallback (#569) already
  have equivalents or the original commits in this fork. Do not port them twice.
* Fritchii commit [`d603d98bb3`](https://github.com/Frizti/Fritchii/commit/d603d98bb33d20fd6b3a48845b83abd2fc63f183)
  substitutes a null texture when a handle word is identified as a storage pointer.
  It reportedly reduces water flicker on the author's machine but is an approximate
  workaround for a per-pixel handle, not proof of correct lighting. Check the
  affected shader and visuals before adopting it.
* Fritchii [PR 13](https://github.com/Frizti/Fritchii/pull/13) supplies Linux
  display refresh to that fork's host pacer. This fork has no `HostPacer` or
  `HOST_PACE` symbol, so this is not a standalone patch here. A larger pacing
  port would need gamescope refresh and frame-generation compatibility testing.
* Fritchii's combined AMD changes (#679) deserve a change-by-change comparison;
  some AMD fixes have already been independently ported here. Its release notes
  explicitly say the v4 AMD fixes were not tested by that author on AMD hardware.

## Other upstream candidates

* [Lichii #642](https://github.com/zortos293/Lichii/pull/642): account for mesh
  fallback auxiliary buffers in the descriptor-set storage-buffer limit. This
  protects correctness on devices near the limit; it is not a claimed speedup.
* [Lichii #718](https://github.com/zortos293/Lichii/pull/718): retain up to four
  occlusion-query banks, with a companion prefix-scan boundary fix. This targets
  observed OoT query windows, but increases retained query resources and needs
  visual and resource testing on this GPU.
* [Lichii #699](https://github.com/zortos293/Lichii/pull/699): reuse a compatible
  active render pass after a deferred clear. Include its active-pass follow-up;
  the original alone can record draws outside a render pass. Test against mesh
  fallback pass breaks and graphics correctness; no BC-250 speedup is established.
* [Eglantine #714](https://github.com/Djihads80/Eglantine/pull/714): rely on
  Mesa's pipeline cache on RADV when enabled. Test cold and warm starts and cache
  eviction under controlled conditions before changing cache ownership.
* [Lichii #761](https://github.com/zortos293/Lichii/pull/761): speculative mesh
  prewarming has a large dependency stack and unproven coverage for compute mesh
  fallback. The published tests do not demonstrate a BC-250 benefit.

## Integration status

The local branch and Eglantine `nx2` (`74db237124`) have diverged by 287 and
196 commits respectively. A non-destructive `git merge-tree` preview reported
conflicts across roughly 100 files, including shader lowering, buffer caching,
Vulkan and mesh-related files. The repository's `AGENTS.md` requires merging
Eglantine `nx2` before fixing an issue; this is a substantial integration project,
not a safe automatic update. No upstream change in this review has been merged,
built or deployed. The current installed build is not a validation of these PRs.

## Frame pacing follow-up

At the later comparison Eglantine `nx2` was `66bfbc5321` and Lichii `nx2`
was `bf48fe92cc`; Sharkiix `nx2` remained `4243c082f5`. Fritchii 4.1's
host pacer requires asynchronous presentation, supported Vulkan present-wait,
known refresh and compatible present settings; it explicitly disables itself
when frame generation is active. Its Linux refresh PR is not the pacer itself.
The current BC-250 build has a separate frame-generation *planner*: it chooses
how many frames to generate, but does not provide the host pacer's display-grid
synchronization. A host pacer cannot raise guest simulation FPS, and enabling
both mechanisms without coordinating them risks extra latency or stalls.

Lichii's `capy/egla42-host-pacer-candidate` (`caeb2954c1`) is an additional
experimental port to examine; it includes a live A/B guard and tests. Its ancestry
is divergent too and it is not evidence that BC-250 frame generation is supported.
Eglantine `nx2` moved during review: the current comparison is 287 local-only
and 231 upstream-only commits, and the merge preview still has extensive conflicts.
The next implementation step is the required upstream integration, followed by a
separately switched candidate and tests. Compare guest frame times and host present
intervals with frame generation both off and on, at the same scene and settings;
check latency, swapchain recreation and present-wait timeout behavior. The repository
instructions require the owner to launch the emulator for live tests.

For a sustained 30 guest FPS, the budget is 33.3 ms per game frame. The README's
17–21 FPS world report corresponds to roughly 48–59 ms per frame, but is not a
repeatable profile and does not identify the bottleneck. Frame generation adds
presented frames and does not by itself bring guest rendering to 30 FPS.

One focused candidate for investigation is [Lichii #802](https://github.com/zortos293/Lichii/pull/802)
(`9b13396bda`): avoid copying overlapping native uniform-bank ranges repeatedly
within a frame. Its reported Castle Town improvement was on an i5-10400 and RTX
3060, with a larger patch stack; that exact PR received a syntax check but was not
game-tested. Establish whether uniform uploads are hot on the BC-250 before porting.
Use a repeatable owner-launched scene and compare uninstrumented frame times with
short GPU-thread profiles; the profile reports host-thread work, not GPU hardware
execution time. Compare frame generation and resolution separately, track clocks
and temperatures, and A/B the existing wide mesh barrier with image checks.

### Initial BC-250 tests

The owner subsequently authorized bounded automated launches. From the first save,
after about 130 s of warm-up, a stationary 30 s sample measured 25.05 guest FPS
with frame generation configured on and 24.96 FPS with it disabled in a temporary
configuration. This is one sample per configuration, not evidence of equivalence
throughout gameplay. The configured setting was restored after testing.

A 69.7 s wall-clock stick recording was converted to 1,744 guest frames using an
assumed 25 FPS. Two replays starting at the same save took 86.36 and 86.84 seconds,
but screenshots showed different final positions. The runs compared the default
mesh barrier with `EDEN_NX2_MESH_WIDE_BARRIER=1`; the differing routes invalidate
the comparison. Stationary pre-route windows in both were approximately 40 ms per
guest present; they do not establish a barrier performance or correctness result.
Replay must be improved and validated before using it for moving-scene A/B tests.

The debug-server sampler reports Windows-only on this Linux build. A 15 s `/proc`
CPU-time sample in the stationary view measured each of six guest CPU threads at
roughly 47–51% of one logical CPU, GPUBack at 41%, and GPU at 36%. This identifies
neither hot functions nor actual GPU utilization. More targeted profiling is needed.
The test harness lives under `/tmp`, uses an eight-minute watchdog and direct CPU
and GPU temperature sensors, and restores the launcher on normal exit. It is not
yet a complete autonomous benchmark. The user's recording, save backup, and run
logs stay on the console, outside the repository.

### Shader compilation follow-up

Lichii [#579](https://github.com/zortos293/Lichii/pull/579) reports a reduction
from 29.2 s to 11.9 s across ten compute-pipeline builds in one Windows/RTX 4090
walk by retaining shared shader function calls. This is not a BC-250 result, and
the specific pinned message was not verified. Eglantine's targeted
[`9a362357a2`](https://github.com/Eglantine-Community/Eglantine/commit/9a362357a27787bdd0dadf1186c927d655cc8994)
is a different helper-specific implementation, likewise not tested here.

Lichii [#841](https://github.com/zortos293/Lichii/pull/841) removes an obsolete
boot-cache filter that discards task/mesh pipelines on devices without native
mesh shaders. Local `vk_pipeline_cache.cpp:1020` still has that filter despite
having compute mesh fallback. This is a focused candidate for fewer repeated
builds, not a demonstrated steady-FPS gain. Two existing BC-250 session logs
contain 115 and 118 runtime graphics-pipeline hashes, with 88 shared between
them; those log lines do not identify mesh stages and do not prove the filter
caused the repetitions. The upstream fix has not been built or tested here.

The Eglantine `nx2` tip `78743f30c2` was merge-previewed against this fork;
it still conflicts across approximately 100 files. The repository requires that
integration before implementing a fix. Do not silently resolve graphics conflicts
or deploy a merged build without validation.

## Correction to prior cache-pack report

The earlier report overstated its evidence. `Uncached storage pointer classification`
means a cached file environment lacked a requested classification; the log alone
does not prove a driver difference caused it, or quantify how many entries were
rebuilt. One instrumented run logged its first guest present at 210 seconds;
the later uninstrumented run's missing `DKB frame present` lines cannot prove no
frames were presented. Tests used a temporary smoke wrapper rather than the normal
launcher, and did not establish the pack's marginal value or correctness. The
pre-sync cache was restored. Any future comparison should use the same wrapper,
instrumentation, save/scene and controlled cache state, preserving backups.
