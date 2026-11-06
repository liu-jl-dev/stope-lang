#pragma once

#include <span>
#include <string>

#include <stope/basic_vm.hpp>
#include "Object.hpp"

struct Runtime;

// ---- 对象与描述符：obj:* 域的全部行为 ----
// 描述符也是 Object（classId 为负哨兵），Handle 统一指向 Object——因此描述
// 符与业务对象一样是 gc 管理的节点：描述符生命周期由「是否有 State 引用它」
// 决定，demo 5 的 bindCache / freeDescs / 手动驱逐在 demo 6 里全部消失：
// 绑定描述符每次 Bind 新建（fields = [成员 id, 绑定对象 Handle]，经 SetField
// 挂引用），方法返回后无人引用即成垃圾，下次 gc 收走。
// 对象分配器也住在这里（alloc）：demo 的 gc 全部机制在 Object.hpp/.cpp。
struct ObjectManager {
  Runtime* runtime = nullptr;
  ObjectAllocator alloc;

  Stope::BasicVM::Value NewObject(int clsId);  // 业务对象：classId + 字段槽位
  // 成员描述符：fields = [Integer 成员 id, 绑定对象 Handle/Null]——kind 由
  // 类的 memberById 查表揭晓，不进描述符。
  Stope::BasicVM::Value NewMemberDesc(int memberId);
  Stope::BasicVM::Value NewCtorDesc(int clsId, int ctorId);
  // 绑定描述符：fields = [成员 id, 对象 Handle]。每次新建，不去重。
  Stope::BasicVM::Value Bind(int memberId, const Stope::BasicVM::Value& obj);
  Stope::BasicVM::Value Bind(const Stope::BasicVM::Value& memberDesc,
                             const Stope::BasicVM::Value& obj);

  void At(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle, const Stope::BasicVM::Value& key,
          Stope::BasicVM::Value& out);
  void Assign(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle, const Stope::BasicVM::Value& value);
  void Call(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle, std::span<Stope::BasicVM::Value> args,
            Stope::BasicVM::Value& out);

  // 三个开口的公共前奏：安全点——先同步根集合，再做本次操作。归零级联
  // 释放的可靠性由这条顺序保证（见 Object.hpp 的口径说明）。
  void SafePoint();

  void RunDestructor(Object& obj);  // gc 回收前回调：<delete> 在这里跑
  void ReportLive();                // 退出诊断：还活着谁、为什么活着
};
