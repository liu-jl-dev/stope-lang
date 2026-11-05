#pragma once
#include <map>
#include <memory>
#include <span>
#include <string>
#include <utility>
#include <vector>
#include <stope/program.hpp>
#include <stope/basic_vm.hpp>

#include "Object.hpp"

struct Method {
  std::u16string name;
  Stope::Program program;
  // unique_ptr：Method 因此可移动（vector 可用）。ProgramConstants 构造时
  // 已把常量深拷贝进共享 Allocator，不引用 Program，搬移 Method 不会悬空。
  std::unique_ptr<Stope::BasicVM::ProgramConstants> constAlloc;
  std::vector<std::u16string> params;

  // self:<属性> 引用（编译后从 exports 扫描，只含方法体实际用到的属性）。
  // 属性不进 preExports——方法体里的 self:<属性> 靠编译器的隐式导出机制
  // （未声明标识符自动注册，赋值走 PushId 可写回）浮现出来，链接遍把槽位
  // 与字段配对。未使用的属性不占槽位、不参与拷入拷出。
  std::vector<std::pair<unsigned, size_t>> selfProps;  // (变量槽位下标, 字段下标)
  std::vector<std::pair<unsigned, int>> hostBinds;  // (变量槽位下标, 宿主函数序号)
  // self:<方法名> 调用同对象方法：(变量槽位下标, 成员 id)。InvokeMethod 往
  // 槽位绑 self 的绑定方法描述符——self:Greet() 无需 [对象]，创建即绑定 self。
  std::vector<std::pair<unsigned, int>> selfMethodBinds;

  void InitializeState(Stope::BasicVM::State& state, const Object& self,
                       std::span<const Stope::BasicVM::Value> args) const;
};

struct Class {
  int id = -1;
  std::u16string name;
  std::vector<std::u16string> properties;
  std::vector<Method> methods;  // 可移动（constAlloc 为 unique_ptr）；无人跨扩容持有指针
  // 成员 id -> 类内位置（唯一查找表）。运行时两层查询的第二层：第一层是
  // 绑定对象自己的 classId（同名成员在各类里可以落在不同位置，互不干扰）。
  // 一个名字在同一个类里只能是属性或方法之一——单表结构性禁止二者兼得。
  std::map<int, MemberRef> memberById;
  std::vector<int> constructorIds;
  std::map<std::u16string, int> constructorMap;  // <new name> -> methods 下标（装配期用）
  int deconstructorId = -1;
};
