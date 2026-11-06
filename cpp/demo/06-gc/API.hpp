#pragma once

#include <span>

#include <stope/basic_vm.hpp>

struct ObjectManager;

// ---- Handle 的三个开口：薄转发到 ObjectManager ----
// BasicVM 的 opAt / opAssign / opCall 遇到 Handle 只把值转发给这三个虚函数，
// 栈纪律（弹参数、压返回值）归 opcode；这里再转给 ObjectManager。
struct API : Stope::BasicVM::API {
  ObjectManager* objMgr = nullptr;

  void HandleAt(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle,
                const Stope::BasicVM::Value& key, Stope::BasicVM::Value& out) override;
  void HandleAssign(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle,
                    const Stope::BasicVM::Value& value) override;
  void HandleCall(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle,
                  std::span<Stope::BasicVM::Value> args, Stope::BasicVM::Value& out) override;
};
