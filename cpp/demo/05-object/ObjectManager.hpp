#pragma once

#include <map>
#include <set>
#include <span>
#include <string>
#include <utility>

#include <stope/basic_vm.hpp>
#include "Object.hpp"

struct Runtime;

// ---- 对象与描述符：obj:* 域的全部行为 ----
// 对象与描述符都是 Object（classId 为负哨兵的是描述符），但走两套不同的 Handle
// 编码：对象堆分配（new）、Handle 存裸指针（ObjectToHandle / HandleToObject）；
// 描述符存于 descPool、Handle 存**池下标**（DescToHandle / ObjectManager::HandleToDesc）。
// 下标编码让 descPool 退回 vector 底（下标天然稳定、realloc 无所谓），免去 deque
// 与地址脆弱性。demo 5 手动管理：对象由 live 表 + obj:delete 管；描述符统一走
// RefCountedPool（New 即建、obj:delete 按 descByObject 整组 RefDec 回收），**不去重**
// ——每次 Bind 新建、池子按回收槽位复用。demo 6 的 GC 将来替换这里的存储与回收策略。
struct ObjectManager {
  Runtime* runtime = nullptr;
  std::set<Object*> live;
  size_t maxObjects = 0;  // 存活对象上限（live 表大小）；顶到上限构造器报错。
                          // 0 = 不限（对齐 Parser / STML maxDepth 约定）
  // 描述符池：描述符也是 Object，Handle 存池下标（非指针），故用默认 vector 底——
  // 下标天然稳定、realloc 无所谓，无需 deque。New 即建、obj:delete 时按 descByObject
  // 整组 RefDec 回收。
  Stope::BasicVM::RefCountedPool<Object> descPool;
  // 对象 -> 其绑定描述符的池句柄，仅用于 obj:delete 驱逐（不做去重）。
  std::map<Object*, std::vector<unsigned>> descByObject;

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

 private:
  // 描述符 Handle（存池下标）-> Object*。需访问本对象的 descPool，故为成员函数。
  // 返回的指针在 descPool 不 New 的窗口内有效——各调用点均只读后即弃，安全。
  Object* HandleToDesc(const Stope::BasicVM::Value& handle);
};
