// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

/* This file is part of the dynarmic project.
 * Copyright (c) 2016 MerryMage
 * SPDX-License-Identifier: 0BSD
 */

#include <cstring>
#include <memory>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <map>
#include <mutex>
#include <shared_mutex>
#include <vector>

#include <boost/icl/interval_set.hpp>
#include "common/assert.h"
#include "common/logging.h"
#include "common/nx2_hitch.h"
#include "dynarmic/common/fp/fpcr.h"
#include "dynarmic/common/llvm_disassemble.h"
#include <bit>

#include "dynarmic/backend/x64/a64_emit_x64.h"
#include "dynarmic/backend/x64/a64_jitstate.h"
#include "dynarmic/backend/x64/block_of_code.h"
#include "dynarmic/backend/x64/devirtualize.h"
#include "dynarmic/backend/x64/jitstate_info.h"
#include "dynarmic/common/atomic.h"
#include "dynarmic/frontend/A64/translate/a64_translate.h"
#include "dynarmic/interface/A64/a64.h"
#include "dynarmic/ir/basic_block.h"
#include "dynarmic/ir/opt_passes.h"

namespace Dynarmic::A64 {

using namespace Backend::X64;

static RunCodeCallbacks GenRunCodeCallbacks(A64::UserCallbacks* cb, CodePtr (*LookupBlock)(void* lookup_block_arg), void* arg, const A64::UserConfig& conf) {
    static_cast<void>(arg);
    // The dispatcher reads its Jit::Impl and callbacks from the JIT state (docs/bc250-shared-jit.md).
    return RunCodeCallbacks{
        ArgCallback(LookupBlock, u64{0}).FromState(u32(offsetof(A64JitState, jit_impl)), 0),
        DevirtualizeState<&A64::UserCallbacks::AddTicks>(cb, u32(offsetof(A64JitState, user_callbacks))),
        DevirtualizeState<&A64::UserCallbacks::GetTicksRemaining>(cb, u32(offsetof(A64JitState, user_callbacks))),
        conf.enable_cycle_counting,
        HostCallReturn(conf) ? std::optional<u32>{u32(offsetof(A64JitState, host_stack_base))} : std::nullopt,
    };
}

static std::function<void(BlockOfCode&)> GenRCP(const A64::UserConfig& conf) {
    return [conf](BlockOfCode& code) {
        if (conf.page_table) {
            code.mov(code.r14, std::bit_cast<u64>(conf.page_table));
        }
        if (conf.fastmem_pointer) {
            code.mov(code.r13, *conf.fastmem_pointer);
        }
        if (HostCallReturn(conf)) {
            // A RET compares its target with the frame's [rsp + ABI_SHADOW_SPACE]; with no guest
            // frame that is the first StackLayout word (the spills live in the JIT state), which
            // holds a value no location descriptor has (bits 57-58 are never set in one).
            code.mov(code.qword[code.rsp + ABI_SHADOW_SPACE], -1);
            code.mov(code.qword[code.ABI_JIT_PTR + offsetof(A64JitState, host_stack_base)], code.rsp);
            code.lea(code.rax, code.ptr[code.rsp - HostCallFrameSize * HostCallMaxDepth]);
            code.mov(code.qword[code.ABI_JIT_PTR + offsetof(A64JitState, host_stack_limit)], code.rax);
        }
    };
}

// Largest power of two <= conf.rsb_size, between 8 and A64JitState::RSB_SIZE, minus one.
static size_t RsbPtrMask(const A64::UserConfig& conf) {
    size_t size = A64JitState::RSB_SIZE;
    while (size > 8 && size > conf.rsb_size) {
        size >>= 1;
    }
    return size - 1;
}

static Optimization::PolyfillOptions GenPolyfillOptions(const BlockOfCode& code) {
    return Optimization::PolyfillOptions{
        .sha256 = !code.HasHostFeature(HostFeature::SHA),
        .vector_multiply_widen = true,
    };
}

// Shared JIT code (docs/bc250-shared-jit.md): the cores of a process run one copy of the
// translated code instead of six. EDEN_NX2_SHARED_JIT=0 keeps one cache per core.
static bool SharedJitEnabled(const UserConfig& conf) {
    static const bool enabled = [] {
        const char* value = std::getenv("EDEN_NX2_SHARED_JIT");
        return value == nullptr || std::strcmp(value, "0") != 0;
    }();
    // Atomic linking needs the compact 5/6-byte link sites.
    return enabled && conf.page_table != nullptr && conf.compact_block_exits && !conf.check_halt_on_memory_access;
}

// One code space for every core: below 1 GiB (patch offsets are 30-bit); Ocarina of Time's
// cores had ~170 MiB each after 90 minutes, most of it the same code.
constexpr std::uint32_t SharedCodeCacheSize = 960u << 20;
// Below this much room a full flush is requested for the next point every core is stopped.
constexpr size_t SharedFlushRemaining = size_t{128} << 20;

struct SharedCode {
    SharedCode(const UserConfig& conf_, Jit* jit, CodePtr (*lookup_block)(void*), bool shared_)
        : conf(conf_)
        , shared(shared_)
        , block_of_code(GenRunCodeCallbacks(conf.callbacks, lookup_block, nullptr, conf), JitStateInfo{A64JitState{}, RsbPtrMask(conf)}, conf.code_cache_size, GenRCP(conf))
        , emitter(block_of_code, conf, jit)
        , polyfill_options(GenPolyfillOptions(block_of_code)) {}

