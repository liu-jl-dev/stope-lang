#pragma once

#include <map>
#include <span>
#include <string>
#include <vector>

#include <stope/basic_vm.hpp>
#include "Object.hpp"
#include "Function.hpp"
#include "Class.hpp"
#include "API.hpp"
#include "ObjectManager.hpp"

struct Runtime {
  Stope::BasicVM::Allocator basicAlloc;  // 所有 State 共享

  std::vector<Stope::BasicVM::HostFunction> hostFuncs;
  std::map<std::u16string, int> hostFuncMap;

  std::vector<Function> functions;  // 可移动（constAlloc 为 unique_ptr），无人跨扩容持有指针
  std::map<std::u16string, int> funcMap;

  std::vector<Class> classes;       // 同上；ObjectManager 持有的是类 id，不是指针
  std::map<std::u16string, int> classMap;

  // 成员名 -> 成员 id（全局，跨类共享同名 id）。obj:<名> 运行时两层查询的
  // 第一层的"名"在装配期就折算成了 id，运行中零字符串比较。
  std::map<std::u16string, int> memberNameMap;
  int NewMemberId(const std::u16string& name);  // 幂等：已存在返回原 id

  ObjectManager objMgr;
  API api;

  Runtime();

  void AddHostFunction(const std::u16string& name, Stope::BasicVM::HostFunction func);
  Class& NewClass();
  Function* FindFunction(const std::u16string& name);

  // 装配入口函数：宿主函数、"<Class>:<New>" 构造器描述符、obj:* 成员描述符
  // 绑进 entry 导出槽位。obj:* 命名等约定属于 Runtime 对文档的契约，嵌入者
  // （main）只调这一行。需在 state.variables.resize 之后、Run 之前调用。
  void BindEntry(Stope::BasicVM::State& state, Function& entry);

  // 装配方法 State 并执行；self 的字段经槽位互达，返回前回写。
  // 方法/函数调用的 State 都在这里临时创建、随调用返回销毁（C++ 递归栈即
  // 调用栈）；Runtime 不保存调用栈 —— 那是 demo 6 为 gc 根扫描准备的。
  void InvokeMethod(Method& m, Object& self, std::span<const Stope::BasicVM::Value> args,
                    Stope::BasicVM::Value* out);
};
