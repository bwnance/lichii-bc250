// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

/* This file is part of the dynarmic project.
 * Copyright (c) 2018 MerryMage
 * SPDX-License-Identifier: 0BSD
 */

#pragma once

#include <functional>
#include <vector>

#include "common/common_types.h"
#include "dynarmic/backend/x64/xbyak.h"

namespace Dynarmic::Backend::X64 {

using RegList = std::vector<Xbyak::Reg64>;

class BlockOfCode;

class Callback {
public:
    virtual ~Callback();

    void EmitCall(BlockOfCode& code) const {
        EmitCall(code, [](RegList) {});
    }

    virtual void EmitCall(BlockOfCode& code, std::function<void(RegList)> fn) const = 0;
    virtual void EmitCallWithReturnPointer(BlockOfCode& code, std::function<void(Xbyak::Reg64, RegList)> fn) const = 0;
};

class SimpleCallback final : public Callback {
public:
    template<typename Function>
    SimpleCallback(Function fn)
            : fn(reinterpret_cast<void (*)()>(fn)) {}

    using Callback::EmitCall;

    void EmitCall(BlockOfCode& code, std::function<void(RegList)> fn) const override;
    void EmitCallWithReturnPointer(BlockOfCode& code, std::function<void(Xbyak::Reg64, RegList)> fn) const override;

private:
    void (*fn)();
};

class ArgCallback final : public Callback {
public:
    template<typename Function>
    ArgCallback(Function fn, u64 arg)
            : fn(reinterpret_cast<void (*)()>(fn)), arg(arg) {}

    /// The same call with its first argument read from the JIT state at `state_offset` (plus
    /// `adjust`) instead of an immediate: code that serves several cores.
    u64 Argument() const { return arg; }

    ArgCallback FromState(u32 state_offset, u64 adjust) const {
        ArgCallback copy = *this;
        copy.arg = adjust;
        copy.state_offset = state_offset;
        return copy;
    }

    using Callback::EmitCall;

    void EmitCall(BlockOfCode& code, std::function<void(RegList)> fn) const override;
    void EmitCallWithReturnPointer(BlockOfCode& code, std::function<void(Xbyak::Reg64, RegList)> fn) const override;

private:
    void (*fn)();
    u64 arg;
    u32 state_offset = ~u32{0};  ///< ~0: `arg` is the argument itself
};

}  // namespace Dynarmic::Backend::X64