    void RequestInvalidation(u64 start_address, size_t length);
    void RequestFullFlush();
    void HaltAll();

    const UserConfig conf;
    const bool shared;
    BlockOfCode block_of_code;
    A64EmitX64 emitter;
    Optimization::PolyfillOptions polyfill_options;

    /// Lookups, compiles and links (the emitter's tables and the code space).
    std::mutex compile_mutex;
    /// Held shared by each core while it runs emitted code; held exclusively to remove code.
    std::shared_timed_mutex run_mutex;
    /// The pending invalidation below.
    std::mutex invalidation_mutex;
    bool invalidate_entire_cache = false;
    boost::icl::interval_set<u64> invalid_cache_ranges;
    std::atomic<bool> invalidation_pending{false};
    bool flush_requested = false;  ///< under compile_mutex
    std::chrono::steady_clock::time_point last_flush = std::chrono::steady_clock::now();
    /// The JIT states of the cores using this code. Lock order: run, compile, invalidation, cores.
    std::mutex cores_mutex;
    std::vector<A64JitState*> cores;
};

static std::shared_ptr<SharedCode> AcquireSharedCode(UserConfig conf, Jit* jit, CodePtr (*lookup_block)(void*)) {
    if (!SharedJitEnabled(conf)) {
        return std::make_shared<SharedCode>(conf, jit, lookup_block, false);
    }
    conf.code_cache_size = SharedCodeCacheSize;
    static std::mutex registry_mutex;
    static std::map<std::pair<const void*, std::uintptr_t>, std::weak_ptr<SharedCode>> registry;
    const std::lock_guard lock{registry_mutex};
    const auto key = std::make_pair(static_cast<const void*>(conf.page_table), conf.fastmem_pointer.value_or(0));
    if (auto existing = registry[key].lock()) {
        return existing;
    }
    auto created = std::make_shared<SharedCode>(conf, jit, lookup_block, true);
    created->emitter.atomic_patching = true;
    created->emitter.request_block_invalidation = [raw = created.get()](u64 pc) {
        raw->RequestInvalidation(pc, 4);
    };
    registry[key] = created;
    LOG_INFO(Core_ARM, "Shared JIT: one {} MiB code cache for every core of the process",
             conf.code_cache_size >> 20);
    return created;
}

struct Jit::Impl final {
public:
    Impl(Jit* jit, UserConfig conf)
        : conf(conf)
        , shared_code(AcquireSharedCode(conf, jit, &LookupBlockThunk))
        , block_of_code(shared_code->block_of_code)
        , emitter(shared_code->emitter)
        , polyfill_options(shared_code->polyfill_options)
    {
        ASSERT(conf.page_table_address_space_bits >= 12 && conf.page_table_address_space_bits <= 64);
        {
            const std::lock_guard compile{shared_code->compile_mutex};
            const std::lock_guard cores{shared_code->cores_mutex};
            // The first core uses the emitter's fast-dispatch table, the others their own.
            if (!shared_code->cores.empty() && conf.HasOptimization(OptimizationFlag::FastDispatch)) {
                own_dispatch_table.resize(emitter.FastDispatchTableEntries());
                emitter.RegisterDispatchTable(own_dispatch_table.data());
            }
            shared_code->cores.push_back(&jit_state);
        }
        SetCoreState();
    }

