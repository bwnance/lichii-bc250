# Shared JIT code between emulated cores (v16 work in progress)

## Why

Each of the six emulated CPU cores has its own dynarmic `A64::Jit`: its own code buffer
(`BlockOfCode`, 512 MiB reserved), emitter tables (block descriptors, patch locations, exit
stubs, fastmem patch info, block ranges) and fast-dispatch table. They all translate the same
game code. Measured in Ocarina of Time:

- 73% of compiles repeat a block another core already has (castle route, 2026-11-13).
- After a 90-100 minute session: translated code ~1.0 GB and translator tables ~0.7 GB
  (heaptrack, play17; smaps, play16/play18), growing as new areas are visited and never freed.

One shared copy should save roughly 1 GB late in a session and most of the compile work in new
areas.

## What ties emitted code to one core today

1. `conf.callbacks` (the core's `UserCallbacks` object) is baked into every callback call as an
   immediate `this` (`Devirtualize<...>(conf.callbacks)` -> `ArgCallback`): memory read/write
   fallbacks, exclusive writes, SVC, exceptions, cache operations, CNTPCT, ticks.
2. `conf.tpidr_el0` / `conf.tpidrro_el0` pointers are baked as immediates (a64_emit_x64.cpp).
3. Exclusive-monitor pointers for this core (`GetExclusiveMonitorAddressPointer/ValuePointer(
   global_monitor, processor_id)`) and the "clear the other cores" loop that skips
   `processor_id` (emit_x64_memory.h / .cpp.inc).
4. The run-code prelude (`GenRunCode`) calls `GetCurrentBlockThunk` with the core's
   `Jit::Impl*` and the ticks callbacks with the core's `conf.callbacks`.
5. Each Jit has its own `BlockOfCode`, emitter and tables; compilation is unsynchronised.

## Plan

Phase 1, core-agnostic code (still one cache per core, behaviour unchanged):
- Add per-core fields to `A64JitState` (reached through r15 in all emitted code): the
  callbacks object, the `Jit::Impl`, tpidr pointers, the exclusive-monitor address/value
  pointers and the processor id.
- Emit those as loads from `[r15 + offset]` instead of immediates (a state-based callback kind
  next to `ArgCallback`; the function pointer stays an immediate, every core has the same
  callbacks class).
- Check: the same block compiled on two cores gives the same bytes apart from relative branches.

Phase 2, one shared cache:
- One `BlockOfCode` + `A64EmitX64` + tables shared by all A64 Jits that use the same page
  table and config; a global compile lock (cores mostly compile different blocks only at
  startup and in new areas).
- Fast-dispatch tables and RSBs stay per core (they only hold pointers into the shared code).
- Block linking patches shared code that other cores may be running: patch only aligned
  jump slots with single atomic stores, or keep linking per-core-safe.
- Invalidation (`InvalidateCacheRange`, full flushes) becomes stop-the-world: every core is
  halted before code is removed, then all fast-dispatch tables are cleared.
- The fastmem fault handler looks blocks up in the shared tables.

Phase 3, testing: castle and Hyrule routes, then a long owner session with the memory recorder.
Keep a switch (`EDEN_NX2_SHARED_JIT=0`) to fall back to per-core caches.

## Progress

- Phase 1 done (v16 ee9b1ed07d): castle route 56.0 fps (v15 56.6), same 37 known log lines.
- Also on v16: a full flush releases code pages and table memory; `EDEN_NX2_JIT_CACHE_MIB`
  (default 512). Forced 64 MiB: ~120 flushes on the castle route, stable, JIT 315 MB instead of
  ~600, but 38 fps (the per-core hot code is larger than 64 MiB) - a small cap is not useful.

## Phase 2 design notes

- **Linking.** Today a link rewrites up to 23 bytes (`mov rax, pc; mov [pc], rax; jg return` ->
  `jg target` + padding). Another core may be executing those bytes. Shared mode: every
  link site is a single `jcc/jmp rel32` whose rel32 is 4-byte aligned (pad before the
  opcode); unlinked it points at a per-site stub in far code that stores the PC and returns to
  the dispatcher. Linking/unlinking is one aligned 4-byte store. `mov rcx, imm64` sites: align
  the imm64 to 8 bytes, one 8-byte store.
- **Compilation.** One compile mutex around GetBlock's miss path (lookup, translate, emit,
  link). Code is only appended, so other cores keep running.
- **Fastmem faults.** The signal handler looks up `fastmem_patch_info` by rip while another
  core may be appending. Use a preallocated array (reserved address space, entries appended
  in rip order) with an atomic count, so readers never see a reallocation.
- **Recompile after a fastmem fault** (`recompile` entries): compile a new version, relink
  sites to it; the old code stays valid for cores that still hold it (dispatch table, RSB).
- **Invalidation and full flushes.** A shared_mutex held shared by each core while it is
  inside Run(); invalidation halts every core and takes it exclusively, then clears the
  code/tables and every core's fast-dispatch table and RSB.
- **Fast dispatch.** Per-core tables (already read through the JIT state in phase 1); the
  C++ Unpatch path clears every core's table under the exclusive lock.

## Phase 2 results (2026-11-16, v16 79e97248b0 / 8eaac8305a)

Implemented as designed above (`SharedCode` in a64_interface.cpp; atomic link patching in
emit_x64.cpp; per-core dispatch tables in a64_emit_x64.cpp; fastmem spin lock and deferred
recompiles in emit_x64_memory.cpp.inc).

- Castle route, shared: 57.5 fps / 1.4 repeats/s (v15 56.6 / 2.4); second field/town/plaza
  pass 59.9-60 fps. Emulator private memory 2.70 GB vs 3.73 GB (v15) at the same point: JIT
  code 174 MB vs 660 MB, translator tables and other heap 1.65 GB vs 2.31 GB.
- Hyrule long run (10 loops): stable, 59.4-59.9 fps in the valid minutes.
- `EDEN_NX2_SHARED_JIT_TEST_FLUSH=60`: 7 full flushes during the castle route (6-70 MiB of
  shared code each), all completed; each costs a ~1-2 s re-translation hitch (test only).
- `EDEN_NX2_SHARED_JIT=0` (one cache per core): works, 54.7 fps, same log.
- No crashes or new log lines in any run.
