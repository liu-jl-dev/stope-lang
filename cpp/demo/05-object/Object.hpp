#pragma once
#include <cstdint>
#include <vector>
#include <stope/basic_vm.hpp>

// Handle 的 data.data 直接存对象指针（uint64 位型），demo 侧经这两个 helper 进出。
constexpr int kMemberDescClass = -2;  // obj:<名> 成员描述符
constexpr int kCtorDescClass = -3;    // <Class>:<New> 构造器描述符

// 成员的种类：查找表 memberById 的值。成员经两层整数查询定位（成员 id ->
// 类内 MemberRef，类取自绑定对象自己的 classId），不做按名查找。
constexpr int kMemberProp = 0;    // obj:<属性> —— Assign 写字段
constexpr int kMemberMethod = 1;  // obj:<方法> —— Call 调方法
constexpr int kMemberDelete = 2;  // obj:delete —— Call 跑 <delete> 并回收对象

// 类内成员的位置：kind 决定 index 落在哪个数组（properties / methods）。
struct MemberRef {
  int kind;
  int index;
};

struct Object {
  int classId = -1;
  std::vector<Stope::BasicVM::Value> fields;  // 按下标对齐 Class::properties
};

Stope::BasicVM::Value ObjectToHandle(Object* p);
Object* HandleToObject(const Stope::BasicVM::Value& v);