    ~Impl() {
        const std::lock_guard compile{shared_code->compile_mutex};
        const std::lock_guard cores{shared_code->cores_mutex};
        std::erase(shared_code->cores, &jit_state);
        if (!own_dispatch_table.empty()) {
            emitter.UnregisterDispatchTable(own_dispatch_table.data());
        }
    }

    /// The dispatcher's block lookup; the Jit::Impl comes from the JIT state (jit_impl).
    static CodePtr LookupBlockThunk(void* impl) {
        return static_cast<Jit::Impl*>(impl)->GetCurrentBlock();
    }

    /// The per-core values emitted code reads from the JIT state (docs/bc250-shared-jit.md).
    void SetCoreState() {
        jit_state.user_callbacks = reinterpret_cast<u64>(conf.callbacks);
        jit_state.user_config = reinterpret_cast<u64>(&this->conf);
        jit_state.jit_impl = reinterpret_cast<u64>(this);
        jit_state.tpidr_el0_ptr = reinterpret_cast<u64>(conf.tpidr_el0);
        jit_state.tpidrro_el0_ptr = reinterpret_cast<u64>(conf.tpidrro_el0);
        if (conf.global_monitor) {
            jit_state.exclusive_address_ptr = reinterpret_cast<u64>(GetExclusiveMonitorAddressPointer(conf.global_monitor, conf.processor_id));
            jit_state.exclusive_value_ptr = reinterpret_cast<u64>(GetExclusiveMonitorValuePointer(conf.global_monitor, conf.processor_id));
        }
        jit_state.fast_dispatch_table = own_dispatch_table.empty() ? emitter.FastDispatchTableBase()
                                                                   : reinterpret_cast<u64>(own_dispatch_table.data());
    }

    HaltReason Run() {
        ASSERT(!is_executing);
        PerformRequestedCacheInvalidation(static_cast<HaltReason>(Atomic::Load(&jit_state.halt_reason)));
        is_executing = true;
        HaltReason hr;
        {
            // Code is only removed while no core holds this (PerformRequestedCacheInvalidation).
            const std::shared_lock run_lock{shared_code->run_mutex};
            // TODO: Check code alignment
            const CodePtr current_code_ptr = [this] {
                // RSB optimization
                const u32 new_rsb_ptr = (jit_state.rsb_ptr - 1) & u32(RsbPtrMask(conf));
                if (jit_state.GetUniqueHash() == jit_state.rsb_location_descriptors[new_rsb_ptr]) {
                    jit_state.rsb_ptr = new_rsb_ptr;
                    return CodePtr(jit_state.rsb_codeptrs[new_rsb_ptr]);
                }
                return CodePtr((uintptr_t(GetCurrentBlock()) + 15) & ~uintptr_t(15));
            }();
            hr = block_of_code.RunCode(&jit_state, current_code_ptr);
        }
        PerformRequestedCacheInvalidation(hr);
        is_executing = false;
        return hr;
    }

    HaltReason Step() {
        ASSERT(!is_executing);
        PerformRequestedCacheInvalidation(static_cast<HaltReason>(Atomic::Load(&jit_state.halt_reason)));
        is_executing = true;
        HaltReason hr;
        {
            const std::shared_lock run_lock{shared_code->run_mutex};
            hr = block_of_code.StepCode(&jit_state, GetCurrentSingleStep());
        }
        PerformRequestedCacheInvalidation(hr);
        is_executing = false;
        return hr;
    }

