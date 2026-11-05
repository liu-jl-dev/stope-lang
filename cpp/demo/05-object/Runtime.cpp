#include "Runtime.hpp"

#include <algorithm>
#include <iostream>

using namespace Stope;
using namespace std;

Runtime::Runtime() {
  objMgr.runtime = this;
  api.objMgr = &objMgr;
}

Class& Runtime::NewClass() {
  classes.emplace_back();
  classes.back().id = classes.size() - 1;
  classMap[classes.back().name] = classes.back().id;
  return classes.back();
}

int Runtime::NewMemberId(const std::u16string& name) {
  auto it = memberNameMap.find(name);
  if (it != memberNameMap.end()) {
    return it->second;
  }
  int id = (int)memberNameMap.size();
  memberNameMap.emplace(name, id);
  return id;
}

Function* Runtime::FindFunction(const std::u16string& name) {
  auto it = funcMap.find(name);
  return it == funcMap.end() ? nullptr : &functions[it->second];
}

void Runtime::AddHostFunction(const std::u16string& name,
                              Stope::BasicVM::HostFunction func) {
  hostFuncMap[name] = hostFuncs.size();
  hostFuncs.push_back(func);
}

void Runtime::BindEntry(BasicVM::State& state, Function& entry) {
  auto bind = [&](const u16string& name, const BasicVM::Value& v) {
    auto it = entry.program.exports.find(name);
    if (it == entry.program.exports.end()) {
      return;
    }
    BasicVM::Value& slot = state.variables[it->second];
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, const_cast<BasicVM::Value&>(v), slot);
  };

  // 宿主函数：装配期已预算 (槽位下标, 宿主函数序号)，直接绑。
  for (auto& [varIdx, hostIdx] : entry.hostBinds) {
    BasicVM::Value& slot = state.variables[varIdx];
    slot.type = BasicVM::Value::Type::HostFunction;
    slot.data.hostFuncPtr = hostFuncs[hostIdx];
  }
  // 构造器："<Class>:<New 名>" 逐个绑（装配期按名查 exports，运行中零查找）
  for (auto& cls : classes) {
    for (auto& [name, methodId] : cls.constructorMap) {
      bind(cls.name + u":" + name, objMgr.NewCtorDesc(cls.id, methodId));
    }
  }
  // 成员描述符 obj:<属性>/<方法>/<delete>：描述符只装成员 id（kind 由类的
  // memberById 查表揭晓），运行时经两层整数查询定位。
  for (auto& cls : classes) {
    for (auto& prop : cls.properties) {
      bind(u"obj:" + prop, objMgr.NewMemberDesc(NewMemberId(prop)));
    }
    for (auto& m : cls.methods) {
      if (m.name.empty() || cls.constructorMap.contains(m.name)) {
        continue;  // <delete> 走 obj:delete；构造器不占 obj: 名
      }
      bind(u"obj:" + m.name, objMgr.NewMemberDesc(NewMemberId(m.name)));
    }
    if (cls.deconstructorId >= 0) {
      bind(u"obj:delete", objMgr.NewMemberDesc(NewMemberId(u"delete")));
    }
  }
}

// 装配方法 State 并执行。方法体里的 self:<属性> 槽位与对象字段按下标互达：
// 进入时从字段复制，返回后把槽位写回字段；没碰的属性原样复制，无变化。
void Runtime::InvokeMethod(Method& m, Object& self,
                           std::span<const BasicVM::Value> args,
                           BasicVM::Value* out) {
  BasicVM::State state;
  state.SetAPI(api);
  state.SetAllocator(basicAlloc);
  state.SetProgramConstants(*m.constAlloc);
  state.SetProgram(m.program);
  state.variables.resize(m.program.variableNum);
  m.InitializeState(state, self, args);

  // 方法体里的宿主函数（println 等）绑进隐式导出槽位——装配期已预算好
  // (变量槽位下标, 宿主函数序号) 对，运行中零查找。
  for (auto& [varIdx, hostIdx] : m.hostBinds) {
    BasicVM::Value& slot = state.variables[varIdx];
    slot.type = BasicVM::Value::Type::HostFunction;
    slot.data.hostFuncPtr = hostFuncs[hostIdx];
  }

  // self:<方法名> 槽位绑 self 的绑定方法描述符——方法体内 self:Greet() 直接
  // 调本类方法，无需 [对象]：描述符创建时即绑定 self，Call 走绑定分支。
  // 去重缓存保证反复调用不重复分配。
  for (auto& [varIdx, memberId] : m.selfMethodBinds) {
    BasicVM::Value handle = objMgr.Bind(memberId, ObjectToHandle(&self));
    BasicVM::Value& slot = state.variables[varIdx];
    slot.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, handle, slot);
  }

  state.Run();
  for (const auto& e : state.errors) {
    cout << "  vm: " << e << "\n";
  }

  // 返回前把 self:<属性> 槽位写回字段——selfProps 只含方法体实际引用的
  // 属性，没碰的零开销。
  for (auto& [slotIdx, fieldIdx] : m.selfProps) {
    BasicVM::Value& dst = self.fields[fieldIdx];
    dst.Clear2(basicAlloc);
    BasicVM::Value::Copy(basicAlloc, state.variables[slotIdx], dst);
  }
  if (out != nullptr && !state.returns.empty()) {
    BasicVM::Value::Copy(basicAlloc, state.returns[0], *out);
  }
}
