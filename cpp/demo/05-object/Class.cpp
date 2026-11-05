#include "Class.hpp"

#include <span>

using namespace Stope;

// 槽位与字段互达：selfProps 里登记的槽位（方法体实际引用的 self:<属性>）
// 从对象字段复制；形参槽位按序注入实参。槽位的变量下标已在链接遍预算好，
// 运行中不做任何按名查找。
void Method::InitializeState(BasicVM::State& state, const Object& self,
                             std::span<const BasicVM::Value> args) const {
  for (auto& [slotIdx, fieldIdx] : selfProps) {
    BasicVM::Value& dst = state.variables[slotIdx];
    BasicVM::Value::Copy(*state.alloc, const_cast<BasicVM::Value&>(self.fields[fieldIdx]), dst);
  }
  for (size_t i = 0; i < params.size() && i < args.size(); ++i) {
    BasicVM::Value& dst = state.variables[program.exports.at(params[i])];
    BasicVM::Value::Copy(*state.alloc, const_cast<BasicVM::Value&>(args[i]), dst);
  }
}
