/* This file is part of the dynarmic project.
 * Copyright (c) 2018 MerryMage
 * SPDX-License-Identifier: 0BSD
 */

#include "dynarmic/backend/x64/callback.h"

#include "dynarmic/backend/x64/block_of_code.h"

namespace Dynarmic::Backend::X64 {

Callback::~Callback() = default;

void SimpleCallback::EmitCall(BlockOfCode& code, std::function<void(RegList)> l) const {
    l({code.ABI_PARAM1, code.ABI_PARAM2, code.ABI_PARAM3, code.ABI_PARAM4});
    code.CallFunction(fn);
}

void SimpleCallback::EmitCallWithReturnPointer(BlockOfCode& code, std::function<void(Xbyak::Reg64, RegList)> l) const {
    l(code.ABI_PARAM1, {code.ABI_PARAM2, code.ABI_PARAM3, code.ABI_PARAM4});
    code.CallFunction(fn);
}

static void LoadArgument(BlockOfCode& code, Xbyak::Reg64 reg, u64 arg, u32 state_offset) {
    if (state_offset == ~u32{0}) {
        code.mov(reg, arg);
        return;
    }
    code.mov(reg, code.qword[code.ABI_JIT_PTR + state_offset]);
    if (arg != 0) {
        code.add(reg, static_cast<u32>(arg));
    }
}

void ArgCallback::EmitCall(BlockOfCode& code, std::function<void(RegList)> l) const {
    l({code.ABI_PARAM2, code.ABI_PARAM3, code.ABI_PARAM4});
    LoadArgument(code, code.ABI_PARAM1, arg, state_offset);
    code.CallFunction(fn);
}

void ArgCallback::EmitCallWithReturnPointer(BlockOfCode& code, std::function<void(Xbyak::Reg64, RegList)> l) const {
#if defined(WIN32) && !defined(__MINGW64__)
    l(code.ABI_PARAM2, {code.ABI_PARAM3, code.ABI_PARAM4});
    LoadArgument(code, code.ABI_PARAM1, arg, state_offset);
#else
    l(code.ABI_PARAM1, {code.ABI_PARAM3, code.ABI_PARAM4});
    LoadArgument(code, code.ABI_PARAM2, arg, state_offset);
#endif
    code.CallFunction(fn);
}

}  // namespace Dynarmic::Backend::X64
