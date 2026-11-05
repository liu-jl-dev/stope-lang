#include "Function.hpp"

#include <span>

using namespace Stope;

// 形参槽位：编译时以 params 为 preExports，调用时按同序注入实参。
// 槽位的变量下标已在装配期预算进 paramVarIdx，运行中不做按名查找。
// 所有 State 共享 Runtime::basicAlloc，实参里的 String 句柄直接 Copy 即可。
void Function::InitializeState(BasicVM::State& state,
                               std::span<const BasicVM::Value> args) const {
  for (size_t i = 0; i < params.size(); ++i) {
    BasicVM::Value& dst = state.variables[paramVarIdx[i]];
    BasicVM::Value::Copy(*state.alloc, const_cast<BasicVM::Value&>(args[i]), dst);
  }
}
