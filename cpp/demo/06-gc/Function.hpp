#pragma once
#include <span>
#include <vector>
#include <string>
#include <memory>
#include <stope/core.hpp>
#include <stope/basic_vm.hpp>

struct Function {
  int id = -1;
  std::u16string name;
  std::vector<std::u16string> params;
  Stope::Program program;
  std::vector<unsigned> paramVarIdx;                // params[i] -> 变量槽位下标（装配期预算）
  std::vector<std::pair<unsigned, int>> hostBinds;  // (变量槽位下标, 宿主函数序号)
  // unique_ptr：Function 因此可移动。理由同 Method（见 Class.hpp）。
  std::unique_ptr<Stope::BasicVM::ProgramConstants> constAlloc;

  void InitializeState(Stope::BasicVM::State& state,
                       std::span<const Stope::BasicVM::Value> args) const;
};
