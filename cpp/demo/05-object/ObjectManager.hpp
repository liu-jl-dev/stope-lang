#pragma once

#include <deque>
#include <map>
#include <set>
#include <span>
#include <string>
#include <utility>

#include <stope/basic_vm.hpp>
#include "Object.hpp"

struct Runtime;

// ---- 对象与描述符：obj:* 域的全部行为 ----
// 描述符也是 Object（classId 为负哨兵），Handle 统一指向 Object。
// demo 5 手动管理：描述符长存不回收，但 Bind 按键去重复用（见 bindCache），
// descs 只随「不同绑定」增长、不随执行次数增长。demo 6 的 GC 将来替换这里
// 的存储与回收策略。
struct ObjectManager {
  Runtime* runtime = nullptr;
  std::deque<Object> descs;  // deque：push 不搬移元素，描述符指针稳定
  std::set<Object*> live;
  // 去重缓存：外层按对象地址、内层按成员 id。绑定描述符只存这两样且创建后
  // 不可变，同一绑定永远等价。obj:delete 时按地址整组驱逐——O(log A) 定位
  // + O(k) 逐个入复用池（k ≤ 成员数，是驱逐的固有工作量）。
  std::map<const void*, std::map<int, Object*>> bindCache;
  // 被驱逐的绑定描述符槽位，Bind 优先复用——descs 只随峰值并发绑定增长，
  // 不随曾见绑定单调增长。
  std::vector<Object*> freeDescs;

  Stope::BasicVM::Value NewObject(int clsId);  // new 对象并入 live 表
  // 成员描述符：fields = [Integer 成员 id, 绑定对象 Handle/Null]——kind 由
  // 类的 memberById 查表揭晓，不进描述符。
  Stope::BasicVM::Value NewMemberDesc(int memberId);
  Stope::BasicVM::Value NewCtorDesc(int clsId, int ctorId);
  Stope::BasicVM::Value Bind(const Stope::BasicVM::Value& memberDesc, const Stope::BasicVM::Value& obj);
  // 按成员 id 直接绑定（self 绑定用）：走同一个去重缓存。
  Stope::BasicVM::Value Bind(int memberId, const Stope::BasicVM::Value& obj);

  void At(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle, const Stope::BasicVM::Value& key,
          Stope::BasicVM::Value& out);
  void Assign(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle, const Stope::BasicVM::Value& value);
  void Call(Stope::BasicVM::State& s, const Stope::BasicVM::Value& handle, std::span<Stope::BasicVM::Value> args,
            Stope::BasicVM::Value& out);

  void Delete(Stope::BasicVM::State& s, Object& obj);  // 跑 <delete> -> live 移除 -> delete
  void ReportLive();                            // 退出诊断：手动清理的现形镜
};