    void ClearCache() {
        shared_code->RequestFullFlush();
    }

    void InvalidateCacheRange(u64 start_address, size_t length) {
        shared_code->RequestInvalidation(start_address, length);
    }

    void Reset() {
        ASSERT(!is_executing);
        jit_state = {};
        SetCoreState();
    }

    void HaltExecution(HaltReason hr) {
        Atomic::Or(&jit_state.halt_reason, static_cast<u32>(hr));
    }

    void ClearHalt(HaltReason hr) {
        Atomic::And(&jit_state.halt_reason, ~static_cast<u32>(hr));
    }

    u64 GetSP() const {
        return jit_state.sp;
    }

    void SetSP(u64 value) {
        jit_state.sp = value;
    }

    u64 GetPC() const {
        return jit_state.pc;
    }

    void SetPC(u64 value) {
        jit_state.pc = value;
    }

    u64 GetRegister(size_t index) const {
        if (index == 31)
            return GetSP();
        return jit_state.reg.at(index);
    }

    void SetRegister(size_t index, u64 value) {
        if (index == 31)
            return SetSP(value);
        jit_state.reg.at(index) = value;
    }

    std::array<u64, 31> GetRegisters() const {
        return jit_state.reg;
    }

    void SetRegisters(const std::array<u64, 31>& value) {
        jit_state.reg = value;
    }

    Vector GetVector(size_t index) const {
        return {jit_state.vec.at(index * 2), jit_state.vec.at(index * 2 + 1)};
    }

    void SetVector(size_t index, Vector value) {
        jit_state.vec.at(index * 2) = value[0];
        jit_state.vec.at(index * 2 + 1) = value[1];
    }

    std::array<Vector, 32> GetVectors() const {
        std::array<Vector, 32> ret;
        static_assert(sizeof(ret) == sizeof(jit_state.vec));
        std::memcpy(ret.data(), jit_state.vec.data(), sizeof(jit_state.vec));
        return ret;
    }

    void SetVectors(const std::array<Vector, 32>& value) {
        static_assert(sizeof(value) == sizeof(jit_state.vec));
        std::memcpy(jit_state.vec.data(), value.data(), sizeof(jit_state.vec));
    }

    u32 GetFpcr() const {
        return jit_state.GetFpcr();
    }

    void SetFpcr(u32 value) {
        jit_state.SetFpcr(value);
    }

    u32 GetFpsr() const {
        return jit_state.GetFpsr();
    }

    void SetFpsr(u32 value) {
        jit_state.SetFpsr(value);
    }

    u32 GetPstate() const {
        return jit_state.GetPstate();
    }

    void SetPstate(u32 value) {
        jit_state.SetPstate(value);
    }

    void ClearExclusiveState() {
        jit_state.exclusive_state = 0;
    }

    bool IsExecuting() const {
        return is_executing;
    }

    std::string Disassemble() const {
        const size_t size = reinterpret_cast<const char*>(block_of_code.getCurr()) - reinterpret_cast<const char*>(block_of_code.GetCodeBegin());
        auto const* p = reinterpret_cast<const char*>(block_of_code.GetCodeBegin());
        return Common::DisassembleX64(p, p + size);
    }

    PrecompileResult Precompile(std::uint64_t location, std::size_t keep_free) {
        ASSERT(!is_executing);
        const std::lock_guard compile{shared_code->compile_mutex};
        const IR::LocationDescriptor descriptor{location};
        if (A64::LocationDescriptor{descriptor}.SingleStepping()) {
            return PrecompileResult::Unreadable;
        }
        if (emitter.GetBasicBlock(descriptor)) {
            return PrecompileResult::Present;
        }
        // Unlike GetBlock, never clears the cache to make room. GetBlock assumes a block fits in
        // MINIMUM_REMAINING_CODESIZE, so keep_free is left after this one.
        if (block_of_code.SpaceRemaining() < MINIMUM_REMAINING_CODESIZE + keep_free) {
            return PrecompileResult::Full;
        }
        block_of_code.EnsureMemoryCommitted(MINIMUM_REMAINING_CODESIZE);
        if (!CompileBlock(descriptor, true)) {
            return PrecompileResult::Unreadable;
        }
        ASSERT(block_of_code.SpaceRemaining() >= keep_free);
        return PrecompileResult::Compiled;
    }

