// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

// EDEN_NX2_TIMELINE=<path>: a per-thread timeline of the GPU threads' profile zones (Nx2Profile
// Scope) as a Chrome trace (chrome://tracing, ui.perfetto.dev). Capture starts at the first
// present after the file /tmp/nx2-timeline-go exists and lasts EDEN_NX2_TIMELINE_SECONDS (default
// 3); zones shorter than EDEN_NX2_TIMELINE_MIN_US (default 5) are left out. Presents are marked.
// Each thread records into its own fixed buffer, so the capture never allocates while it runs.

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "common/common_types.h"

#ifdef __linux__
#include <pthread.h>
#include <unistd.h>
#include <sys/syscall.h>
#endif

namespace VideoCommon::Nx2Timeline {

struct Event {
    u64 start;
    u64 end;
    u32 zone;
};

struct Buffer {
    static constexpr size_t Capacity = 1 << 20;
    std::unique_ptr<Event[]> events{new Event[Capacity]};
    std::atomic<size_t> count{};
    std::string name;
    long tid{};
};

enum class State : int { Off, Armed, Capturing, Done };

inline const char* const g_path = std::getenv("EDEN_NX2_TIMELINE");
inline std::atomic<State> g_state{g_path != nullptr ? State::Armed : State::Off};
inline std::mutex g_mutex;
inline std::vector<std::unique_ptr<Buffer>> g_buffers;
inline thread_local Buffer* t_buffer{};
inline u64 g_min_ticks{};
inline u64 g_start_ticks{};
inline u64 g_start_ns{};
inline u64 g_end_ns{};

inline bool Enabled() {
    return g_path != nullptr;
}

inline Buffer* ThreadBuffer() {
    if (t_buffer == nullptr) {
        auto buffer = std::make_unique<Buffer>();
#ifdef __linux__
        char name[32]{};
        pthread_getname_np(pthread_self(), name, sizeof(name));
        buffer->name = name;
        buffer->tid = static_cast<long>(syscall(SYS_gettid));
#endif
        std::scoped_lock lock{g_mutex};
        t_buffer = buffer.get();
        g_buffers.push_back(std::move(buffer));
    }
    return t_buffer;
}

/// A zone that ran [start, end) in time stamp ticks.
inline void Record(u32 zone, u64 start, u64 end) {
    if (g_state.load(std::memory_order_relaxed) != State::Capturing || end - start < g_min_ticks) {
        return;
    }
    Buffer* const buffer = ThreadBuffer();
    const size_t index = buffer->count.load(std::memory_order_relaxed);
    if (index < Buffer::Capacity) {
        buffer->events[index] = {start, end, zone};
        buffer->count.store(index + 1, std::memory_order_release);
    }
}

/// Called at each present with the time stamp and wall clock now; `zone_names` names the zones.
template <typename NowNs, typename TicksFn, typename Names>
void OnPresent(NowNs now_ns, TicksFn ticks, const Names& zone_names, u32 present_zone) {
    const State state = g_state.load(std::memory_order_relaxed);
    if (state == State::Armed) {
        if (!std::filesystem::exists("/tmp/nx2-timeline-go")) {
            return;
        }
        const char* const seconds_env = std::getenv("EDEN_NX2_TIMELINE_SECONDS");
        const char* const min_env = std::getenv("EDEN_NX2_TIMELINE_MIN_US");
        const double seconds = seconds_env ? std::strtod(seconds_env, nullptr) : 3.0;
        const double min_us = min_env ? std::strtod(min_env, nullptr) : 5.0;
        // Calibrate ticks against the wall clock over ~20 ms.
        const u64 n0 = now_ns(), t0 = ticks();
        std::this_thread::sleep_for(std::chrono::milliseconds{20});
        const u64 n1 = now_ns(), t1 = ticks();
        const double ticks_per_ns = static_cast<double>(t1 - t0) / static_cast<double>(n1 - n0);
        g_min_ticks = static_cast<u64>(min_us * 1000.0 * ticks_per_ns);
        g_start_ticks = t1;
        g_start_ns = n1;
        g_end_ns = n1 + static_cast<u64>(seconds * 1e9);
        g_state.store(State::Capturing, std::memory_order_release);
        return;
    }
    if (state != State::Capturing) {
        return;
    }
    const u64 t = ticks();
    Record(present_zone, t, t + g_min_ticks + 1); // a present marker
    const u64 n = now_ns();
    if (n < g_end_ns) {
        return;
    }
    g_state.store(State::Done, std::memory_order_release);
    const double ticks_per_ns =
        static_cast<double>(t - g_start_ticks) / static_cast<double>(n - g_start_ns);
    std::this_thread::sleep_for(std::chrono::milliseconds{50});
    std::FILE* const file = std::fopen(g_path, "w");
    if (file == nullptr) {
        return;
    }
    std::fputs("{\"traceEvents\":[\n", file);
    bool first = true;
    std::scoped_lock lock{g_mutex};
    for (const auto& buffer : g_buffers) {
        std::fprintf(file, "%s{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":1,\"tid\":%ld,\"args\":{\"name\":\"%s\"}}",
                     first ? "" : ",\n", buffer->tid, buffer->name.c_str());
        first = false;
        const size_t count = buffer->count.load(std::memory_order_acquire);
        for (size_t i = 0; i < count; ++i) {
            const Event& e = buffer->events[i];
            if (e.start < g_start_ticks) {
                continue;
            }
            const double ts = static_cast<double>(e.start - g_start_ticks) / ticks_per_ns / 1000.0;
            const double dur = static_cast<double>(e.end - e.start) / ticks_per_ns / 1000.0;
            std::fprintf(file, ",\n{\"ph\":\"X\",\"name\":\"%s\",\"pid\":1,\"tid\":%ld,\"ts\":%.3f,\"dur\":%.3f}",
                         e.zone < zone_names.size() ? zone_names[e.zone] : "?", buffer->tid, ts, dur);
        }
    }
    std::fputs("\n]}\n", file);
    std::fclose(file);
}

} // namespace VideoCommon::Nx2Timeline