    size_t CodeCacheUsed() const {
        return size_t(reinterpret_cast<const char*>(block_of_code.getCurr()) - reinterpret_cast<const char*>(block_of_code.GetCodeBegin()));
    }

private:

    IR::LocationDescriptor GetCurrentLocation() const {
        return IR::LocationDescriptor{jit_state.GetUniqueHash()};
    }

    CodePtr GetCurrentBlock() {
        if (conf.counters) {
            ++conf.counters->block_lookups;
        }
        return GetBlock(GetCurrentLocation());
    }

public:
    bool PrecompileBlock(u64 location) {
        if (is_executing) {
            return false;
        }
        const IR::LocationDescriptor descriptor{location};
        {
            const std::lock_guard compile{shared_code->compile_mutex};
            if (emitter.GetBasicBlock(descriptor)) {
                return false;
            }
            if (block_of_code.SpaceRemaining() < (size_t{256} << 20)) {
                return false;
            }
        }
        static_cast<void>(GetBlock(descriptor));
        return true;
    }

private:

    CodePtr GetCurrentSingleStep() {
        return GetBlock(A64::LocationDescriptor{GetCurrentLocation()}.SetSingleStepping(true));
    }

    static constexpr size_t MINIMUM_REMAINING_CODESIZE = 1 * 1024 * 1024;

    CodePtr GetBlock(IR::LocationDescriptor descriptor) {
        std::unique_lock compile{shared_code->compile_mutex};
        if (auto block = emitter.GetBasicBlock(descriptor))
            return block->entrypoint;
        // Fritchii hitch attribution (2026-11-10): new game code compiled while the game waits.
        // Each emulated core has its own JIT (fable52_answer_12): count code another core has.
        const ::Common::Nx2Hitch::Scope hitch_timed{
            ::Common::Nx2Hitch::CompileCause(descriptor.Value(), conf.processor_id)};

        if (shared_code->shared) {
            // EDEN_NX2_SHARED_JIT_TEST_FLUSH=<seconds>: a full flush that often (tests the
            // stop-every-core path, which games rarely take).
            static const std::chrono::seconds test_flush_interval{[] {
                const char* value = std::getenv("EDEN_NX2_SHARED_JIT_TEST_FLUSH");
                return value != nullptr ? std::strtoll(value, nullptr, 10) : 0LL;
            }()};
            if (test_flush_interval.count() > 0 && !shared_code->flush_requested) {
                const auto now = std::chrono::steady_clock::now();
                if (now - shared_code->last_flush >= test_flush_interval) {
                    shared_code->flush_requested = true;
                    shared_code->RequestFullFlush();
                }
            }
            // Other cores run this code: it can only be flushed once they are all stopped.
            if (block_of_code.SpaceRemaining() < SharedFlushRemaining && !shared_code->flush_requested) {
                shared_code->flush_requested = true;
                LOG_INFO(Core_ARM, "Shared JIT code cache nearly full ({} MiB used): flushing it",
                         CodeCacheUsed() >> 20);
                shared_code->RequestFullFlush();
            }
            ASSERT_MSG(block_of_code.SpaceRemaining() >= MINIMUM_REMAINING_CODESIZE,
                       "Shared JIT code cache full before its flush");
        } else if (block_of_code.SpaceRemaining() < MINIMUM_REMAINING_CODESIZE) {
            // Immediately evacuate cache. With a code cache smaller than a session's code
            // (EDEN_NX2_JIT_CACHE_MIB) this is how a core gives its code and tables back.
            LOG_INFO(Core_ARM, "JIT code cache full on core {}: flushing {} MiB of code",
                     conf.processor_id, CodeCacheUsed() >> 20);
            if (conf.counters) {
                ++conf.counters->cache_clears;
            }
            const std::lock_guard lock{shared_code->invalidation_mutex};
            jit_state.ResetRSB();
            block_of_code.ClearCache();
            emitter.ClearCache();
            shared_code->invalid_cache_ranges.clear();
            shared_code->invalidate_entire_cache = false;
            shared_code->invalidation_pending = false;
        }
        block_of_code.EnsureMemoryCommitted(MINIMUM_REMAINING_CODESIZE);

        // JIT Compile
        const CodePtr entrypoint = CompileBlock(descriptor, false);
        compile.unlock();
        conf.callbacks->BlockCompiled(descriptor.Value());
        return entrypoint;
    }

    /// Translates, optimizes and emits the block. With skip_unreadable, returns nullptr and emits
    /// nothing when an instruction of the block could not be read.
    CodePtr CompileBlock(IR::LocationDescriptor descriptor, bool skip_unreadable) {
        bool readable = true;
        const auto get_code = [this, &readable](u64 vaddr) {
            const std::optional<u32> instruction = conf.callbacks->MemoryReadCode(vaddr);
            readable = readable && instruction.has_value();
            return instruction;
        };
        // LocationDescriptor ctor() does important ops (like tflags) do not skip
        auto const arch_descriptor = A64::LocationDescriptor{descriptor};
        ir_block.Reset(arch_descriptor);
        A64::Translate(ir_block, arch_descriptor, get_code, {conf.define_unpredictable_behaviour, conf.wall_clock_cntpct});
        if (skip_unreadable && !readable) {
            return nullptr;
        }
        Optimization::Optimize(ir_block, conf, polyfill_options);
        if (conf.counters) {
            ++conf.counters->blocks_compiled;
        }
        return emitter.Emit(ir_block).entrypoint;
    }

    void PerformRequestedCacheInvalidation(HaltReason hr) {
        if (Has(hr, HaltReason::CacheInvalidation)) {
            ClearHalt(HaltReason::CacheInvalidation);
        } else if (!shared_code->shared || !shared_code->invalidation_pending.load(std::memory_order_acquire)) {
            return;
        }
        if (!shared_code->invalidation_pending.load(std::memory_order_acquire)) {
            return;
        }
        // Every core must be out of the code: they were all halted with the request. A core
        // that does not come out soon (waiting in a callback for something this core would do)
        // must not block this one; the next Run() tries again.
        std::unique_lock run{shared_code->run_mutex, std::defer_lock};
        const auto wait = Has(hr, HaltReason::CacheInvalidation) ? std::chrono::milliseconds(20)
                                                                 : std::chrono::milliseconds(1);
        if (!run.try_lock_for(wait)) {
            return;
        }
        const std::lock_guard compile{shared_code->compile_mutex};
        const std::lock_guard lock{shared_code->invalidation_mutex};
        if (!shared_code->invalidate_entire_cache && shared_code->invalid_cache_ranges.empty()) {
            shared_code->invalidation_pending = false;
            return;
        }
        {
            const std::lock_guard cores{shared_code->cores_mutex};
            for (A64JitState* const core : shared_code->cores) {
                core->ResetRSB();
            }
        }
        if (shared_code->invalidate_entire_cache) {
            if (conf.counters) {
                ++conf.counters->cache_clears;
            }
            if (shared_code->shared) {
                LOG_INFO(Core_ARM, "Shared JIT: flushed {} MiB of code", CodeCacheUsed() >> 20);
            }
            block_of_code.ClearCache();
            emitter.ClearCache();
            shared_code->flush_requested = false;
            shared_code->last_flush = std::chrono::steady_clock::now();
        } else {
            emitter.InvalidateCacheRanges(shared_code->invalid_cache_ranges);
        }
        shared_code->invalid_cache_ranges.clear();
        shared_code->invalidate_entire_cache = false;
        shared_code->invalidation_pending = false;
    }

    IR::Block ir_block = {LocationDescriptor(0, FP::FPCR(0), false)};
    const UserConfig conf;
    A64JitState jit_state;
    std::shared_ptr<SharedCode> shared_code;
    BlockOfCode& block_of_code;
    A64EmitX64& emitter;
    Optimization::PolyfillOptions polyfill_options;
    /// Shared code: this core's fast-dispatch table (the first core uses the emitter's).
    std::vector<A64EmitX64::FastDispatchEntry> own_dispatch_table;
    bool is_executing = false;

};

void SharedCode::RequestInvalidation(u64 start_address, size_t length) {
    {
        const std::lock_guard lock{invalidation_mutex};
        const auto end_address = static_cast<u64>(start_address + length - 1);
        invalid_cache_ranges.add(boost::icl::discrete_interval<u64>::closed(start_address, end_address));
        invalidation_pending = true;
    }
    HaltAll();
}

void SharedCode::RequestFullFlush() {
    {
        const std::lock_guard lock{invalidation_mutex};
        invalidate_entire_cache = true;
        invalidation_pending = true;
    }
    HaltAll();
}

void SharedCode::HaltAll() {
    const std::lock_guard lock{cores_mutex};
    for (A64JitState* const core : cores) {
        Atomic::Or(&core->halt_reason, static_cast<u32>(HaltReason::CacheInvalidation));
    }
}

Jit::Jit(UserConfig conf)
        : impl(std::make_unique<Jit::Impl>(this, conf)) {}

Jit::~Jit() = default;

HaltReason Jit::Run() {
    return impl->Run();
}

HaltReason Jit::Step() {
    return impl->Step();
}

void Jit::ClearCache() {
    impl->ClearCache();
}

bool Jit::PrecompileBlock(u64 location) {
    return impl->PrecompileBlock(location);
}

void Jit::InvalidateCacheRange(u64 start_address, size_t length) {
    impl->InvalidateCacheRange(start_address, length);
}

PrecompileResult Jit::Precompile(std::uint64_t location, std::size_t keep_free) {
    return impl->Precompile(location, keep_free);
}

std::size_t Jit::CodeCacheUsed() const {
    return impl->CodeCacheUsed();
}

void Jit::Reset() {
    impl->Reset();
}

void Jit::HaltExecution(HaltReason hr) {
    impl->HaltExecution(hr);
}

void Jit::ClearHalt(HaltReason hr) {
    impl->ClearHalt(hr);
}

u64 Jit::GetSP() const {
    return impl->GetSP();
}

void Jit::SetSP(u64 value) {
    impl->SetSP(value);
}

u64 Jit::GetPC() const {
    return impl->GetPC();
}

void Jit::SetPC(u64 value) {
    impl->SetPC(value);
}

u64 Jit::GetRegister(size_t index) const {
    return impl->GetRegister(index);
}

void Jit::SetRegister(size_t index, u64 value) {
    impl->SetRegister(index, value);
}

std::array<u64, 31> Jit::GetRegisters() const {
    return impl->GetRegisters();
}

void Jit::SetRegisters(const std::array<u64, 31>& value) {
    impl->SetRegisters(value);
}

Vector Jit::GetVector(size_t index) const {
    return impl->GetVector(index);
}

void Jit::SetVector(size_t index, Vector value) {
    impl->SetVector(index, value);
}

std::array<Vector, 32> Jit::GetVectors() const {
    return impl->GetVectors();
}

void Jit::SetVectors(const std::array<Vector, 32>& value) {
    impl->SetVectors(value);
}

u32 Jit::GetFpcr() const {
    return impl->GetFpcr();
}

void Jit::SetFpcr(u32 value) {
    impl->SetFpcr(value);
}

u32 Jit::GetFpsr() const {
    return impl->GetFpsr();
}

void Jit::SetFpsr(u32 value) {
    impl->SetFpsr(value);
}

u32 Jit::GetPstate() const {
    return impl->GetPstate();
}

void Jit::SetPstate(u32 value) {
    impl->SetPstate(value);
}

void Jit::ClearExclusiveState() {
    impl->ClearExclusiveState();
}

bool Jit::IsExecuting() const {
    return impl->IsExecuting();
}

std::string Jit::Disassemble() const {
    return impl->Disassemble();
}

}  // namespace Dynarmic::A64
